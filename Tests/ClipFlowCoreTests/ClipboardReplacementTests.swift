import AppKit
import Testing
@testable import ClipFlowCore

@Suite(.serialized) @MainActor
struct ClipboardReplacementTests {
    @Test func transientClipboardDoesNotBlockHistorySelectionOrGetArchived() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("unrelated temporary data", forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        board.clearContents(); #expect(board.writeObjects([item]))
        #expect(throws: PasteboardSnapshotError.self) { try PasteboardSnapshot.capture(from: board) }
        let lease = try PasteboardLease(board: board, replacement: .text("selected history"), preserveOriginal: false)
        #expect(lease.stillOwnsClipboard)
        #expect(lease.keepReplacementIfOwned())
        #expect(board.string(forType: .string) == "selected history")
        #expect(board.data(forType: .init("org.nspasteboard.TransientType")) == nil)
    }
    @Test func anUnprovidedRepresentationDoesNotBlockReplacement() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        #expect(board.data(forType: .string) == nil)
        #expect(throws: PasteboardSnapshotError.self) { try PasteboardSnapshot.capture(from: board) }
        let lease = try PasteboardLease(board: board, replacement: .text("restored history"), preserveOriginal: false)
        #expect(lease.keepReplacementIfOwned())
        #expect(board.string(forType: .string) == "restored history")
    }
    @Test func newExternalCopyWinsAfterReplacementEvenOnCleanup() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let lease = try PasteboardLease(board: board, replacement: .text("history"), preserveOriginal: false)
        try PasteboardSnapshot.text("new user copy").write(to: board)
        #expect(!lease.keepReplacementIfOwned())
        #expect(try !lease.restoreIfOwned())
        #expect(board.string(forType: .string) == "new user copy")
    }
    @Test func replacementPreservesAllRichAndImageBytesAndItemOrder() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        let selected = PasteboardSnapshot(items: [.init(representations:["public.rtf":Data("{\\rtf1 text}".utf8),"public.utf8-plain-text":Data("text".utf8)]),.init(representations:["public.png":Data([0,1,2,255])])])
        let lease = try PasteboardLease(board: board, replacement: selected, preserveOriginal: false)
        #expect(lease.keepReplacementIfOwned())
        let actual = try PasteboardSnapshot.capture(from: board)
        #expect(actual.items.count == selected.items.count)
        for (index, item) in selected.items.enumerated() {
            for (type, bytes) in item.representations {
                #expect(actual.items[index].representations[type] == bytes)
            }
        }
    }
}
