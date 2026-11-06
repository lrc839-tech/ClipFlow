import AppKit
import UniformTypeIdentifiers

public enum FileReferenceError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "文件引用已失效或不可读；源文件可能已移动、删除或缺少访问权限，未发送粘贴。" }
}

public extension PasteboardSnapshot {
    static func contentKind(types: [String]) -> String {
        if types.contains(where: { ["net.daringfireball.markdown","public.markdown","text/markdown"].contains($0) }) { return "markdown" }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) || types.contains("NSFilenamesPboardType") { return "file" }
        if types.contains(where: { UTType($0)?.conforms(to: .image) == true }) { return "image" }
        if types.contains("com.adobe.pdf") { return "pdf" }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue) || types.contains(NSPasteboard.PasteboardType.html.rawValue) { return "rich" }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return "text" }
        return "custom"
    }
    var contentKind: String { Self.contentKind(types: items.flatMap { Array($0.representations.keys) }) }
    var requiresSystemPaste: Bool { contentKind != "text" || items.count != 1 }
    var forSystemPaste: PasteboardSnapshot {
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
               let text = String(data: data, encoding: .utf8), let url = URL(string: text), url.isFileURL { return [url] }
            if let data = item.representations["NSFilenamesPboardType"],
               let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                return paths.map { URL(fileURLWithPath: $0) }
            }
            return []
        }
    }
    func validateFileReferences() throws {
        if contentKind == "file" {
            guard !fileURLs.isEmpty, fileURLs.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else { throw FileReferenceError.unavailable }
        }
    }
    var summary: String {
        if contentKind == "file" { return fileURLs.map(\.lastPathComponent).joined(separator: "、") }
        if let plainText { return String(plainText.prefix(240)) }
        return ["image":"图片", "pdf":"PDF 文档", "rich":"富文本", "custom":"自定义格式"][contentKind] ?? contentKind
    }
}
