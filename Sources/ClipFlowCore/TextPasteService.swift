import AppKit
import ApplicationServices
import Carbon

public enum TextPasteError: LocalizedError {
    case permission, focusChanged, unsupported, secureInput, clipboardChanged, eventCreation, cancelled
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "快捷键接管设置或前台应用已变化，此任务已取消。"
        case .permission: return "尚无跨应用输入权限。请授权当前 ClipFlow App 后退出重开；热键注册成功不等于能够粘贴。"
        case .focusChanged: return "前台应用已改变，本条粘贴取消以免输入到其他应用。"
        case .unsupported: return "M1 只粘贴单项目的文本内容；图片、文件及多格式保真粘贴尚未验收。"
        case .secureInput: return "系统安全输入已启用，已停止模拟输入。请离开密码等安全输入区域。"
        case .clipboardChanged: return "发送前检测到新复制，未发送临时内容且保留新剪贴板。"
        case .eventCreation: return "系统无法创建输入事件，未确认粘贴。"
        }
    }
}

public struct TextPasteOutcome: Sendable {
    public let path: String
    public let restoreSkipped: Bool
}

@MainActor
public final class TextPasteService {
    public init() {}

    /// Nil means text size or a long grapheme needs the fallback before any events are sent.
    public static func unicodeChunks(_ text: String) -> [[UniChar]]? {
        guard text.utf16.count <= 2048 else { return nil }
        var output: [[UniChar]] = []
        var chunk: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            guard units.count <= 20 else { return nil }
            if chunk.count + units.count > 20 { output.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { output.append(chunk) }
        return output
    }

    public func paste(snapshot: PasteboardSnapshot, targetPID: pid_t, clipboardMode: Bool,
                      waitMilliseconds: Int = 150, shouldContinue: () -> Bool = { true }, onBoardChange: @escaping (Int) -> Void) async throws -> TextPasteOutcome {
        guard shouldContinue() else { throw TextPasteError.cancelled }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw TextPasteError.permission }
        guard !IsSecureEventInputEnabled() else { throw TextPasteError.secureInput }
        try checkFocus(targetPID)
        try snapshot.validateFileReferences()
        let text = snapshot.plainText
        let preserveFormats = snapshot.requiresSystemPaste

        if !clipboardMode, !preserveFormats, let text, let chunks = Self.unicodeChunks(text) {
            for units in chunks {
                guard shouldContinue() else { throw TextPasteError.cancelled }
                try checkFocus(targetPID)
                guard !IsSecureEventInputEnabled() else { throw TextPasteError.secureInput }
                try post(units: units)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
            return TextPasteOutcome(path: "unicode; receipt unconfirmed", restoreSkipped: false)
        }

        let board = NSPasteboard.general
        let lease = try PasteboardLease(board: board, replacement: snapshot.forSystemPaste, onChange: onBoardChange)
        var restored = false
        do {
            try await Task.sleep(nanoseconds: 10_000_000)
            guard shouldContinue() else { throw TextPasteError.cancelled }
            try checkFocus(targetPID)
            guard !IsSecureEventInputEnabled() else { throw TextPasteError.secureInput }
            guard lease.stillOwnsClipboard else { throw TextPasteError.clipboardChanged }
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw TextPasteError.eventCreation }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            let boundedWait = min(2000, max(10, waitMilliseconds))
            try await Task.sleep(nanoseconds: UInt64(boundedWait) * 1_000_000)
        } catch {
            // Restore errors must remain observable rather than being silently swallowed.
            _ = try lease.restoreIfOwned()
            throw error
        }
        restored = try lease.restoreIfOwned()
        return TextPasteOutcome(path: "clipboard; heuristic wait, receipt unconfirmed", restoreSkipped: !restored)
    }

    private func checkFocus(_ pid: pid_t) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw TextPasteError.focusChanged }
    }

    private func post(units: [UniChar]) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw TextPasteError.eventCreation }
        down.flags = []; up.flags = []
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
