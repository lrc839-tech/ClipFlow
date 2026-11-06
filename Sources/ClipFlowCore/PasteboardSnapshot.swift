import AppKit
import CryptoKit

/// Materialized representations only. File URLs remain references; providers and file promises
/// cannot be archived by copying their type identifiers.
public struct PasteboardItemSnapshot: Codable, Equatable, Sendable {
    public var representations: [String: Data]

    public init(representations: [String: Data]) {
        self.representations = representations
    }
}

public enum PasteboardSnapshotError: Error, LocalizedError, Equatable {
    case changedDuringRead
    case unreadableItems
    case unreadableRepresentation(item: Int, type: String)
    case sensitiveType(String)
    case unsupportedFilePromise(String)
    case sizeLimitExceeded(limit: Int)
    case invalidSizeLimit
    case emptyItem(Int)
    case couldNotSetRepresentation(item: Int, type: String)
    case couldNotWrite

    public var errorDescription: String? {
        switch self {
        case .changedDuringRead:
            return "剪贴板在读取期间发生变化，本次快照已放弃。"
        case .unreadableItems:
            return "无法读取剪贴板项目；请检查剪贴板访问权限。"
        case let .unreadableRepresentation(item, type):
            return "第 \(item + 1) 个项目的类型 \(type) 无法提供数据，未保存不完整快照。"
        case let .sensitiveType(type):
            return "检测到敏感或临时剪贴板标记 \(type)，已拒绝保存。"
        case let .unsupportedFilePromise(type):
            return "类型 \(type) 是文件承诺，本版本无法保存其提供者。"
        case let .sizeLimitExceeded(limit):
            return "剪贴板数据超过本次快照的 \(limit) 字节限制，未裁剪或保存部分内容。"
        case .invalidSizeLimit:
            return "快照字节限制不能为负数。"
        case let .emptyItem(item):
            return "第 \(item + 1) 个剪贴板项目没有可恢复的类型。"
        case let .couldNotSetRepresentation(item, type):
            return "无法构建第 \(item + 1) 个项目的类型 \(type)。"
        case .couldNotWrite:
            return "系统剪贴板写入失败；剪贴板可能已经被清空。"
        }
    }
}

public struct PasteboardSnapshot: Codable, Equatable, Sendable {
    public var items: [PasteboardItemSnapshot]

    public init(items: [PasteboardItemSnapshot]) {
        self.items = items
    }

    public static func text(_ value: String) -> Self {
        Self(items: [PasteboardItemSnapshot(representations: [
            NSPasteboard.PasteboardType.string.rawValue: Data(value.utf8)
        ])])
    }

    /// Returns text only for a single item with an explicitly stored UTF-8 representation.
    /// It does not flatten files, images, multiple items, or attributed formats.
    public var plainText: String? {
        guard items.count == 1 else { return nil }
        for type in [NSPasteboard.PasteboardType.string.rawValue, "net.daringfireball.markdown", "public.markdown", "text/markdown"] {
            if let data = items[0].representations[type], let value = String(data:data,encoding:.utf8) { return value }
        }
        return nil
    }

    /// Captures every advertised representation, or throws instead of silently omitting a type.
    /// The byte limit bounds retained payload, not allocations inside an external data provider.
    /// A synchronous NSPasteboard provider can block this call; no provider deadline is claimed.
    public static func capture(from pasteboard: NSPasteboard,
                               maxBytes: Int = 64 * 1024 * 1024) throws -> Self {
        guard maxBytes >= 0 else { throw PasteboardSnapshotError.invalidSizeLimit }
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            throw PasteboardSnapshotError.unreadableItems
        }
        let initialChangeCount = pasteboard.changeCount
        let sourceItems: [NSPasteboardItem]
        if let available = pasteboard.pasteboardItems {
            sourceItems = available
        } else if pasteboard.types?.isEmpty != false {
            sourceItems = []
        } else {
            throw PasteboardSnapshotError.unreadableItems
        }

