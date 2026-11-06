import AppKit
import Testing
@testable import ClipFlowCore

@Suite(.serialized) @MainActor
struct ClipboardMonitorTests {
    @Test func actualTimerCapturesSuccessiveABCChangesWithoutCallingTick() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { value, _ in captures.append(value.plainText!) },
                                       onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        for (index, text) in ["A", "B", "C"].enumerated() {
            try PasteboardSnapshot.text(text).write(to: board)
            let deadline = Date().addingTimeInterval(1)
            while captures.count < index + 1, Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            #expect(captures.count == index + 1)
        }
        // Each copy waits for the actual timer to consume the previous revision.
        // This test makes no guarantee about copies overwritten between timer ticks.
        #expect(captures == ["A", "B", "C"])
    }

    @Test func initialClipboardIsNotImportedAndABCChangesAreCapturedInOrder() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PasteboardSnapshot.text("pre-existing").write(to: board)
        var captures: [PasteboardSnapshot] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { value, _ in captures.append(value) },
                                       onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        monitor.tick()
        #expect(captures.isEmpty)
        for text in ["A", "B", "C"] {
            try PasteboardSnapshot.text(text).write(to: board)
            monitor.tick()
            monitor.tick() // An unchanged change count must not generate duplicates.
        }
        #expect(captures.compactMap(\.plainText) == ["A", "B", "C"])
    }

    @Test func copyingIdenticalBytesIsStillReportedAgain() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { value, _ in captures.append(value.plainText!) },
                                       onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<2 {
            try PasteboardSnapshot.text("same").write(to: board)
            monitor.tick()
        }
        #expect(captures == ["same", "same"])
    }

    @Test func selfWriteIsSuppressedButLaterExternalCopyOfSameBytesIsCaptured() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { value, _ in captures.append(value.plainText!) },
                                       onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        let fixture = PasteboardSnapshot.text("same")
        let ownCount = try fixture.write(to: board, onClaim: { monitor.suppress($0) })
        monitor.suppress(ownCount)
        monitor.tick()
        #expect(captures.isEmpty)
        #expect(monitor.suppressedChangeCounts.isEmpty)
        try fixture.write(to: board)
        monitor.tick()
        #expect(captures == ["same"])
    }

    @Test func userCopyBeforeFirstTickIsNotSwallowedByEarlierSelfWriteToken() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { value, _ in captures.append(value.plainText!) },
                                       onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        let ownCount = try PasteboardSnapshot.text("temporary").write(to: board)
        monitor.suppress(ownCount)
        try PasteboardSnapshot.text("new user copy").write(to: board)
        monitor.tick()
        #expect(captures == ["new user copy"])
        #expect(monitor.suppressedChangeCounts.isEmpty)
    }

    @Test func pauseUpdatesBaselineAndResumeDoesNotSavePausedContent() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { value, _ in captures.append(value.plainText!) },
                                       onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        monitor.paused = true
        try PasteboardSnapshot.text("private while paused").write(to: board)
        monitor.tick()
        try PasteboardSnapshot.text("still paused, without a tick").write(to: board)
        monitor.paused = false
        monitor.tick()
        #expect(captures.isEmpty)
        try PasteboardSnapshot.text("resumed").write(to: board)
        monitor.tick()
        #expect(captures == ["resumed"])
    }

    @Test func stoppedServiceDoesNotCaptureAndRestartSkipsExistingClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures = 0
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { _, _ in captures += 1 },
                                       onDiagnostic: { _ in })
        monitor.start()
        monitor.stop()
        try PasteboardSnapshot.text("while stopped").write(to: board)
        monitor.tick()
        #expect(captures == 0)
        monitor.start()
        defer { monitor.stop() }
        monitor.tick()
        #expect(captures == 0)
        try PasteboardSnapshot.text("after restarting").write(to: board)
        monitor.tick()
        #expect(captures == 1)
    }

    @Test func binaryFilesImagesAndMultipleItemsAreCapturedWithoutFlattening() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures = 0
        var diagnostics: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { _, _ in captures += 1 },
                                       onDiagnostic: { diagnostics.append($0) })
        monitor.start()
        defer { monitor.stop() }
        let fixtures: [PasteboardSnapshot] = [
            .init(items: [.init(representations: ["org.clipflow.test.binary": Data([0, 255])])]),
            .init(items: [.init(representations: [
                NSPasteboard.PasteboardType.fileURL.rawValue: Data("file:///tmp/clipflow-test.txt".utf8),
                NSPasteboard.PasteboardType.string.rawValue: Data("file:///tmp/clipflow-test.txt".utf8)
            ])]),
            .init(items: [.init(representations: [
                NSPasteboard.PasteboardType.png.rawValue: Data([1, 2, 3]),
                NSPasteboard.PasteboardType.string.rawValue: Data("image caption fallback".utf8)
            ])]),
            .init(items: [
                .init(representations: [NSPasteboard.PasteboardType.string.rawValue: Data("A".utf8)]),
                .init(representations: [NSPasteboard.PasteboardType.string.rawValue: Data("B".utf8)])
            ])
        ]
        for fixture in fixtures {
            try fixture.write(to: board)
            monitor.tick()
        }
        #expect(captures == fixtures.count)
        #expect(diagnostics.isEmpty)
    }

    @Test func identifiedSensitiveMarkersAreRejectedWithoutPayloadDisclosure() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures = 0
        var diagnostics: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { _, _ in captures += 1 },
                                       onDiagnostic: { diagnostics.append($0) })
        monitor.start()
        defer { monitor.stop() }
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            let item = NSPasteboardItem()
            #expect(item.setString("do-not-log-this-secret", forType: .string))
            #expect(item.setData(Data(), forType: .init(marker)))
            board.clearContents()
            #expect(board.writeObjects([item]))
            monitor.tick()
        }
        #expect(captures == 0)
        #expect(diagnostics.count == 3)
        #expect(diagnostics.allSatisfy { $0.contains("敏感") && !$0.contains("do-not-log") })
    }

    @Test func allOriginalTextRepresentationsAreKeptAndSourceIsReported() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures: [(PasteboardSnapshot, String?)] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { captures.append(($0, $1)) },
                                       onDiagnostic: { _ in },
                                       sourceBundleIdentifier: { "org.clipflow.fixture.editor" })
        monitor.start()
        defer { monitor.stop() }
        let fixture = PasteboardSnapshot(items: [.init(representations: [
            NSPasteboard.PasteboardType.string.rawValue: Data("hello".utf8),
            NSPasteboard.PasteboardType.html.rawValue: Data("<b>hello</b>".utf8),
            "org.clipflow.fixture.private": Data([0, 254, 20])
        ])])
        try fixture.write(to: board)
        monitor.tick()
        #expect(captures.count == 1)
        #expect(captures.first?.0 == fixture)
        #expect(captures.first?.1 == "org.clipflow.fixture.editor")
    }

    @Test func excludedFrontmostApplicationIsSkippedWithoutReadingContent() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures = 0
        var diagnostics: [String] = []
        var source = "org.clipflow.fixture.excluded"
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { _, _ in captures += 1 },
                                       onDiagnostic: { diagnostics.append($0) },
                                       sourceBundleIdentifier: { source })
        monitor.excludedBundleIDs = [source]
        monitor.start()
        defer { monitor.stop() }
        try PasteboardSnapshot.text("excluded").write(to: board)
        monitor.tick()
        #expect(captures == 0)
        #expect(diagnostics.count == 1)
        source = "org.clipflow.fixture.allowed"
        try PasteboardSnapshot.text("allowed").write(to: board)
        monitor.tick()
        #expect(captures == 1)
    }

    @Test func oversizedSnapshotsAreRejectedAsAWhole() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captures = 0
        var diagnostics: [String] = []
        let monitor = ClipboardMonitor(pasteboard: board,
                                       onCapture: { _, _ in captures += 1 },
                                       onDiagnostic: { diagnostics.append($0) }, maxBytes: 3)
        monitor.start()
        defer { monitor.stop() }
        try PasteboardSnapshot.text("ABCD").write(to: board)
        monitor.tick()
        #expect(captures == 0)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.contains("整条拒绝") == true)
    }
}
