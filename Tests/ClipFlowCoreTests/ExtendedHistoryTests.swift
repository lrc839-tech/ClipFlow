import AppKit
import Testing
import CSQLite
@testable import ClipFlowCore

struct ExtendedHistoryTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func sql(_ directory: URL, _ text: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path,&db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,text,nil,nil,nil) == SQLITE_OK)
    }
    @Test func pinsPersistAndStayAheadOfNewCopiesWithoutChangingIdentity() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try HistoryStore(directory:dir)
        let a = try await store.record(snapshot:.text("A"))
        let b = try await store.record(snapshot:.text("B"))
        try await store.setPinned(id:a.id,pinned:true)
        let c = try await store.record(snapshot:.text("C"))
        #expect(try await store.load().map(\.id) == [a.id,c.id,b.id])
        _ = try await store.record(snapshot:.text("B"))
        #expect(try await store.load().map(\.id) == [a.id,b.id,c.id])
        try await store.setPinned(id:c.id,pinned:true)
        #expect(try await store.load(limit:2).map(\.id) == [c.id,a.id])
        let reopened = try HistoryStore(directory:dir)
        #expect(try await reopened.pinnedIDs() == Set([a.id,c.id]))
        #expect(try await reopened.load().map(\.id) == [c.id,a.id,b.id])
        try await reopened.setPinned(id:a.id,pinned:false)
        #expect(try await reopened.load().map(\.id) == [c.id,b.id,a.id])
    }
    @Test func versionOneMigratesAndSummarySearchFindsOlderRecords() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try HistoryStore(directory:dir)
        let old = try await store.record(snapshot:.text("older searchable 中文"))
        for index in 0..<20 { _ = try await store.record(snapshot:.text("entry \(index)")) }
        try sql(dir,"ALTER TABLE history DROP COLUMN pinned_rank; PRAGMA user_version=1")
        let migrated = try HistoryStore(directory:dir)
        #expect(try await migrated.load().count == 21)
        #expect(try await migrated.summaries(query:"searchable").map(\.id) == [old.id])
        #expect(try await migrated.load(limit:1,id:old.id).first?.snapshot.plainText == "older searchable 中文")
        #expect(try await migrated.summaries(offset:20,limit:50).count == 1)
    }
    @Test func imagesPDFFilesAndPrivateFormatsPersistWithAllItems() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try HistoryStore(directory:dir)
        for (type,kind) in [("public.png","image"),("public.tiff","image"),("public.jpeg","image"),("com.adobe.pdf","pdf"),("public.html","rich"),("org.example.private","custom")] {
            let snapshot = PasteboardSnapshot(items:[.init(representations:[type:Data([0,255,1])])])
            let row = try await store.record(snapshot:snapshot)
            #expect(try await store.load(limit:1,id:row.id).first?.snapshot == snapshot)
            #expect(try await store.summaries(kind:kind).contains { $0.id == row.id })
            #expect(snapshot.requiresSystemPaste)
        }
        let file = dir.appendingPathComponent("source.txt"); try Data("fixture".utf8).write(to:file)
        let snap = PasteboardSnapshot(items:[.init(representations:["public.file-url":Data(file.absoluteString.utf8)])])
        try snap.validateFileReferences()
        let row = try await store.record(snapshot:snap)
        #expect(try await store.summaries(query:"source.txt").first?.id == row.id)
        try FileManager.default.removeItem(at:file)
        #expect(throws:FileReferenceError.self) { try snap.validateFileReferences() }
    }
}

struct MarkdownTests {
    @Test func markdownBytesAndPlainTextFallbackArePreserved() throws {
        let source = "# 标题\n\n- 条目\n\n```swift\nlet x = 1\n```\n[链接](https://example.com)\n"
        let snapshot = PasteboardSnapshot(items:[.init(representations:["net.daringfireball.markdown":Data(source.utf8)])])
        #expect(snapshot.contentKind == "markdown")
        #expect(snapshot.plainText == source)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try snapshot.forSystemPaste.write(to:board)
        let capture = try PasteboardSnapshot.capture(from:board)
        #expect(capture.items[0].representations["net.daringfireball.markdown"] == Data(source.utf8))
        #expect(board.string(forType:.string) == source)
        #expect(PasteboardSnapshot.text(source).plainText == source)
    }
}

struct SummaryUnicodeTests {
    @Test func truncatedUnicodeSummaryRemainsSearchable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = try HistoryStore(directory:dir)
        let source = String(repeating:"中文",count:1000)
        let row = try await store.record(snapshot:.text(source))
        #expect(try await store.summaries(query:"中文").first?.id == row.id)
        #expect(try await store.load(limit:1,id:row.id).first?.snapshot.plainText == source)
    }
}

struct FilePasteCompatibilityTests {
    @Test func outgoingFilesRetainTwoOrderedReferences() throws {
        let urls = [URL(fileURLWithPath:"/tmp/alpha.txt"),URL(fileURLWithPath:"/tmp/beta.txt")]
        let snapshot = PasteboardSnapshot(items:urls.map { .init(representations:["public.file-url":Data($0.absoluteString.utf8)]) })
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try snapshot.forSystemPaste.write(to:board)
        #expect(board.pasteboardItems?.count == 2)
        #expect((board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) == urls)
    }
}
