import AppKit

/// A best-effort lease, not an atomic system transaction. Never restores after a detected
/// external clipboard write. There is no public NSPasteboard compare-and-swap primitive.
public final class PasteboardLease {
    private let board: NSPasteboard
    private let original: PasteboardSnapshot
    private var ownedCount: Int?
    private let onChange: ((Int) -> Void)?

    public var stillOwnsClipboard: Bool { ownedCount.map { board.changeCount == $0 } ?? false }

    public init(board: NSPasteboard, replacement: PasteboardSnapshot, onChange: ((Int) -> Void)? = nil) throws {
        self.board = board
        self.onChange = onChange
        let before = board.changeCount
        original = try PasteboardSnapshot.capture(from: board)
        guard board.changeCount == before else { throw PasteboardSnapshotError.changedDuringRead }
        do {
            ownedCount = try replacement.write(to: board, onClaim: { self.ownedCount = $0; onChange?($0) })
            if let ownedCount { onChange?(ownedCount) }
        } catch {
            // Even writeObjects failure may follow a successful clear. Restore only when
            // the last change count is still attributable to this lease.
            if stillOwnsClipboard {
                do { let count = try original.write(to: board, onClaim: onChange); onChange?(count) }
                catch { throw PasteboardLeaseError.writeAndRestoreFailed }
            }
            ownedCount = nil
            throw error
        }
    }

    /// False means a later copy won; the caller must leave it untouched.
    @discardableResult
    public func restoreIfOwned() throws -> Bool {
        guard stillOwnsClipboard else { ownedCount = nil; return false }
        ownedCount = nil
        let count = try original.write(to: board, onClaim: onChange)
        onChange?(count)
        return true
    }
}

public enum PasteboardLeaseError: LocalizedError {
    case writeAndRestoreFailed
    public var errorDescription: String? { "临时剪贴板写入失败，原剪贴板恢复也失败；请重新复制需要的内容。" }
}
