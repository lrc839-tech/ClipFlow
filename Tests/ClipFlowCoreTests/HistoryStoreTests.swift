import Foundation
import Testing
import CSQLite
@testable import ClipFlowCore

@Suite(.serialized)
struct HistoryStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipFlowHistoryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func blobFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.count == 64 }
    }
    private func sql(_ directory: URL, _ statement: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK, let db else {
            throw HistoryStoreError.database(operation: "test open", code: SQLITE_ERROR)
        }
        defer { sqlite3_close(db) }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &query, nil) == SQLITE_OK, let query else {
            throw HistoryStoreError.database(operation: "test prepare", code: SQLITE_ERROR)
        }
        defer { sqlite3_finalize(query) }
        let code = sqlite3_step(query)
        guard code == SQLITE_ROW || code == SQLITE_DONE else {
            throw HistoryStoreError.database(operation: "test step", code: code)
        }
        if code == SQLITE_ROW, let text = sqlite3_column_text(query, 0) { return String(cString: text) }
        return nil
    }

    @Test func abcOrderAndReadDoesNotReorder() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        for text in ["A", "B", "C"] { try await store.record(snapshot: .text(text), sourceBundleID: "org.clipflow.tests") }
        #expect(try await store.load().map { $0.snapshot.plainText } == ["C", "B", "A"])
        _ = try await store.load(limit: 1).first?.snapshot
        #expect(try await store.load().map { $0.snapshot.plainText } == ["C", "B", "A"])
        #expect(try sql(dir, "PRAGMA user_version") == "2")
        #expect(try sql(dir, "PRAGMA journal_mode") == "wal")
    }

    @Test func duplicateMovesToFrontWithStableIDAndCount() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let first = try await store.record(snapshot: .text("A"), sourceBundleID: "first.app")
        try await store.record(snapshot: .text("B"))
        let duplicate = try await store.record(snapshot: .text("A"), sourceBundleID: "second.app")
        let loaded = try await store.load()
        #expect(duplicate.id == first.id)
        #expect(loaded.map { $0.snapshot.plainText } == ["A", "B"])
        #expect(loaded.first?.sourceBundleID == "second.app")
        #expect((try await store.stats()).recordCount == 2)
    }

    @Test func reopenPreservesOrderUUIDAndMetadata() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var store: HistoryStore? = try HistoryStore(directory: dir)
        let a = try await store!.record(snapshot: .text("重启 A"), sourceBundleID: "org.clipflow.fixture")
        let b = try await store!.record(snapshot: .text("重启 B"))
        store = nil
        let reopened = try HistoryStore(directory: dir)
        let records = try await reopened.load()
        #expect(records.map(\.id) == [b.id, a.id])
        #expect(records.map { $0.snapshot.plainText } == ["重启 B", "重启 A"])
        let restoredDate = try #require(records.last?.copiedAt)
        #expect(abs(restoredDate.timeIntervalSince(a.copiedAt)) < 0.000001)
        #expect(records.last?.sourceBundleID == a.sourceBundleID)
    }

    @Test func multipleItemsAndBinaryRepresentationsUseIndependentBlobs() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let snapshot = PasteboardSnapshot(items: [
            .init(representations: ["public.png": Data([0, 255, 137, 80]), "org.clipflow.private": Data([1, 0, 254])]),
            .init(representations: ["public.html": Data("<b>fixture</b>".utf8), "public.utf8-plain-text": Data("fixture".utf8)])
        ])
        try await store.record(snapshot: snapshot)
        #expect(try await store.load().first?.snapshot == snapshot)
        let files = try blobFiles(dir)
        #expect(files.count == 4)
        let storedPayloads = try files.map { try Data(contentsOf: $0) }
        #expect(Set(storedPayloads) == Set(snapshot.items.flatMap { Array($0.representations.values) }))
        let manifest = try #require(try sql(dir, "SELECT manifest FROM history"))
        let descriptor = try #require(try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any])
        #expect(descriptor["version"] as? Int == 1)
        let items = try #require(descriptor["items"] as? [[String: Any]])
        let references = try #require(items.first?["representations"] as? [[String: Any]])
        #expect(Set(references[0].keys) == Set(["hash", "length", "type"]))
        #expect(try sql(dir, "SELECT typeof(manifest) FROM history") == "text")
    }

    @Test func missingBlobIsReportedWithoutDeletingIndex() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        try await store.record(snapshot: .text("missing fixture"))
        let file = try #require(try blobFiles(dir).first)
        try FileManager.default.removeItem(at: file)
        do { _ = try await store.load(); Issue.record("Missing blob must fail") }
        catch { #expect(error as? HistoryStoreError == .missingBlob) }
        let reopened = try HistoryStore(directory: dir)
        #expect((try await reopened.stats()).recordCount == 1)
        do { _ = try await reopened.load(); Issue.record("Reopen must preserve the failure") }
        catch { #expect(error as? HistoryStoreError == .missingBlob) }
    }

    @Test func sameLengthCorruptionIsRejectedBySHA() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        try await store.record(snapshot: .text("fixture"))
        let file = try #require(try blobFiles(dir).first)
        try Data("corrupt".utf8).write(to: file)
        do { _ = try await store.load(); Issue.record("Corrupt bytes must fail") }
        catch { #expect(error as? HistoryStoreError == .corruptBlob) }
        #expect((try await store.stats()).recordCount == 1)
        #expect(try Data(contentsOf: file) == Data("corrupt".utf8))
    }

    @Test func unknownNewSchemaIsRejectedAndUntouched() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sql(dir, "PRAGMA user_version=99")
        _ = try sql(dir, "CREATE TABLE future_data(value TEXT)")
        do { _ = try HistoryStore(directory: dir); Issue.record("Future schema must fail") }
        catch { #expect(error as? HistoryStoreError == .unsupportedSchema(99)) }
        #expect(try sql(dir, "PRAGMA user_version") == "99")
        #expect(try sql(dir, "SELECT name FROM sqlite_master WHERE name='future_data'") == "future_data")
    }

    @Test func unrelatedVersionZeroDatabaseIsNotOverwritten() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sql(dir, "CREATE TABLE user_data(value TEXT)")
        do { _ = try HistoryStore(directory: dir); Issue.record("Unrelated database must fail") }
        catch { #expect(error as? HistoryStoreError == .incompatibleDatabase) }
        #expect(try sql(dir, "SELECT name FROM sqlite_master WHERE name='user_data'") == "user_data")
    }

    @Test func deleteAndClearAreLogicalAndDoNotResetSequence() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let a = try await store.record(snapshot: .text("A"))
        let b = try await store.record(snapshot: .text("B"))
        try await store.delete(id: b.id)
        #expect(try await store.load().map(\.id) == [a.id])
        try await store.record(snapshot: .text("C"))
        #expect(try sql(dir, "SELECT value FROM store_state WHERE key='sort_sequence'") == "3")
        try await store.clear()
        #expect(try await store.load().isEmpty)
        #expect((try await store.stats()).recordCount == 0)
        #expect((try await store.stats()).blobCount == 3)
        try await store.record(snapshot: .text("D"))
        #expect(try sql(dir, "SELECT sort_index FROM history") == "4")
        let reopened = try HistoryStore(directory: dir)
        #expect(try await reopened.load().map { $0.snapshot.plainText } == ["D"])
    }

    @Test func boundedLoadPreservesUnlimitedHistoryAndReportsTotal() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        for index in 0..<20 { try await store.record(snapshot: .text(String(index))) }
        let newest = try await store.load(limit: 12)
        #expect(newest.count == 12)
        #expect(newest.first?.snapshot.plainText == "19")
        #expect(newest.last?.snapshot.plainText == "8")
        #expect((try await store.stats()).recordCount == 20)
        #expect(try await store.load(limit: 0).isEmpty)
        do { _ = try await store.load(limit: -1); Issue.record("Negative limit must fail") }
        catch { #expect(error as? HistoryStoreError == .invalidLimit) }
    }

    @Test func failedBlobWriteRollsBackMetadataAndSequence() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let originalBytes = Data("fixture".utf8)
        try await store.record(snapshot: .text("fixture"))
        let originalFile = try #require(try blobFiles(dir).first)
        try Data("corrupt".utf8).write(to: originalFile)
        let mixed = PasteboardSnapshot(items: [.init(representations: [
            "org.clipflow.first": Data("new bytes".utf8), "org.clipflow.second": originalBytes
        ])])
        do { try await store.record(snapshot: mixed); Issue.record("Must not reference corrupted blob") }
        catch { #expect(error as? HistoryStoreError == .corruptBlob) }
        #expect((try await store.stats()).recordCount == 1)
        #expect(try sql(dir, "SELECT value FROM store_state WHERE key='sort_sequence'") == "1")
        try originalBytes.write(to: originalFile)
        let reopened = try HistoryStore(directory: dir)
        #expect(try await reopened.load().map { $0.snapshot.plainText } == ["fixture"])
        try await reopened.record(snapshot: .text("after rollback"))
        #expect(try sql(dir, "SELECT MAX(sort_index) FROM history") == "2")
    }

    @Test func blobsAreDeduplicatedAcrossDifferentTypesButRecordsAreDistinct() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let bytes = Data("same bytes".utf8)
        let plain = PasteboardSnapshot(items: [.init(representations: ["public.utf8-plain-text": bytes])])
        let html = PasteboardSnapshot(items: [.init(representations: ["public.html": bytes])])
        try await store.record(snapshot: plain)
        try await store.record(snapshot: html)
        let stats = try await store.stats()
        #expect(stats.recordCount == 2)
        #expect(stats.blobCount == 1)
        #expect(stats.blobBytes == Int64(bytes.count))
        #expect(stats.databaseBytes > 0)
        #expect(stats.totalBytes == stats.blobBytes + stats.databaseBytes)
    }

    @Test func emptyAndSensitiveSnapshotsAreNotPersisted() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let fixtures = [PasteboardSnapshot(items: []),
                        PasteboardSnapshot(items: [.init(representations: [:])]),
                        PasteboardSnapshot(items: [.init(representations: ["org.nspasteboard.ConcealedType": Data()])])]
        for snapshot in fixtures {
            do { try await store.record(snapshot: snapshot); Issue.record("Invalid snapshot must fail") }
            catch { #expect(error as? HistoryStoreError == .invalidSnapshot) }
        }
        #expect((try await store.stats()).recordCount == 0)
        #expect((try await store.stats()).blobCount == 0)
    }
}
