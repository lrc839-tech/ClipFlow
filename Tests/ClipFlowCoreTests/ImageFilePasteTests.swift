import AppKit
import Testing
@testable import ClipFlowCore

@Suite(.serialized) @MainActor
struct ImageFilePasteTests {
    private func makeJPEG(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4,
            pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<4 { for y in 0..<3 { bitmap.setColor(.red, atX: x, y: y) } }
        let url = directory.appendingPathComponent("IMG_6480.JPG")
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
        return url
    }
    private func fileSnapshot(_ url: URL) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [.init(representations: [
            "public.file-url": Data(url.absoluteString.utf8),
            "public.utf8-plain-text": Data("IMG_6480.JPG".utf8)
        ])])
    }
    @Test func legacyFileReferenceWithFilenamePastesAsAnImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeJPEG(in: directory)
        let reference = try #require((url as NSURL).fileReferenceURL())
        let prepared = try fileSnapshot(reference).materializingImageFiles().forSystemPaste
        #expect(prepared.contentKind == "image")
        #expect(prepared.plainText == nil)
        #expect(prepared.fileURLs.isEmpty)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try prepared.write(to: board)
        let image = try #require(NSImage(pasteboard: board))
        #expect(image.size.width == 4)
        #expect(image.size.height == 3)
        #expect(board.string(forType: .string) == nil)
    }
    @Test func normalMonitorPersistsImageBytesAfterOriginalFileIsDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeJPEG(in: directory)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var captured: PasteboardSnapshot?
        let monitor = ClipboardMonitor(pasteboard: board, onCapture: { value, _ in captured = value }, onDiagnostic: { _ in })
        monitor.start()
        defer { monitor.stop() }
        try fileSnapshot(url).write(to: board)
        monitor.tick()
        let snapshot = try #require(captured)
        let store = try HistoryStore(directory: directory.appendingPathComponent("history"))
        let record = try await store.record(snapshot: snapshot)
        try FileManager.default.removeItem(at: url)
        let restored = try #require(try await store.load(id: record.id).first)
        let outgoing = try restored.snapshot.materializingImageFiles().forSystemPaste
        try outgoing.validateFileReferences()
        try outgoing.write(to: board)
        #expect(NSImage(pasteboard: board) != nil)
        #expect(board.string(forType: .string) == nil)
    }
    @Test func filenameTextAndRegularFilesKeepTheirMeaning() throws {
        let text = PasteboardSnapshot.text("IMG_6480.JPG")
        #expect(try text.materializingImageFiles().forSystemPaste == text)
        let regular = fileSnapshot(URL(fileURLWithPath: "/tmp/ClipFlow-file.txt"))
        let outgoing = try regular.materializingImageFiles().forSystemPaste
        #expect(outgoing.fileURLs == regular.fileURLs)
        #expect(outgoing.contentKind == "file")
        #expect(outgoing.plainText == nil)
    }
    @Test func missingImageFileDoesNotFallBackToItsFilename() throws {
        let missing = fileSnapshot(URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/IMG_6480.JPG"))
        #expect(throws: FileReferenceError.self) { try missing.materializingImageFiles() }
    }
}
