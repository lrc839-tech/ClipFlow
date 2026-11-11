import AppKit
import Testing
import CSQLite
@testable import ClipFlowCore

@Suite(.serialized) @MainActor
struct RichTextImageCompletionTests {
    func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    func html(_ body: String) -> PasteboardSnapshot {
        .init(items: [.init(representations: ["public.html": Data(("<html><body>" + body + "</body></html>").utf8),
            "public.utf8-plain-text": Data("original fallback".utf8), "org.chromium.web-custom-data": Data([1])])])
    }
    func attachmentCount(_ text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }
    @Test func threeImagesAndTextPasteAsActualAttachmentsInOrder() async throws {
        _ = NSApplication.shared
        let bytes = try png()
        let source = html("<p><b>前</b><img src='https://alidocs.dingtalk.com/a'/></p><p>中<img src='https://alidocs.dingtalk.com/b'/></p><p>后<img src='https://alidocs.dingtalk.com/c'/></p>")
        let result = try await RichTextImageCompletion.complete(source, fetch: { _, _ in bytes })
        #expect(result.imageCount == 3)
        #expect(result.snapshot.contentKind == "rich")
        #expect(result.snapshot.requiresSystemPaste)
        let item = try #require(result.snapshot.items.first)
        #expect(item.representations["org.chromium.web-custom-data"] == nil)
        let markup = String(decoding: try #require(item.representations["public.html"]), as: UTF8.self)
        #expect(!markup.contains("https://alidocs"))
        #expect(markup.components(separatedBy: "data:image/png;base64,").count == 4)
        let attributed = try NSAttributedString(data: #require(item.representations[NSPasteboard.PasteboardType.rtfd.rawValue]),
            options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        #expect(attachmentCount(attributed) == 3)
        #expect(attributed.string.filter { !$0.isWhitespace } == "前\u{fffc}中\u{fffc}后\u{fffc}")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try result.snapshot.forSystemPaste.write(to: board)
        let target = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        target.isRichText = true; target.importsGraphics = true
        #expect(target.readSelection(from: board))
        #expect(attachmentCount(target.attributedString()) == 3)
        #expect(target.string == attributed.string)
    }
    @Test func singleImageBecomesPNGAndRepeatedURLDownloadsOnce() async throws {
        let bytes = try png()
        let single = try await RichTextImageCompletion.complete(html("<img src='https://alidocs.dingtalk.com/a'>"), fetch: { _, _ in bytes })
        #expect(single.snapshot.contentKind == "image")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try single.snapshot.write(to: board)
        #expect(NSImage(pasteboard: board) != nil)
        var calls = 0
        let repeated = try await RichTextImageCompletion.complete(html("<img src='https://alidocs.dingtalk.com/a'><img src='https://alidocs.dingtalk.com/a'>"), fetch: { _, _ in calls += 1; return bytes })
        #expect(calls == 1)
        #expect(repeated.imageCount == 2)
    }
    @Test func unsafeURLsAndInvalidDownloadsAreRejectedAndOriginalUnchanged() async throws {
        for url in ["http://alidocs.dingtalk.com/a", "https://example.com/a", "https://dingtalk.com.evil.test/a", "https://user:pass@alidocs.dingtalk.com/a", "file:///tmp/a", "https://alidocs.dingtalk.com:8443/a"] {
            let source = html("<img src='\(url)'>")
            #expect(!RichTextImageCompletion.canComplete(source))
            var called = false
            await #expect(throws: ImageCompletionError.self) {
                _ = try await RichTextImageCompletion.complete(source, fetch: { _, _ in called = true; return Data() })
            }
            #expect(!called)
        }
        let source = html("<img src='https://alidocs.dingtalk.com/a'>")
        let fingerprint = source.fingerprint
        await #expect(throws: ImageCompletionError.self) {
            _ = try await RichTextImageCompletion.complete(source, fetch: { _, _ in Data("not an image".utf8) })
        }
        await #expect(throws: ImageCompletionError.self) {
            _ = try await RichTextImageCompletion.complete(source, fetch: { _, _ in Data(repeating: 0, count: 8 * 1024 * 1024 + 1) })
        }
        #expect(source.fingerprint == fingerprint)
        let tooMany = html(String(repeating: "<img src='https://alidocs.dingtalk.com/a'>", count: 13))
        await #expect(throws: ImageCompletionError.self) {
            _ = try await RichTextImageCompletion.complete(tooMany, fetch: { _, _ in Issue.record("must reject before fetch"); return Data() })
        }
    }
    @Test func removesActiveContentAndNetworkStylesWhileKeepingText() async throws {
        let bytes = try png()
        let source = html("<script>bad()</script><iframe src='https://example.com'></iframe><p style='background-image:url(https://example.com/a);color:red' onclick='bad()'>正文<img src='https://alidocs.dingtalk.com/a'></p>")
        let result = try await RichTextImageCompletion.complete(source, fetch: { _, _ in bytes })
        let markup = String(decoding: try #require(result.snapshot.items[0].representations["public.html"]), as: UTF8.self)
        #expect(!markup.contains("script")); #expect(!markup.contains("iframe"))
        #expect(!markup.contains("onclick")); #expect(!markup.contains("example.com"))
        #expect(markup.contains("color:red")); #expect(result.snapshot.plainText?.contains("正文") == true)
    }
    @Test func richTextWithImageFlavorKeepsTextInsteadOfFlatteningToImage() throws {
        let snapshot = PasteboardSnapshot(items: [.init(representations: [
            NSPasteboard.PasteboardType.rtfd.rawValue: Data([1]), "public.png": try png(),
            "public.utf8-plain-text": Data("text plus image".utf8)])])
        #expect(snapshot.contentKind == "rich")
        #expect(snapshot.forSystemPaste == snapshot)
        #expect(snapshot.requiresSystemPaste)
    }
}

