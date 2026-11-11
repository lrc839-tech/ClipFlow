import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct HistoryImagePreview: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public var dataURL: String { "data:image/png;base64," + png.base64EncodedString() }
}

/// A separate, bounded thumbnail cache. Decoding never runs on the paste FIFO or
/// main actor, and previews never follow HTML image URLs or file-wrapper links.
public actor HistoryImagePreviews {
    private var cache: [String: [HistoryImagePreview]] = [:]
    private var recency: [String] = []
    private var bytes = 0
    private var inFlight: [String: Task<[HistoryImagePreview], Never>] = [:]
    public init() {}

    public func images(id: UUID, store: HistoryStore, size: Int = 256, limit: Int = 1) async throws -> [HistoryImagePreview] {
        let resources = try await store.imagePreviewResources(id: id)
        guard !resources.isEmpty else { return [] }
        let side = min(1200, max(32, size)), count = min(12, max(1, limit))
        let key = resources.map(\.fingerprint).joined(separator: ":") + ":\(side):\(count)"
        if let cached = cache[key] { touch(key); return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .utility) {
            Self.render(resources, side: side, limit: count)
        }
        inFlight[key] = task
        let images = await task.value
        inFlight[key] = nil
        let cost = images.reduce(0) { $0 + $1.png.count }
        if cost <= 16 * 1024 * 1024 {
            while !recency.isEmpty && (bytes + cost > 16 * 1024 * 1024 || cache.count >= 96) {
                let oldest = recency.removeFirst()
                bytes -= cache.removeValue(forKey: oldest)?.reduce(0) { $0 + $1.png.count } ?? 0
            }
            cache[key] = images; bytes += cost; touch(key)
        }
        return images
    }

    private func touch(_ key: String) { recency.removeAll { $0 == key }; recency.append(key) }

    private static func render(_ resources: [HistoryImageResource], side: Int, limit: Int) -> [HistoryImagePreview] {
        var result: [HistoryImagePreview] = []
        for resource in resources {
            guard result.count < limit else { break }
            if resource.isRTFD {
                guard let data = try? Data(contentsOf: resource.url, options: .mappedIfSafe),
                      data.count <= 64 * 1024 * 1024,
                      let wrapper = FileWrapper(serializedRepresentation: data) else { continue }
                let children = wrapper.fileWrappers ?? [:]
                // RTFD may deduplicate two occurrences of the same picture into
                // one file. Follow its local RTF references to retain page order
                // and repeated occurrences in the expanded preview.
                if let rtf = children["TXT.rtf"]?.regularFileContents, rtf.count <= 2 * 1024 * 1024,
                   let pattern = try? NSRegularExpression(pattern: #"\\NeXTGraphic\s+([^\s\\{}]+)"#) {
                    let text = String(decoding: rtf, as: UTF8.self) as NSString
                    let matches = pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                    var ordered: [HistoryImagePreview] = []
                    for match in matches.prefix(limit - result.count) {
                        let name = text.substring(with: match.range(at: 1))
                        if let child = children[name], child.isRegularFile, !child.isSymbolicLink,
                           let bytes = child.regularFileContents,
                           let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache:false] as CFDictionary),
                           let image = thumbnail(source, side: side) { ordered.append(image) }
                    }
                    if !ordered.isEmpty { result.append(contentsOf: ordered); continue }
                }
                var visited = 0
                func visit(_ wrapper: FileWrapper, depth: Int) {
                    visited += 1
                    guard depth <= 8, visited <= 100, result.count < limit, !wrapper.isSymbolicLink else { return }
                    if wrapper.isRegularFile, let data = wrapper.regularFileContents, data.count <= 64 * 1024 * 1024,
                       let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                       let image = thumbnail(source, side: side) { result.append(image) }
                    else if wrapper.isDirectory {
                        for key in (wrapper.fileWrappers ?? [:]).keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                            if let child = wrapper.fileWrappers?[key] { visit(child, depth: depth + 1) }
                        }
                    }
                }
                visit(wrapper, depth: 0)
            } else if let source = CGImageSourceCreateWithURL(resource.url as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = thumbnail(source, side: side) { result.append(image) }
        }
        return result
    }

    private static func thumbnail(_ source: CGImageSource, side: Int) -> HistoryImagePreview? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= (256 * 1024 * 1024) / 4 / height else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest), data.length <= 6 * 1024 * 1024 else { return nil }
        return HistoryImagePreview(png: data as Data, width: image.width, height: image.height)
    }
}
