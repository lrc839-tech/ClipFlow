import AppKit
import Testing
@testable import ClipFlowCore

@Suite(.serialized) @MainActor
struct HistoryImagePreviewTests {
    func fixture(width: Int = 1200, height: Int = 800) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func persistedImageGetsSmallThumbnailAndLargerPreviewWithoutReordering() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir), previews = HistoryImagePreviews()
        let bytes = try fixture()
        let image = try await store.record(snapshot: .init(items: [.init(representations: ["public.png":bytes, "public.tiff":Data([1])])]))
        let newer = try await store.record(snapshot: .text("newer"))
        let before = try await store.load()
        let small = try #require(try await previews.images(id: image.id, store: store, size: 160).first)
        #expect(small.width == 160); #expect(small.height == 107)
        #expect(NSImage(data: small.png) != nil)
        #expect(small.dataURL.hasPrefix("data:image/png;base64,"))
        let bigger = try #require(try await previews.images(id: image.id, store: store, size: 900).first)
        #expect(bigger.width == 900); #expect(bigger.height == 600)
        #expect(try await previews.images(id: image.id, store: store, size: 160).count == 1)
        #expect(try await store.load().map(\.id) == [newer.id, image.id])
        #expect(try await store.load().map(\.snapshot) == before.map(\.snapshot))
        #expect(try await store.load().map(\.copiedAt) == before.map(\.copiedAt))
    }
    @Test func richAttachmentsAndLateCompletionRefreshAnEarlierEmptyPreview() async throws {
        _ = NSApplication.shared
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir), previews = HistoryImagePreviews()
        let html = PasteboardSnapshot(items: [.init(representations: ["public.html":Data("<p>before<img src='https://alidocs.dingtalk.com/a'>between<img src='https://alidocs.dingtalk.com/b'>after</p>".utf8)])])
        let record = try await store.record(snapshot: html)
        #expect(try await previews.images(id: record.id, store: store).isEmpty)
        let png = try fixture(width: 40, height: 20)
        let completed = try await RichTextImageCompletion.complete(html, fetch: { _, _ in png })
        try await store.savePreparedSnapshot(id: record.id, sourceFingerprint: record.fingerprint, result: completed)
        #expect(try await previews.images(id: record.id, store: store, limit: 1).count == 1)
        #expect(try await previews.images(id: record.id, store: store, size: 900, limit: 12).count == 2)
        let reopened = try HistoryStore(directory: dir)
        #expect(try await HistoryImagePreviews().images(id: record.id, store: reopened, limit: 12).count == 2)
    }
    @Test func legacyLocalImageReferencePreviewsButPlainTextAndRemoteHTMLDoNot() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.png"); try fixture(width: 30, height: 20).write(to: url)
        let store = try HistoryStore(directory: dir.appendingPathComponent("history")), previews = HistoryImagePreviews()
        let legacy = try await store.record(snapshot: .init(items: [.init(representations: ["public.file-url": Data(url.absoluteString.utf8)])]))
        #expect(try await previews.images(id: legacy.id, store: store).count == 1)
        try FileManager.default.removeItem(at: url)
        #expect(try await previews.images(id: legacy.id, store: store).isEmpty)
        let text = try await store.record(snapshot: .text("fixture.png"))
        #expect(try await previews.images(id: text.id, store: store).isEmpty)
        let remote = try await store.record(snapshot: .init(items: [.init(representations: ["public.html":Data("<img src='https://invalid.example/photo.png'>".utf8)])]))
        #expect(try await previews.images(id: remote.id, store: store).isEmpty)
    }
    @Test func invalidImageAndDeletedHistoryCannotReturnCachedPrivatePreview() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir), previews = HistoryImagePreviews()
        let bad = try await store.record(snapshot: .init(items: [.init(representations: ["public.png":Data([1,2,3])])]))
        #expect(try await previews.images(id: bad.id, store: store).isEmpty)
        let good = try await store.record(snapshot: .init(items: [.init(representations: ["public.png":try fixture(width: 20, height: 20)])]))
        #expect(try await previews.images(id: good.id, store: store).count == 1)
        try await store.delete(id: good.id)
        #expect(try await previews.images(id: good.id, store: store).isEmpty)
    }
}
