import AppKit
import Testing
@testable import ClipFlowCore

@Suite(.serialized)
@MainActor
struct PasteboardSnapshotTests {
    private func expectThrows<T>(_ expression: @autoclosure () throws -> T,
                                 _ verify: ((Error) -> Void)? = nil,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try expression()
            Issue.record("Expected an error, but the operation succeeded", sourceLocation: sourceLocation)
        } catch {
            verify?(error)
        }
    }
    private func withPasteboards(_ test: (NSPasteboard, NSPasteboard) throws -> Void) rethrows {
        let source = NSPasteboard.withUniqueName()
        let destination = NSPasteboard.withUniqueName()
        defer {
            source.releaseGlobally()
            destination.releaseGlobally()
        }
        try test(source, destination)
    }

    private func roundTrip(_ representations: [String: Data]) throws {
        try withPasteboards { source, destination in
            let expected = PasteboardSnapshot(items: [.init(representations: representations)])
            try expected.write(to: source)
            let captured = try PasteboardSnapshot.capture(from: source)
            #expect(captured.items.count == expected.items.count)
            let capturedItem = try #require(captured.items.first)
            // AppKit may synthesize additional compatible types (for example UTF-16).
            // Every explicitly supplied representation must still be byte-identical.
            for (type, bytes) in representations {
                #expect(capturedItem.representations[type] == bytes)
            }
            let count = try captured.write(to: destination)
            #expect(count == destination.changeCount)
            // Restoring the materialized capture must retain every type, including
            // system-synthesized representations, without adding or dropping bytes.
            #expect(try PasteboardSnapshot.capture(from: destination) == captured)
        }
    }

    @Test func testPNGAndTIFFPixelDataRoundTrip() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 1, y: 0)
        bitmap.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: 0, y: 1)
        bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: 1, y: 1)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let tiff = try #require(bitmap.tiffRepresentation)
        try roundTrip([NSPasteboard.PasteboardType.png.rawValue: png,
                       NSPasteboard.PasteboardType.tiff.rawValue: tiff])
    }

    @Test func testRTFAndHTMLAndTextRoundTrip() throws {
        let attributed = NSAttributedString(string: "粗体 English 中文", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = Data("<html><body><b>粗体 English 中文</b></body></html>".utf8)
        try roundTrip([NSPasteboard.PasteboardType.rtf.rawValue: rtf,
                       NSPasteboard.PasteboardType.html.rawValue: html,
                       NSPasteboard.PasteboardType.string.rawValue: Data(attributed.string.utf8)])
    }

    @Test func testMultipleFileURLItemsRetainOrderAndTypes() throws {
        try withPasteboards { source, destination in
            let urls = [URL(fileURLWithPath: "/tmp/ClipFlow M0 first.txt"),
                        URL(fileURLWithPath: "/tmp/ClipFlow M0 second.png")]
            let expected = PasteboardSnapshot(items: urls.map {
                .init(representations: [NSPasteboard.PasteboardType.fileURL.rawValue: Data($0.absoluteString.utf8),
                                        "org.clipflow.test.private": Data([0, 255, 1])])
            })
            try expected.write(to: source)
            let captured = try PasteboardSnapshot.capture(from: source)
            #expect((captured) == (expected))
            try captured.write(to: destination)
            #expect((try PasteboardSnapshot.capture(from: destination)) == (expected))
            let restoredURLs = destination.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            #expect((restoredURLs) == (urls))
        }
    }

    @Test func testUnknownPrivateBinaryTypeRetained() throws {
        try roundTrip(["org.clipflow.test.private-binary": Data([0, 0, 254, 255, 13, 10])])
    }

    @Test func testSensitiveMarkersRejectedBeforePayloadRead() throws {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType", "com.vendor.password-type"] {
            try withPasteboards { source, _ in
                let item = NSPasteboardItem()
                item.setString("test fixture", forType: .string)
                item.setData(Data(), forType: .init(marker))
                source.clearContents()
                #expect(source.writeObjects([item]))
                expectThrows(try PasteboardSnapshot.capture(from: source)) { error in
                    #expect((error as? PasteboardSnapshotError) == (.sensitiveType(marker)))
                }
            }
        }
    }

    @Test func testFilePromisesRejected() throws {
        try withPasteboards { source, _ in
            let promiseType = "com.apple.pasteboard.promised-file-url"
            let item = NSPasteboardItem()
            item.setData(Data("promise".utf8), forType: .init(promiseType))
            source.clearContents()
            #expect(source.writeObjects([item]))
            expectThrows(try PasteboardSnapshot.capture(from: source)) { error in
                #expect((error as? PasteboardSnapshotError) == (.unsupportedFilePromise(promiseType)))
            }
        }
    }

    @Test func testSizeLimitCountsAllRepresentationsAndItemsWithoutTruncation() throws {
        try withPasteboards { source, _ in
            let expected = PasteboardSnapshot(items: [
                .init(representations: ["org.clipflow.test.a": Data([1, 2, 3]), "org.clipflow.test.b": Data([4, 5])]),
                .init(representations: ["org.clipflow.test.c": Data([6, 7])])
            ])
            try expected.write(to: source)
            expectThrows(try PasteboardSnapshot.capture(from: source, maxBytes: 6)) { error in
                #expect((error as? PasteboardSnapshotError) == (.sizeLimitExceeded(limit: 6)))
            }
            #expect((try PasteboardSnapshot.capture(from: source, maxBytes: 7)) == (expected))
        }
    }

    @Test func testEmptySnapshotClearsDestination() throws {
        try withPasteboards { source, _ in
            try PasteboardSnapshot.text("fixture").write(to: source)
            try PasteboardSnapshot(items: []).write(to: source)
            #expect((try PasteboardSnapshot.capture(from: source)) == (.init(items: [])))
        }
    }

    @Test func testInvalidItemDoesNotClearDestination() throws {
        try withPasteboards { source, _ in
            let original = PasteboardSnapshot.text("fixture")
            try original.write(to: source)
            let invalid = PasteboardSnapshot(items: [.init(representations: [:])])
            expectThrows(try invalid.write(to: source))
            #expect((try PasteboardSnapshot.capture(from: source)) == (original))
        }
    }

    @Test func testFingerprintNormalizesTypeOrderButPreservesFormatsAndItems() {
        let a = PasteboardItemSnapshot(representations: ["public.utf8-plain-text": Data("same".utf8),
                                                        "public.html": Data("<b>same</b>".utf8)])
        let reordered = PasteboardItemSnapshot(representations: ["public.html": Data("<b>same</b>".utf8),
                                                                "public.utf8-plain-text": Data("same".utf8)])
        let plain = PasteboardItemSnapshot(representations: ["public.utf8-plain-text": Data("same".utf8)])
        #expect((PasteboardSnapshot(items: [a]).fingerprint) == (PasteboardSnapshot(items: [reordered]).fingerprint))
        #expect((PasteboardSnapshot(items: [a]).fingerprint) != (PasteboardSnapshot(items: [plain]).fingerprint))
        #expect((PasteboardSnapshot(items: [a, plain]).fingerprint) != (PasteboardSnapshot(items: [plain, a]).fingerprint))
        #expect((PasteboardSnapshot(items: [.init(representations: ["ab": Data("c".utf8)])]).fingerprint) != (PasteboardSnapshot(items: [.init(representations: ["a": Data("bc".utf8)])]).fingerprint))
    }

    @Test func testCodableRetainsBinaryAndItemOrder() throws {
        let expected = PasteboardSnapshot(items: [.init(representations: ["private": Data([0, 255])]),
                                                   .init(representations: ["public.utf8-plain-text": Data("中文😀".utf8)])])
        #expect((try JSONDecoder().decode(PasteboardSnapshot.self, from: JSONEncoder().encode(expected))) == (expected))
    }

    @Test func testPlainTextDoesNotFlattenMultipleItems() {
        #expect((PasteboardSnapshot.text("中文😀\nline").plainText) == ("中文😀\nline"))
        #expect((PasteboardSnapshot(items: PasteboardSnapshot.text("a").items + PasteboardSnapshot.text("b").items).plainText) == nil)
    }
}