struct PreparedHistoryTests {
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    let completed = CompletedRichTextImages(snapshot: .text("prepared fixture"), imageCount: 3)
    @Test func completionPersistsWithoutChangingSourceOrderOrRecopyDeduplication() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let source = try await store.record(snapshot: .text("source"), sourceBundleID: "test.source")
        let newer = try await store.record(snapshot: .text("newer"))
        #expect(try await store.savePreparedSnapshot(id: source.id, sourceFingerprint: source.fingerprint, result: completed))
        let reopened = try HistoryStore(directory: dir)
        #expect(try await reopened.preparedSnapshot(id: source.id) == completed.snapshot)
        #expect(try await reopened.load().map(\.id) == [newer.id, source.id])
        let raw = try #require(try await reopened.load(id: source.id).first)
        #expect(raw.snapshot == source.snapshot); #expect(abs(raw.copiedAt.timeIntervalSince(source.copiedAt)) < 0.000001)
        #expect(raw.fingerprint == source.fingerprint); #expect(raw.sourceBundleID == source.sourceBundleID)
        #expect(try await reopened.summaries().first(where: { $0.id == source.id })?.readyImageCount == 3)
        let recopy = try await reopened.record(snapshot: source.snapshot)
        #expect(recopy.id == source.id)
        #expect(try await reopened.preparedSnapshot(id: source.id) == completed.snapshot)
        #expect(try await reopened.stats().recordCount == 2)
    }
    @Test func lateCompletionDoesNotResurrectDeletedOrWrongSource() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let source = try await store.record(snapshot: .text("source"))
        #expect(try await !store.savePreparedSnapshot(id: source.id, sourceFingerprint: "wrong", result: completed))
        try await store.delete(id: source.id)
        #expect(try await !store.savePreparedSnapshot(id: source.id, sourceFingerprint: source.fingerprint, result: completed))
        #expect(try await store.preparedSnapshot(id: source.id) == nil)
        #expect(try await store.stats().recordCount == 0)
    }
    @Test func schemaThreeUpgradeRetainsSource() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let source = try await store.record(snapshot: .text("source"))
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "DROP TABLE prepared_history; PRAGMA user_version=3", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let upgraded = try HistoryStore(directory: dir)
        #expect(try await upgraded.load().first?.snapshot == source.snapshot)
        #expect(try await upgraded.preparedSnapshot(id: source.id) == nil)
        #expect(try await upgraded.savePreparedSnapshot(id: source.id, sourceFingerprint: source.fingerprint, result: completed))
    }
    @Test func damagedPreparedBlobDoesNotDamageOriginalRecord() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let record = try await store.record(snapshot: .text("source"))
        try await store.savePreparedSnapshot(id: record.id, sourceFingerprint: record.fingerprint, result: completed)
        // Locate only the known synthetic prepared bytes in this isolated fixture.
        for url in try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("blobs"), includingPropertiesForKeys: nil) {
            if try Data(contentsOf: url) == Data("prepared fixture".utf8) { try Data("damaged".utf8).write(to: url) }
        }
        await #expect(throws: HistoryStoreError.self) { _ = try await store.preparedSnapshot(id: record.id) }
        #expect(try await store.load().first?.snapshot == record.snapshot)
    }
}
