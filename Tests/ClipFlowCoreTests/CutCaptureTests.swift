import AppKit
import Testing
@testable import ClipFlowCore

@MainActor private final class CutTestTextView: NSTextView {
    var testPasteboard: NSPasteboard!
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        super.writeSelection(to: testPasteboard, types: types)
    }
}

@Suite(.serialized) @MainActor
struct CutCaptureTests {
    @Test func appKitCutRemovesSelectionAndCollectsItWithoutACommandCEvent() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures: [PasteboardSnapshot] = []
        let monitor = ClipboardMonitor(pasteboard: board,
            onCapture: { snapshot, _ in captures.append(snapshot) }, onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        let view = CutTestTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.testPasteboard = board
        view.string = "前面 剪切内容🙂 后面"
        view.setSelectedRange((view.string as NSString).range(of: "剪切内容🙂"))
        let originalGeneralCount = NSPasteboard.general.changeCount
        view.cut(nil)
        monitor.tick()
        #expect(view.string == "前面  后面")
        #expect(captures.count == 1)
        #expect(captures.first?.plainText == "剪切内容🙂")
        #expect(NSPasteboard.general.changeCount == originalGeneralCount)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        try await store.record(snapshot: #require(captures.first))
        let reopened = try HistoryStore(directory: directory)
        #expect(try await reopened.load().first?.snapshot.plainText == "剪切内容🙂")
    }
}
