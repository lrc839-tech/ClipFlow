import AppKit
import Testing
@testable import ClipFlowCore

@Suite(.serialized) @MainActor
struct PasteboardLeaseTests {
    @Test func restoresAllOriginalItemsWhenUnchanged() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let original = PasteboardSnapshot(items: [.init(representations: ["org.clipflow.test.a": Data([0, 255])]),
                                                   .init(representations: ["org.clipflow.test.b": Data([3, 4])])])
        try original.write(to: board)
        let lease = try PasteboardLease(board: board, replacement: .text("C"))
        #expect(lease.stillOwnsClipboard)
        #expect(try lease.restoreIfOwned())
        #expect(try PasteboardSnapshot.capture(from: board) == original)
        #expect(try !lease.restoreIfOwned())
    }

    @Test func concurrentUserCopyWinsAndIsNeverRestoredOver() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PasteboardSnapshot.text("old fixture").write(to: board)
        let lease = try PasteboardLease(board: board, replacement: .text("temporary fixture"))
        let newCopy = PasteboardSnapshot.text("new user fixture")
        try newCopy.write(to: board)
        #expect(!lease.stillOwnsClipboard)
        #expect(try !lease.restoreIfOwned())
        #expect(try PasteboardSnapshot.capture(from: board) == newCopy)
    }

    @Test func sameBytesCopiedAgainStillCountAsExternalChange() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PasteboardSnapshot.text("old").write(to: board)
        let temporary = PasteboardSnapshot.text("same")
        let lease = try PasteboardLease(board: board, replacement: temporary)
        try temporary.write(to: board)
        #expect(try !lease.restoreIfOwned())
        #expect(try PasteboardSnapshot.capture(from: board) == temporary)
    }
}
