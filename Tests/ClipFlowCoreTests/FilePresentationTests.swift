import AppKit
import UniformTypeIdentifiers
import Testing
@testable import ClipFlowCore

@Suite(.serialized) @MainActor
struct FilePresentationTests {
    func fixtureIcon() throws -> Data {
        _ = NSApplication.shared
        return try #require(NSWorkspace.shared.icon(for: .data).tiffRepresentation)
    }
    func document(_ url: URL, type: String = "com.apple.icns", icon: Data) -> PasteboardSnapshot {
        .init(items: [.init(representations: ["public.file-url":Data(url.absoluteString.utf8),
            "public.utf8-plain-text":Data(url.lastPathComponent.utf8),type:icon])])
    }
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func finderDocumentIconNeverTurnsAFileIntoAnImageOrAnImagePaste() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("课件.pptx"); try Data("synthetic document".utf8).write(to: url)
        for type in ["com.apple.icns", "public.tiff", "public.png"] {
            let snapshot = document(url, type: type, icon: try fixtureIcon())
            #expect(snapshot.contentKind == "file")
            #expect(snapshot.summary == "课件.pptx")
            let outgoing = snapshot.forSystemPaste
            #expect(outgoing.fileURLs == [url])
            #expect(outgoing.items[0].representations[type] == nil)
            #expect(outgoing.plainText == nil)
            #expect(outgoing.requiresSystemPaste)
            try outgoing.validateFileReferences()
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            try outgoing.write(to: board)
            #expect((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL]) == [url])
        }
    }
    @Test func filePasteCannotOfferFilenameTextToATextFirstReceiver() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("report.docx")
        try Data("synthetic document".utf8).write(to: url)
        var raw = document(url, icon: try fixtureIcon())
        raw.items[0].representations["public.utf16-external-plain-text"] = url.lastPathComponent.data(using: .utf16)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try raw.write(to: board)
        // Reproduce the old failure: a text-first receiver chooses the filename.
        #expect(board.string(forType: .string) == "report.docx")
        let outgoing = raw.forSystemPaste
        try outgoing.write(to: board)
        #expect(board.availableType(from: [.string, .init("public.utf16-external-plain-text"), .fileURL]) == .fileURL)
        #expect(board.string(forType: .string) == nil)
        #expect(outgoing.forSystemPaste == outgoing)
        let native = NSPasteboard.withUniqueName(); defer { native.releaseGlobally() }
        native.clearContents()
        #expect(native.writeObjects([url as NSURL]))
        #expect(Set(board.pasteboardItems?.first?.types ?? []) == Set(native.pasteboardItems?.first?.types ?? []))
        #expect((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL]) == [url])
        #expect(raw.items[0].representations["public.utf8-plain-text"] != nil)
    }
    @Test func legacyFilesBecomeSeparateModernItemsAndKeepOrderAfterPersistence() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = ["文件 one.pptx", "two.docx", "folder"].map { dir.appendingPathComponent($0) }
        try Data("one".utf8).write(to: urls[0]); try Data("two".utf8).write(to: urls[1])
        try FileManager.default.createDirectory(at: urls[2], withIntermediateDirectories: true)
        let list = try PropertyListSerialization.data(fromPropertyList: urls.map(\.path), format: .binary, options: 0)
        let raw = PasteboardSnapshot(items: [.init(representations: ["NSFilenamesPboardType":list,
            "public.utf8-plain-text":Data("filename fallback".utf8),"public.html":Data("filename fallback".utf8)])])
        let store = try HistoryStore(directory: dir.appendingPathComponent("history"))
        let record = try await store.record(snapshot: raw)
        let loaded = try #require(try await store.load(id: record.id).first).snapshot
        #expect(loaded == raw)
        let outgoing = loaded.forSystemPaste
        try outgoing.validateFileReferences()
        #expect(outgoing.items.count == 3)
        #expect(outgoing.fileURLs.map(\.path) == urls.map(\.path))
        #expect(outgoing.items.allSatisfy { Set($0.representations.keys) == ["public.file-url"] })
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try outgoing.write(to: board)
        #expect((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL])?.map(\.path) == urls.map(\.path))
        #expect(board.string(forType: .string) == nil)
    }
    @Test func existingIconBearingFilesHaveNamesTypesAndNoPicturePreviewWithoutRewritingHistory() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir), previews = HistoryImagePreviews()
        let icon = try fixtureIcon()
        for (ext,label) in [("pptx","PowerPoint"),("docx","Word"),("xlsx","Excel"),("pdf","PDF")] {
            let url = URL(fileURLWithPath: "/tmp/missing-fixture.\(ext)")
            let snapshot = document(url, icon: icon)
            let record = try await store.record(snapshot: snapshot)
            let rows = try await store.summaries(kind: "file")
            let summary = try #require(rows.first { $0.id == record.id })
            #expect(summary.kind == "file"); #expect(summary.preview == url.lastPathComponent)
            #expect(summary.files.first?.name == url.lastPathComponent)
            #expect(summary.files.first?.typeLabel == label)
            #expect(try await previews.images(id: record.id, store: store).isEmpty)
            #expect(try await store.load(id: record.id).first?.snapshot == snapshot)
            #expect(try await store.load(id: record.id).first?.fingerprint == record.fingerprint)
            #expect(try await store.summaries(kind: "image").isEmpty)
        }
    }
    @Test func actualImageFileStillHasAnImageThumbnailAndImagePaste() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent("photo.png"); try png.write(to: url)
        let raw = document(url, icon: try fixtureIcon())
        let snapshot = try raw.materializingImageFiles()
        #expect(snapshot.contentKind == "image")
        #expect(snapshot.forSystemPaste.fileURLs.isEmpty)
        #expect(snapshot.forSystemPaste.items[0].representations["public.png"] != nil)
        #expect(snapshot.forSystemPaste.items[0].representations["com.apple.icns"] == nil)
        let store = try HistoryStore(directory: dir.appendingPathComponent("history"))
        let record = try await store.record(snapshot: snapshot)
        #expect(try await store.summaries(kind: "image").first?.id == record.id)
        #expect(try await HistoryImagePreviews().images(id: record.id, store: store).count == 1)
    }
    @Test func multipleFilesAndLegacyFilenameListsKeepTheirNamesAndFileMeaning() throws {
        let urls = [URL(fileURLWithPath: "/tmp/report.docx"),URL(fileURLWithPath: "/tmp/photo.png")]
        let list = try PropertyListSerialization.data(fromPropertyList: urls.map(\.path), format: .binary, options: 0)
        let legacy = PasteboardSnapshot(items: [.init(representations: ["NSFilenamesPboardType":list,"public.png":try fixtureIcon()])])
        #expect(legacy.contentKind == "file")
        #expect(legacy.summary == "report.docx、photo.png")
        #expect(legacy.forSystemPaste.fileURLs == urls)
        #expect(legacy.forSystemPaste.items[0].representations["public.png"] == nil)
        let icon = try fixtureIcon()
        let mixed = PasteboardSnapshot(items: urls.map { document($0, icon: icon).items[0] })
        #expect(mixed.contentKind == "file")
        #expect(mixed.forSystemPaste.fileURLs == urls)
        #expect(mixed.forSystemPaste.items.allSatisfy { $0.representations["com.apple.icns"] == nil })
    }
    @Test func systemTypeIconsRemainAvailableAfterSourceFileDisappears() throws {
        for ext in ["pptx","docx","xlsx","pdf","unknown"] {
            let file = HistoryFilePresentation(url: URL(fileURLWithPath: "/tmp/nonexistent.\(ext)"))
            let icon = HistoryFileIcons.image(for: file)
            #expect(icon.size == NSSize(width: 24, height: 24))
            let url = HistoryFileIcons.dataURL(for: file)
            let png = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
            #expect(NSImage(data: png) != nil)
        }
    }
    @Test func aBrokenFileReferenceCannotBecomeFilenameTextOrAPartialFilePaste() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("keep.txt"); try Data("fixture".utf8).write(to: url)
        let valid = document(url, icon: try fixtureIcon())
        let invalid = PasteboardItemSnapshot(representations: ["public.file-url":Data("https://example.invalid/not-a-file".utf8),
            "public.utf8-plain-text":Data("missing.docx".utf8)])
        let mixed = PasteboardSnapshot(items: valid.items + [invalid])
        #expect(mixed.forSystemPaste.items.count == 2)
        #expect(throws: FileReferenceError.self) { try mixed.forSystemPaste.validateFileReferences() }
        try FileManager.default.removeItem(at: url)
        #expect(valid.forSystemPaste.plainText == nil)
        #expect(throws: FileReferenceError.self) { try valid.forSystemPaste.validateFileReferences() }
    }
}
