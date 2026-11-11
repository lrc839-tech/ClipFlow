import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCompletionError: LocalizedError {
    case noImages, unsupportedSource, downloadFailed, loginRequired, tooLarge, invalidImage, invalidHTML

    public var errorDescription: String? {
        switch self {
        case .noImages: return "这条富文本没有可补全的图片。"
        case .unsupportedSource: return "图片地址不属于当前支持的钉钉图片来源，原记录已保留。"
        case .downloadFailed: return "图片下载失败或超时，原记录已保留，可稍后重试。"
        case .loginRequired: return "图片链接已过期或需要登录，请回到钉钉文档重新复制。"
        case .tooLarge: return "图片数量或数据量超过补全上限，原记录已保留。"
        case .invalidImage: return "图片资源无法解析，原记录已保留。"
        case .invalidHTML: return "富文本无法完整转换，原记录已保留。"
        }
    }
}

private final class ImageDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var failure: ImageCompletionError?

    init(limit: Int) { self.limit = limit }
    var error: ImageCompletionError? { lock.lock(); defer { lock.unlock() }; return failure }
    private func fail(_ error: ImageCompletionError, task: URLSessionTask) {
        lock.lock(); failure = error; lock.unlock()
        task.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, RichTextImageCompletion.permitsRemoteURL(url) else {
            completionHandler(nil)
            fail(.unsupportedSource, task: task)
            return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { fail(.tooLarge, task: downloadTask) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public enum RichTextImageCompletion {
    public static func permitsRemoteURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "dingtalk.com" || host.hasSuffix(".dingtalk.com")
    }

    public static func downloadImage(_ url: URL, limit: Int) async throws -> Data {
        guard permitsRemoteURL(url) else { throw ImageCompletionError.unsupportedSource }
        let delegate = ImageDownloadDelegate(limit: limit)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 16
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse else { throw ImageCompletionError.downloadFailed }
            if http.statusCode == 401 || http.statusCode == 403 { throw ImageCompletionError.loginRequired }
            guard (200...299).contains(http.statusCode) else { throw ImageCompletionError.downloadFailed }
            guard response.mimeType?.lowercased().hasPrefix("image/") == true else { throw ImageCompletionError.loginRequired }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= limit else { throw ImageCompletionError.tooLarge }
            let data = try Data(contentsOf: file)
            guard data.count <= limit else { throw ImageCompletionError.tooLarge }
            return data
        } catch {
            if let failure = delegate.error { throw failure }
            if let failure = error as? ImageCompletionError { throw failure }
            if Task.isCancelled { throw CancellationError() }
            throw ImageCompletionError.downloadFailed
        }
    }

    @MainActor
    public static func canComplete(_ snapshot: PasteboardSnapshot) -> Bool {
        guard let document = try? document(from: snapshot), let images = try? document.nodes(forXPath: "//*[local-name()='img']"), !images.isEmpty else { return false }
        return images.allSatisfy { node in
            guard let element = node as? XMLElement, let source = element.attribute(forName: "src")?.stringValue else { return false }
            return source.hasPrefix("data:image/") || URL(string: source).map(permitsRemoteURL) == true
        }
    }

    @MainActor
    public static func complete(_ snapshot: PasteboardSnapshot,
                                fetch: (URL, Int) async throws -> Data = downloadImage) async throws -> CompletedRichTextImages {
        let document = try document(from: snapshot)
        let imageNodes = try document.nodes(forXPath: "//*[local-name()='img']")
        guard !imageNodes.isEmpty else { throw ImageCompletionError.noImages }
        guard imageNodes.count <= 12 else { throw ImageCompletionError.tooLarge }
        let started = Date()
        var cache: [String: Data] = [:]
        var images: [Data] = []
        var total = 0
        for node in imageNodes {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) < 30 else { throw ImageCompletionError.downloadFailed }
            guard let element = node as? XMLElement, let source = element.attribute(forName: "src")?.stringValue else { throw ImageCompletionError.invalidHTML }
            let png: Data
            if let existing = cache[source] { png = existing }
            else {
                let bytes: Data
                if source.hasPrefix("data:image/") {
                    guard let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
                          let decoded = Data(base64Encoded: String(source[source.index(after: comma)...])) else { throw ImageCompletionError.invalidImage }
                    bytes = decoded
                } else {
                    guard let url = URL(string: source), permitsRemoteURL(url) else { throw ImageCompletionError.unsupportedSource }
                    bytes = try await fetch(url, 8 * 1024 * 1024)
                }
                guard bytes.count <= 8 * 1024 * 1024 else { throw ImageCompletionError.tooLarge }
                png = try await Task.detached(priority: .utility) { try pngData(bytes) }.value
                cache[source] = png
            }
            total += png.count
            guard total <= 24 * 1024 * 1024 else { throw ImageCompletionError.tooLarge }
            images.append(png)
        }
        // Only standard formatting enters the HTML importer. Image placeholders
        // prevent its HTML reader from issuing its own network requests.
        sanitize(document)
        document.dtd = nil
        let placeholders = try XMLDocument(xmlString: document.xmlString, options: [.nodeLoadExternalEntitiesNever])
        let placeholderNodes = try placeholders.nodes(forXPath: "//*[local-name()='img']")
        guard placeholderNodes.count == images.count else { throw ImageCompletionError.invalidHTML }
        var markers: [String] = []
        for (index, node) in placeholderNodes.enumerated() {
            let marker = "CLIPFLOWIMAGE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            guard let parent = node.parent as? XMLElement else { throw ImageCompletionError.invalidHTML }
            let position = node.index
            node.detach()
            let text = XMLNode(kind: .text)
            text.stringValue = marker
            parent.insertChild(text, at: position)
            markers.append(marker)
            guard let element = imageNodes[index] as? XMLElement else { throw ImageCompletionError.invalidHTML }
            element.addAttribute(XMLNode.attribute(withName: "src", stringValue: "data:image/png;base64," + images[index].base64EncodedString()) as! XMLNode)
        }
        let imported: NSAttributedString
        do {
            imported = try NSAttributedString(data: Data(placeholders.xmlString.utf8),
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        } catch { throw ImageCompletionError.invalidHTML }
        let attributed = NSMutableAttributedString(attributedString: imported)
        for (index, marker) in markers.enumerated() {
            let range = (attributed.string as NSString).range(of: marker)
            guard range.location != NSNotFound else { throw ImageCompletionError.invalidHTML }
            let attachment = NSTextAttachment()
            let wrapper = FileWrapper(regularFileWithContents: images[index])
            wrapper.preferredFilename = "image-\(index + 1).png"
            attachment.fileWrapper = wrapper
            attributed.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
        let visibleText = attributed.string.replacingOccurrences(of: "\u{fffc}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing: PasteboardSnapshot
        if images.count == 1 && visibleText.isEmpty {
            outgoing = PasteboardSnapshot(items: [.init(representations: [NSPasteboard.PasteboardType.png.rawValue: images[0]])])
        } else {
            guard let rtfd = attributed.rtfd(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else { throw ImageCompletionError.invalidHTML }
            outgoing = PasteboardSnapshot(items: [.init(representations: [
                NSPasteboard.PasteboardType.rtfd.rawValue: rtfd,
                NSPasteboard.PasteboardType.html.rawValue: Data(document.xmlString.utf8),
                NSPasteboard.PasteboardType.string.rawValue: Data(attributed.string.utf8)
            ])])
        }
        let retained = outgoing.items.flatMap { Array($0.representations.values) }.reduce(0) { $0 + $1.count }
        guard retained <= 64 * 1024 * 1024 else { throw ImageCompletionError.tooLarge }
        return CompletedRichTextImages(snapshot: outgoing, imageCount: images.count)
    }

    @MainActor private static func document(from snapshot: PasteboardSnapshot) throws -> XMLDocument {
        guard snapshot.items.count == 1, let html = snapshot.items[0].representations[NSPasteboard.PasteboardType.html.rawValue], html.count <= 2 * 1024 * 1024 else { throw ImageCompletionError.invalidHTML }
        // libxml's HTML reader otherwise treats UTF-8 Chinese as Latin-1 when
        // Chromium omits a charset. Normalize to UTF-8 before tidying.
        guard let markup = String(data: html, encoding: .utf8) else { throw ImageCompletionError.invalidHTML }
        let prefix = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
        do { return try XMLDocument(data: Data((prefix + markup).utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) }
        catch { throw ImageCompletionError.invalidHTML }
    }

    private static func pngData(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageCompletionError.invalidImage }
        guard width <= (256 * 1024 * 1024) / 4 / height else { throw ImageCompletionError.tooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageCompletionError.invalidImage }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw ImageCompletionError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageCompletionError.invalidImage }
        return result as Data
    }

    @MainActor private static func sanitize(_ document: XMLDocument) {
        let removed = "//*[local-name()='head' or local-name()='script' or local-name()='style' or local-name()='iframe' or local-name()='object' or local-name()='embed' or local-name()='link' or local-name()='video' or local-name()='audio' or local-name()='source' or local-name()='svg']"
        for node in (try? document.nodes(forXPath: removed)) ?? [] { node.detach() }
        let styles: Set<String> = ["font-family","font-size","font-weight","font-style","color","background-color","text-align","text-decoration","line-height","white-space","margin","margin-left","margin-right","padding","border","border-collapse","width","height","vertical-align"]
        for node in (try? document.nodes(forXPath: "//*")) ?? [] {
            guard let element = node as? XMLElement else { continue }
            for attribute in element.attributes ?? [] {
                guard let name = attribute.name else { continue }
                if name == "style" {
                    let declarations = (attribute.stringValue ?? "").split(separator: ";").compactMap { raw -> String? in
                        let parts = raw.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        guard parts.count == 2, styles.contains(parts[0].lowercased()),
                              !parts[1].contains("\\"), !parts[1].contains("@"), !parts[1].lowercased().contains("url"), !parts[1].lowercased().contains("expression") else { return nil }
                        return parts[0] + ":" + parts[1]
                    }
                    attribute.stringValue = declarations.joined(separator: ";")
                } else if !["href","width","height","colspan","rowspan","align","dir"].contains(name) {
                    element.removeAttribute(forName: name)
                } else if name == "href", let value = attribute.stringValue,
                          !(value.hasPrefix("https://") || value.hasPrefix("http://") || value.hasPrefix("mailto:") || value.hasPrefix("#")) {
                    element.removeAttribute(forName: name)
                }
            }
        }
    }
}
