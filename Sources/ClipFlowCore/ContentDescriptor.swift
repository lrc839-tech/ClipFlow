import AppKit
import UniformTypeIdentifiers
import ImageIO

public enum FileReferenceError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "文件引用已失效或不可读；源文件可能已移动、删除或缺少访问权限，未发送粘贴。" }
}

public extension PasteboardSnapshot {
    static func contentKind(types: [String]) -> String {
        if types.contains(where: { ["net.daringfireball.markdown","public.markdown","text/markdown"].contains($0) }) { return "markdown" }
        if types.contains(NSPasteboard.PasteboardType.rtfd.rawValue) { return "rich" }
        if types.contains(where: { UTType($0)?.conforms(to: .image) == true }) { return "image" }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) || types.contains("NSFilenamesPboardType") { return "file" }
        if types.contains("com.adobe.pdf") { return "pdf" }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue) || types.contains(NSPasteboard.PasteboardType.html.rawValue) { return "rich" }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return "text" }
        return "custom"
    }
    var contentKind: String { Self.contentKind(types: items.flatMap { Array($0.representations.keys) }) }
    var requiresSystemPaste: Bool { contentKind != "text" || items.count != 1 }
    var forSystemPaste: PasteboardSnapshot {
        if contentKind == "image", !items.isEmpty, items.allSatisfy({ item in item.representations.keys.contains(where: Self.isImageType) }) {
            return Self(items: items.map { item in
                .init(representations: item.representations.filter { Self.isImageType($0.key) })
            })
        }
        guard contentKind == "markdown", items.count == 1, let text = plainText else { return self }
        var result = self
        if result.items[0].representations[NSPasteboard.PasteboardType.string.rawValue] == nil {
            result.items[0].representations[NSPasteboard.PasteboardType.string.rawValue] = Data(text.utf8)
        }
        return result
    }
    var fileURLs: [URL] {
        items.flatMap { item -> [URL] in
            if let data = item.representations[NSPasteboard.PasteboardType.fileURL.rawValue],
               let text = String(data: data, encoding: .utf8), let url = URL(string: text), url.isFileURL {
                return [(url as NSURL).filePathURL ?? url]
            }
            if let data = item.representations["NSFilenamesPboardType"],
               let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                return paths.map { URL(fileURLWithPath: $0) }
            }
            return []
        }
    }
    /// Resolve file-reference URLs while their source volume is still available.
    /// Image files also get durable PNG bytes so future paste never depends on a filename.
    func materializingImageFiles(maxBytes: Int = 64 * 1024 * 1024) throws -> Self {
        var result = self
        var retained = items.reduce(0) { $0 + $1.representations.values.reduce(0) { $0 + $1.count } }
        guard maxBytes >= 0, retained <= maxBytes else { throw PasteboardSnapshotError.sizeLimitExceeded(limit: maxBytes) }
        for index in result.items.indices {
            var item = result.items[index]
            if let bytes = item.representations["public.file-url"],
               let text = String(data: bytes, encoding: .utf8), let raw = URL(string: text),
               let resolved = (raw as NSURL).filePathURL {
                let pathBytes = Data(resolved.absoluteString.utf8)
                retained += pathBytes.count - bytes.count
                item.representations["public.file-url"] = pathBytes
            }
            result.items[index] = item
            if item.representations.keys.contains(where: Self.isImageType) { continue }
            let single = Self(items: [item])
            let urls = single.fileURLs
            let filename = single.plainText ?? ""
            let extensionHint = URL(fileURLWithPath: filename).pathExtension
            let fileType = UTType(filenameExtension: urls.first?.pathExtension ?? "") ?? UTType(filenameExtension: extensionHint)
            let isImage = urls.count == 1 && fileType?.conforms(to: .image) == true
            guard isImage else { continue }
            try single.validateFileReferences()
            let url = urls[0]
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxBytes - retained else { throw PasteboardSnapshotError.sizeLimitExceeded(limit: maxBytes) }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard bytes.count <= maxBytes - retained else { throw PasteboardSnapshotError.sizeLimitExceeded(limit: maxBytes) }
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw FileReferenceError.unavailable }
            // A compressed 24/48MP phone photo can fit the archive limit while its
            // decoded pixels need more memory. Bound decoding separately from storage.
            let maximumDecodedBytes = 256 * 1024 * 1024
            guard width <= maximumDecodedBytes / 4 / height else { throw PasteboardSnapshotError.sizeLimitExceeded(limit: maxBytes) }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw FileReferenceError.unavailable }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw FileReferenceError.unavailable }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw FileReferenceError.unavailable }
            guard png.length <= maxBytes - retained else { throw PasteboardSnapshotError.sizeLimitExceeded(limit: maxBytes) }
            retained += png.length
            result.items[index].representations[UTType.png.identifier] = png as Data
        }
        guard retained <= maxBytes else { throw PasteboardSnapshotError.sizeLimitExceeded(limit: maxBytes) }
        return result
    }
    private static func isImageType(_ type: String) -> Bool { UTType(type)?.conforms(to: .image) == true }
    func validateFileReferences() throws {
        if contentKind == "file" {
            guard !fileURLs.isEmpty, fileURLs.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else { throw FileReferenceError.unavailable }
        }
    }
    var summary: String {
        if contentKind == "image" { return "图片" }
        if contentKind == "file" { return fileURLs.map(\.lastPathComponent).joined(separator: "、") }
        if let plainText { return String(plainText.prefix(240)) }
        return ["image":"图片", "pdf":"PDF 文档", "rich":"富文本", "custom":"自定义格式"][contentKind] ?? contentKind
    }
}