        // Detect known markers before requesting any payload, including lazy representations.
        for source in sourceItems {
            for type in source.types {
                try validate(type: type.rawValue)
            }
        }

        var byteCount = 0
        var captured: [PasteboardItemSnapshot] = []
        for (itemIndex, source) in sourceItems.enumerated() {
            guard !source.types.isEmpty else { throw PasteboardSnapshotError.emptyItem(itemIndex) }
            var representations: [String: Data] = [:]
            for type in source.types {
                guard let bytes = source.data(forType: type) else {
                    throw PasteboardSnapshotError.unreadableRepresentation(item: itemIndex, type: type.rawValue)
                }
                guard bytes.count <= maxBytes - byteCount else {
                    throw PasteboardSnapshotError.sizeLimitExceeded(limit: maxBytes)
                }
                byteCount += bytes.count
                representations[type.rawValue] = bytes
            }
            captured.append(PasteboardItemSnapshot(representations: representations))
        }
        guard pasteboard.changeCount == initialChangeCount else {
            throw PasteboardSnapshotError.changedDuringRead
        }
        return Self(items: captured)
    }

    /// Constructs all items before clearing the destination. The caller owns change-count
    /// comparisons and restore policy; NSPasteboard exposes no atomic compare-and-swap write.
    @discardableResult
    public func write(to pasteboard: NSPasteboard, onClaim: ((Int) -> Void)? = nil) throws -> Int {
        var outgoing: [NSPasteboardItem] = []
        for (itemIndex, saved) in items.enumerated() {
            guard !saved.representations.isEmpty else { throw PasteboardSnapshotError.emptyItem(itemIndex) }
            let item = NSPasteboardItem()
            for type in saved.representations.keys.sorted() {
                try Self.validate(type: type)
                guard item.setData(saved.representations[type]!, forType: NSPasteboard.PasteboardType(type)) else {
                    throw PasteboardSnapshotError.couldNotSetRepresentation(item: itemIndex, type: type)
                }
            }
            outgoing.append(item)
        }
        // Do not publish temporary/history clipboard payloads through Universal Clipboard.
        let claimCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        onClaim?(claimCount)
        if !outgoing.isEmpty && !pasteboard.writeObjects(outgoing) {
            throw PasteboardSnapshotError.couldNotWrite
        }
        return pasteboard.changeCount
    }

    /// Exact data fingerprint: item order matters; representation dictionary order does not.
    /// Types are retained in the hash, so equal previews with different formats are distinct.
    public var fingerprint: String {
        var hasher = SHA256()
        func appendLength(_ value: Int) {
            var encoded = UInt64(value).bigEndian
            withUnsafeBytes(of: &encoded) { hasher.update(data: Data($0)) }
        }
        hasher.update(data: Data("ClipFlowSnapshot.v1".utf8))
        appendLength(items.count)
        for item in items {
            appendLength(item.representations.count)
            for type in item.representations.keys.sorted() {
                let typeBytes = Data(type.utf8)
                appendLength(typeBytes.count)
                hasher.update(data: typeBytes)
                let bytes = item.representations[type]!
                appendLength(bytes.count)
                hasher.update(data: bytes)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(type: String) throws {
        let normalized = type.lowercased()
        let sensitiveMarkers: Set<String> = [
            "org.nspasteboard.concealedtype",
            "org.nspasteboard.transienttype",
            "org.nspasteboard.autogeneratedtype",
            "de.petermaurer.transientpasteboardtype",
            "com.agilebits.onepassword"
        ]
        if sensitiveMarkers.contains(normalized) || normalized.contains("password") {
            throw PasteboardSnapshotError.sensitiveType(type)
        }
        if normalized.hasPrefix("com.apple.pasteboard.promised-") ||
            normalized == "apple files promise pasteboard type" ||
            normalized == "com.apple.pasteboard.filepromise" {
            throw PasteboardSnapshotError.unsupportedFilePromise(type)
        }
    }
}
