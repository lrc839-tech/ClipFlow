import Foundation
import CryptoKit
import CSQLite
import Darwin
import UniformTypeIdentifiers

public struct HistoryImageResource: Sendable {
    public let url: URL
    public let fingerprint: String
    public let isRTFD: Bool
}

public struct CompletedRichTextImages: Sendable {
    public let snapshot: PasteboardSnapshot
    public let imageCount: Int
    public init(snapshot: PasteboardSnapshot, imageCount: Int) { self.snapshot = snapshot; self.imageCount = imageCount }
}

public struct HistoryRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let fingerprint: String
    public let copiedAt: Date
    public let sourceBundleID: String?
    public let snapshot: PasteboardSnapshot
}

public struct HistoryStorageStats: Codable, Sendable {
    public let recordCount: Int
    public let blobCount: Int
    public let blobBytes: Int64
    public let databaseBytes: Int64
    public var totalBytes: Int64 { blobBytes + databaseBytes }
}

public enum HistoryStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case incompatibleDatabase
    case database(operation: String, code: Int32)
    case fileIO(operation: String)
    case invalidSnapshot
    case snapshotTooLarge
    case invalidLimit
    case corruptIndex
    case missingBlob
    case corruptBlob
    case sortSequenceExhausted

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "历史数据库版本 \(version) 不受此版本支持；原数据库未迁移或覆盖。"
        case .incompatibleDatabase: return "该存储位置已有其他数据库，已拒绝覆盖。"
        case let .database(operation, code): return "历史数据库\(operation)失败（SQLite \(code)），请检查磁盘和存储位置。"
        case let .fileIO(operation): return "历史数据文件\(operation)失败；未静默删除历史。"
        case .invalidSnapshot: return "该剪贴板快照为空、敏感或结构无效，未保存。"
        case .snapshotTooLarge: return "快照超过本版本可物化的 64 MiB 限制，未保存部分内容。"
        case .invalidLimit: return "历史读取条数不能为负数。"
        case .corruptIndex: return "历史索引或数据描述损坏；原文件已保留，请先备份存储目录。"
        case .missingBlob: return "历史引用的数据文件缺失；原索引已保留，请恢复备份。"
        case .corruptBlob: return "历史数据文件长度或校验不符；原文件已保留，请恢复备份。"
        case .sortSequenceExhausted: return "历史排序序号已耗尽，已停止写入。"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class HistoryStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var result: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &result, nil)
        guard code == SQLITE_OK, let result else {
            if let result { sqlite3_finalize(result) }
            throw HistoryStoreError.database(operation: "准备查询", code: code)
        }
        statement = result
    }
    deinit { sqlite3_finalize(statement) }

    func bind(_ value: String?, at index: Int32) throws {
        let code: Int32
        if let value {
            guard value.utf8.count <= Int(Int32.max) else { throw HistoryStoreError.invalidSnapshot }
            code = value.utf8CString.withUnsafeBufferPointer {
                sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), sqliteTransient)
            }
        } else { code = sqlite3_bind_null(statement, index) }
        guard code == SQLITE_OK else { throw HistoryStoreError.database(operation: "绑定参数", code: code) }
    }
    func bind(_ value: Int64, at index: Int32) throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else { throw HistoryStoreError.database(operation: "绑定参数", code: code) }
    }
    func bind(_ value: Double, at index: Int32) throws {
        let code = sqlite3_bind_double(statement, index, value)
        guard code == SQLITE_OK else { throw HistoryStoreError.database(operation: "绑定参数", code: code) }
    }
    @discardableResult func next() throws -> Bool {
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw HistoryStoreError.database(operation: "执行查询", code: code)
    }
    func text(at index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8)
        else { throw HistoryStoreError.corruptIndex }
        return value
    }
    func optionalText(at index: Int32) throws -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return try text(at: index)
    }
    func integer(at index: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { throw HistoryStoreError.corruptIndex }
        return sqlite3_column_int64(statement, index)
    }
    func number(at index: Int32) throws -> Double {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else { throw HistoryStoreError.corruptIndex }
        let value = sqlite3_column_double(statement, index)
        guard value.isFinite else { throw HistoryStoreError.corruptIndex }
        return value
    }
}

private final class HistoryDatabase {
    let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw HistoryStoreError.database(operation: "打开", code: code)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5_000)
    }
    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard code == SQLITE_OK else { throw HistoryStoreError.database(operation: "事务或配置", code: code) }
    }
    func prepare(_ sql: String) throws -> HistoryStatement { try HistoryStatement(database: handle, sql: sql) }

    func scalarInteger(_ sql: String) throws -> Int64 {
        let query = try prepare(sql)
        guard try query.next() else { throw HistoryStoreError.corruptIndex }
        return try query.integer(at: 0)
    }
    func scalarText(_ sql: String) throws -> String {
        let query = try prepare(sql)
        guard try query.next() else { throw HistoryStoreError.corruptIndex }
        return try query.text(at: 0)
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            // Covers COMMIT failures too. sqlite3_exec errors never include bound payloads.
            try? execute("ROLLBACK")
            throw error
        }
    }
}

private struct HistoryManifest: Codable {
    let version: Int
    let items: [Item]
    struct Item: Codable { let representations: [Representation] }
    struct Representation: Codable {
        let type: String
        let hash: String
        let length: Int
    }
}

/// SQLite metadata and immutable, content-addressed binary files. No age/capacity
/// eviction is performed. Failed writes may leave unreferenced blobs; they are kept
/// for safe recovery rather than automatically deleting files after a crash.
/// delete/clear remove records, but intentionally retain blob files in M1. This is
/// logical deletion, not secure erasure; the UI must disclose that distinction.
public actor HistoryStore {
    private static let schemaVersion = 4
    private static let applicationID: Int64 = 0x43464C57
    private static let maximumSnapshotBytes = 64 * 1024 * 1024
    private let directory: URL
    private let blobDirectory: URL
    private let databaseURL: URL
    private let database: HistoryDatabase
    private var beforeCommitHookForTesting: (@Sendable () -> Void)?

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw HistoryStoreError.fileIO(operation: "创建目录") }
        self.directory = directory.standardizedFileURL
        blobDirectory = self.directory.appendingPathComponent("blobs", isDirectory: true)
        databaseURL = self.directory.appendingPathComponent("history.sqlite3")
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobDirectory.path)
        } catch { throw HistoryStoreError.fileIO(operation: "创建受保护目录") }
        let opened = try HistoryDatabase(url: databaseURL)
        database = opened
        let version = Int(try opened.scalarInteger("PRAGMA user_version"))
        guard version <= Self.schemaVersion else { throw HistoryStoreError.unsupportedSchema(version) }
        let application = try opened.scalarInteger("PRAGMA application_id")
        if version == 0 {
            let tableCount = try opened.scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            guard tableCount == 0, application == 0 else {
                throw HistoryStoreError.incompatibleDatabase
            }
        } else {
            guard (1...Self.schemaVersion).contains(version) else { throw HistoryStoreError.unsupportedSchema(version) }
            guard application == Self.applicationID else { throw HistoryStoreError.incompatibleDatabase }
        }
        // Validate ownership/version before changing the existing database's journal mode.
        guard try opened.scalarText("PRAGMA journal_mode=WAL").lowercased() == "wal" else {
            throw HistoryStoreError.database(operation: "启用 WAL", code: SQLITE_ERROR)
        }
        try opened.execute("PRAGMA synchronous=FULL")
        try opened.execute("PRAGMA foreign_keys=ON")
        if version == 0 {
            try opened.transaction {
                try opened.execute("CREATE TABLE history (id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT UNIQUE NOT NULL, copied_at REAL NOT NULL, source_bundle_id TEXT, sort_index INTEGER UNIQUE NOT NULL CHECK(sort_index > 0), manifest TEXT NOT NULL)")
                try opened.execute("CREATE TABLE store_state (key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL)")
                try opened.execute("INSERT INTO store_state(key,value) VALUES('sort_sequence',0)")
                try opened.execute("PRAGMA application_id=\(Self.applicationID)")
                try opened.execute("PRAGMA user_version=1")
            }
        }
        if version < 2 {
            try opened.transaction {
                try opened.execute("ALTER TABLE history ADD COLUMN pinned_rank INTEGER NOT NULL DEFAULT 0")
                try opened.execute("PRAGMA user_version=2")
            }
        }
        if version < 3 {
            try opened.transaction {
                let pins = try opened.prepare("SELECT id FROM history WHERE pinned_rank>0 ORDER BY pinned_rank ASC,sort_index ASC")
                var identifiers: [String] = []
                while try pins.next() { identifiers.append(try pins.text(at: 0)) }
                var sequence = try opened.scalarInteger("SELECT value FROM store_state WHERE key='sort_sequence'")
                guard sequence <= Int64.max - Int64(identifiers.count) else { throw HistoryStoreError.sortSequenceExhausted }
                for id in identifiers {
                    sequence += 1
                    let move = try opened.prepare("UPDATE history SET sort_index=? WHERE id=?")
                    try move.bind(sequence, at: 1)
                    try move.bind(id, at: 2)
                    _ = try move.next()
                }
                let advance = try opened.prepare("UPDATE store_state SET value=? WHERE key='sort_sequence'")
                try advance.bind(sequence, at: 1)
                _ = try advance.next()
                try opened.execute("UPDATE history SET pinned_rank=0")
                try opened.execute("PRAGMA user_version=3")
            }
        }
        if version < 4 {
            try opened.transaction {
                try opened.execute("CREATE TABLE prepared_history (history_id TEXT PRIMARY KEY NOT NULL REFERENCES history(id) ON DELETE CASCADE,source_fingerprint TEXT NOT NULL,fingerprint TEXT NOT NULL,manifest TEXT NOT NULL,image_count INTEGER NOT NULL CHECK(image_count>0))")
                try opened.execute("PRAGMA user_version=4")
            }
        }
        guard try opened.scalarText("PRAGMA quick_check") == "ok" else { throw HistoryStoreError.corruptIndex }
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path) }
        catch { throw HistoryStoreError.fileIO(operation: "设置索引权限") }
    }

    /// nil loads/validates the whole history; production can request just the newest 12.
    /// Any missing/corrupt payload aborts the read and preserves the original database.
    public func load(limit: Int? = nil, id: UUID? = nil, offset: Int = 0) throws -> [HistoryRecord] {
        if let limit, limit < 0 { throw HistoryStoreError.invalidLimit }
        if limit == 0 { return [] }
        var sql = "SELECT id,fingerprint,copied_at,source_bundle_id,manifest FROM history"
        if id != nil { sql += " WHERE id=?" }
        sql += " ORDER BY sort_index DESC"
        if let limit { sql += " LIMIT \(limit) OFFSET \(max(0,offset))" }
        let query = try database.prepare(sql)
        if let id { try query.bind(id.uuidString, at: 1) }
        var records: [HistoryRecord] = []
        while try query.next() {
            guard let id = UUID(uuidString: try query.text(at: 0)) else { throw HistoryStoreError.corruptIndex }
            let fingerprint = try query.text(at: 1)
            guard Self.validHash(fingerprint) else { throw HistoryStoreError.corruptIndex }
            let copiedAt = Date(timeIntervalSince1970: try query.number(at: 2))
            let source = try query.optionalText(at: 3)
            let manifestText = try query.text(at: 4)
            let manifest: HistoryManifest
            do { manifest = try JSONDecoder().decode(HistoryManifest.self, from: Data(manifestText.utf8)) }
            catch { throw HistoryStoreError.corruptIndex }
            let snapshot = try materialize(manifest)
            guard snapshot.fingerprint == fingerprint else { throw HistoryStoreError.corruptIndex }
            records.append(HistoryRecord(id: id, fingerprint: fingerprint, copiedAt: copiedAt,
                                         sourceBundleID: source, snapshot: snapshot))
        }
        return records
    }

    // Internal test seam only: no environment switch and no public production option.
    // A separately compiled test process can pause after payload fsync/SQL writes,
    // then be SIGKILLed before the transaction helper issues COMMIT.
    func setBeforeCommitHookForTesting(_ hook: (@Sendable () -> Void)?) {
        beforeCommitHookForTesting = hook
    }

    @discardableResult
    public func record(snapshot: PasteboardSnapshot, sourceBundleID: String? = nil) throws -> HistoryRecord {
        let manifest = try makeManifest(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestText: String
        do { manifestText = String(decoding: try encoder.encode(manifest), as: UTF8.self) }
        catch { throw HistoryStoreError.invalidSnapshot }
        let fingerprint = snapshot.fingerprint
        let now = Date()
        return try database.transaction {
            let sequenceQuery = try database.prepare("SELECT value FROM store_state WHERE key='sort_sequence'")
            guard try sequenceQuery.next() else { throw HistoryStoreError.corruptIndex }
            let previous = try sequenceQuery.integer(at: 0)
            guard previous >= 0, previous < Int64.max else { throw HistoryStoreError.sortSequenceExhausted }
            let sequence = previous + 1
            let existing = try database.prepare("SELECT id FROM history WHERE fingerprint=?")
            try existing.bind(fingerprint, at: 1)
            let id: UUID
            if try existing.next() {
                guard let existingID = UUID(uuidString: try existing.text(at: 0)) else { throw HistoryStoreError.corruptIndex }
                id = existingID
            } else { id = UUID() }
            // Durable payload first, metadata references only after every blob is valid.
            // A crash before COMMIT can leave orphans, never a deliberately committed
            // index pointing at a payload that has not been atomically written/synced.
            for item in snapshot.items {
                for data in item.representations.values { try persistBlob(data) }
            }
            let write = try database.prepare("INSERT INTO history(id,fingerprint,copied_at,source_bundle_id,sort_index,manifest) VALUES(?,?,?,?,?,?) ON CONFLICT(fingerprint) DO UPDATE SET copied_at=excluded.copied_at,source_bundle_id=excluded.source_bundle_id,sort_index=excluded.sort_index,manifest=excluded.manifest")
            try write.bind(id.uuidString, at: 1)
            try write.bind(fingerprint, at: 2)
            try write.bind(now.timeIntervalSince1970, at: 3)
            try write.bind(sourceBundleID, at: 4)
            try write.bind(sequence, at: 5)
            try write.bind(manifestText, at: 6)
            _ = try write.next()
            let advance = try database.prepare("UPDATE store_state SET value=? WHERE key='sort_sequence'")
            try advance.bind(sequence, at: 1)
            _ = try advance.next()
            beforeCommitHookForTesting?()
            return HistoryRecord(id: id, fingerprint: fingerprint, copiedAt: now,
                                 sourceBundleID: sourceBundleID, snapshot: snapshot)
        }
    }

    public func summaries(query: String = "", kind: String = "", offset: Int = 0, limit: Int = 50) throws -> [HistorySummary] {
        let rows = try database.prepare("SELECT id,copied_at,manifest,COALESCE((SELECT image_count FROM prepared_history WHERE history_id=history.id AND source_fingerprint=history.fingerprint),0) FROM history ORDER BY sort_index DESC")
        var result: [HistorySummary] = []
        var skipped = 0
        while try rows.next() {
            guard let id = UUID(uuidString: try rows.text(at: 0)),
                  let manifest = try? JSONDecoder().decode(HistoryManifest.self, from: Data(try rows.text(at: 2).utf8)) else { throw HistoryStoreError.corruptIndex }
            let types = manifest.items.flatMap { $0.representations.map(\.type) }
            let category = PasteboardSnapshot.contentKind(types: types)
            if !kind.isEmpty && category != kind { continue }
            var smallItems: [PasteboardItemSnapshot] = []
            for item in manifest.items {
                var representations: [String: Data] = [:]
                for ref in item.representations where ["public.utf8-plain-text", "public.file-url", "NSFilenamesPboardType", "net.daringfireball.markdown", "public.markdown", "text/markdown"].contains(ref.type) {
                    guard Self.validHash(ref.hash) else { throw HistoryStoreError.corruptIndex }
                    let url = blobDirectory.appendingPathComponent(ref.hash)
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw HistoryStoreError.corruptBlob }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let bytes = try file.read(upToCount: 4096) ?? Data()
                    if ["public.utf8-plain-text", "net.daringfireball.markdown", "public.markdown", "text/markdown"].contains(ref.type) {
                        representations[ref.type] = Data(String(decoding:bytes,as:UTF8.self).utf8)
                    } else { representations[ref.type] = bytes }
                }
                smallItems.append(.init(representations: representations))
            }
            let partial = PasteboardSnapshot(items: smallItems)
            let preview = category == "image" ? "图片" : category == "file" ? partial.fileURLs.map(\.lastPathComponent).joined(separator: "、") : (partial.plainText ?? ["pdf":"PDF 文档", "rich":"富文本", "custom":"自定义格式"][category] ?? category)
            if !query.isEmpty && !preview.localizedCaseInsensitiveContains(query) && !(partial.plainText ?? "").localizedCaseInsensitiveContains(query) && !types.joined(separator: " ").localizedCaseInsensitiveContains(query) { continue }
            if skipped < max(0,offset) { skipped += 1; continue }
            result.append(HistorySummary(id: id, preview: String(preview.prefix(500)), kind: category, pinned: false, copiedAt: try rows.number(at: 1), types: types, readyImageCount: Int(try rows.integer(at: 3))))
            if result.count >= min(100,max(1,limit)) { break }
        }
        return result
    }

    /// Derived image bytes are separate from the source fingerprint and copy order.
    /// A late download never resurrects a deleted record or moves newer copies down.
    @discardableResult
    public func savePreparedSnapshot(id: UUID, sourceFingerprint: String,
                                     result: CompletedRichTextImages) throws -> Bool {
        guard (1...12).contains(result.imageCount) else { throw HistoryStoreError.invalidSnapshot }
        let manifest = try makeManifest(result.snapshot)
        let encoded = try JSONEncoder().encode(manifest)
        return try database.transaction {
            let source = try database.prepare("SELECT fingerprint FROM history WHERE id=?")
            try source.bind(id.uuidString, at: 1)
            guard try source.next(), try source.text(at: 0) == sourceFingerprint else { return false }
            for item in result.snapshot.items {
                for bytes in item.representations.values { try persistBlob(bytes) }
            }
            let save = try database.prepare("INSERT INTO prepared_history(history_id,source_fingerprint,fingerprint,manifest,image_count) VALUES(?,?,?,?,?) ON CONFLICT(history_id) DO UPDATE SET source_fingerprint=excluded.source_fingerprint,fingerprint=excluded.fingerprint,manifest=excluded.manifest,image_count=excluded.image_count")
            try save.bind(id.uuidString, at: 1)
            try save.bind(sourceFingerprint, at: 2)
            try save.bind(result.snapshot.fingerprint, at: 3)
            try save.bind(String(decoding: encoded, as: UTF8.self), at: 4)
            try save.bind(Int64(result.imageCount), at: 5)
            _ = try save.next()
            return true
        }
    }

    public func preparedSnapshot(id: UUID) throws -> PasteboardSnapshot? {
        let query = try database.prepare("SELECT prepared_history.fingerprint,prepared_history.manifest FROM prepared_history JOIN history ON history.id=history_id AND history.fingerprint=source_fingerprint WHERE history_id=?")
        try query.bind(id.uuidString, at: 1)
        guard try query.next() else { return nil }
        let fingerprint = try query.text(at: 0)
        guard let manifest = try? JSONDecoder().decode(HistoryManifest.self, from: Data(try query.text(at: 1).utf8)) else { throw HistoryStoreError.corruptIndex }
        let snapshot = try materialize(manifest)
        guard snapshot.fingerprint == fingerprint else { throw HistoryStoreError.corruptIndex }
        return snapshot
    }

    /// Only trusted local blob URLs leave this actor; the preview worker reads
    /// them independently so image decoding cannot stall clipboard transactions.
    public func imagePreviewResources(id: UUID) throws -> [HistoryImageResource] {
        let query = try database.prepare("SELECT COALESCE((SELECT prepared_history.manifest FROM prepared_history WHERE history_id=history.id AND source_fingerprint=history.fingerprint),history.manifest) FROM history WHERE id=?")
        try query.bind(id.uuidString, at: 1)
        guard try query.next() else { return [] }
        guard let manifest = try? JSONDecoder().decode(HistoryManifest.self, from: Data(try query.text(at: 0).utf8)), manifest.version == 1 else { throw HistoryStoreError.corruptIndex }
        var result: [HistoryImageResource] = []
        for item in manifest.items {
            // Prefer a single native image per pasteboard item, avoiding duplicate
            // TIFF/PNG representations of the same photograph.
            let image = item.representations.first { $0.type == "public.png" } ?? item.representations.first { UTType($0.type)?.conforms(to: .image) == true }
            let rich = item.representations.first { $0.type == "com.apple.flat-rtfd" }
            guard let ref = rich ?? image else {
                // Older versions retained image-file references without pixels.
                // Preview only readable local image files; never fetch a URL.
                if let file = item.representations.first(where: { $0.type == "public.file-url" }),
                   Self.validHash(file.hash), file.length <= 64 * 1024,
                   let bytes = try? Data(contentsOf: blobDirectory.appendingPathComponent(file.hash)),
                   let text = String(data: bytes, encoding: .utf8), let raw = URL(string: text), raw.isFileURL {
                    let resolved = (raw as NSURL).filePathURL ?? raw
                    if UTType(filenameExtension: resolved.pathExtension)?.conforms(to: .image) == true,
                       let attrs = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                       attrs.isRegularFile == true, let length = attrs.fileSize, length <= Self.maximumSnapshotBytes {
                        result.append(.init(url: resolved, fingerprint: file.hash + ":\(length):\(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0)", isRTFD: false))
                    }
                }
                continue
            }
            guard Self.validHash(ref.hash), (0...Self.maximumSnapshotBytes).contains(ref.length) else { throw HistoryStoreError.corruptIndex }
            let url = blobDirectory.appendingPathComponent(ref.hash)
            let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs?.isRegularFile == true, attrs?.isSymbolicLink != true, attrs?.fileSize == ref.length else { throw HistoryStoreError.missingBlob }
            result.append(.init(url: url, fingerprint: ref.hash, isRTFD: rich != nil))
        }
        return result
    }

    public func setPinned(id: UUID, pinned: Bool) throws {
        if pinned { try moveToFront(id: id) }
    }

    public func moveToFront(id: UUID) throws {
        try database.transaction {
            let existing = try database.prepare("SELECT id FROM history WHERE id=?")
            try existing.bind(id.uuidString, at: 1)
            guard try existing.next() else { return }
            let previous = try database.scalarInteger("SELECT value FROM store_state WHERE key='sort_sequence'")
            guard previous < Int64.max else { throw HistoryStoreError.sortSequenceExhausted }
            let sequence = previous + 1
            let statement = try database.prepare("UPDATE history SET sort_index=?,pinned_rank=0 WHERE id=?")
            try statement.bind(sequence, at: 1)
            try statement.bind(id.uuidString, at: 2)
            _ = try statement.next()
            let advance = try database.prepare("UPDATE store_state SET value=? WHERE key='sort_sequence'")
            try advance.bind(sequence, at: 1)
            _ = try advance.next()
        }
    }

    public func pinnedIDs() throws -> Set<UUID> {
        let query = try database.prepare("SELECT id FROM history WHERE pinned_rank>0")
        var result = Set<UUID>()
        while try query.next() { if let id = UUID(uuidString: try query.text(at: 0)) { result.insert(id) } }
        return result
    }

    public func delete(id: UUID) throws {
        try database.transaction {
            let statement = try database.prepare("DELETE FROM history WHERE id=?")
            try statement.bind(id.uuidString, at: 1)
            _ = try statement.next()
        }
    }

    /// Logical deletion only in M1. Immutable blobs and SQLite free pages are retained.
    public func clear() throws { try database.transaction { try database.execute("DELETE FROM history") } }

    public func stats() throws -> HistoryStorageStats {
        let count = try database.prepare("SELECT COUNT(*) FROM history")
        guard try count.next() else { throw HistoryStoreError.corruptIndex }
        let recordCount = Int(try count.integer(at: 0))
        var blobCount = 0
        var blobBytes: Int64 = 0
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            for url in urls where Self.validHash(url.lastPathComponent) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    blobCount += 1
                    blobBytes += Int64(values.fileSize ?? 0)
                }
            }
            var databaseBytes: Int64 = 0
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) {
                    databaseBytes += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
            }
            return HistoryStorageStats(recordCount: recordCount, blobCount: blobCount,
                                       blobBytes: blobBytes, databaseBytes: databaseBytes)
        } catch { throw HistoryStoreError.fileIO(operation: "统计占用") }
    }

    private func makeManifest(_ snapshot: PasteboardSnapshot) throws -> HistoryManifest {
        guard !snapshot.items.isEmpty else { throw HistoryStoreError.invalidSnapshot }
        var total = 0
        let items = try snapshot.items.map { item -> HistoryManifest.Item in
            guard !item.representations.isEmpty else { throw HistoryStoreError.invalidSnapshot }
            let representations = try item.representations.keys.sorted().map { type -> HistoryManifest.Representation in
                let normalized = type.lowercased()
                guard !type.isEmpty, !normalized.contains("password"),
                      !["org.nspasteboard.concealedtype", "org.nspasteboard.transienttype", "org.nspasteboard.autogeneratedtype", "de.petermaurer.transientpasteboardtype", "com.agilebits.onepassword"].contains(normalized),
                      !normalized.hasPrefix("com.apple.pasteboard.promised-"),
                      normalized != "apple files promise pasteboard type" else { throw HistoryStoreError.invalidSnapshot }
                let data = item.representations[type]!
                guard data.count <= Self.maximumSnapshotBytes - total else { throw HistoryStoreError.snapshotTooLarge }
                total += data.count
                return .init(type: type, hash: Self.hash(data), length: data.count)
            }
            return .init(representations: representations)
        }
        return HistoryManifest(version: 1, items: items)
    }

    private func materialize(_ manifest: HistoryManifest) throws -> PasteboardSnapshot {
        guard manifest.version == 1, !manifest.items.isEmpty else { throw HistoryStoreError.corruptIndex }
        var total = 0
        let items = try manifest.items.map { item -> PasteboardItemSnapshot in
            guard !item.representations.isEmpty else { throw HistoryStoreError.corruptIndex }
            var representations: [String: Data] = [:]
            for reference in item.representations {
                guard !reference.type.isEmpty, representations[reference.type] == nil,
                      Self.validHash(reference.hash), reference.length >= 0 else { throw HistoryStoreError.corruptIndex }
                guard reference.length <= Self.maximumSnapshotBytes - total else { throw HistoryStoreError.snapshotTooLarge }
                total += reference.length
                let url = blobDirectory.appendingPathComponent(reference.hash)
                guard FileManager.default.fileExists(atPath: url.path) else { throw HistoryStoreError.missingBlob }
                let data: Data
                do {
                    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                          attributes.fileSize == reference.length else { throw HistoryStoreError.corruptBlob }
                    data = try Data(contentsOf: url)
                } catch let error as HistoryStoreError { throw error }
                catch { throw HistoryStoreError.fileIO(operation: "读取") }
                guard data.count == reference.length, Self.hash(data) == reference.hash else { throw HistoryStoreError.corruptBlob }
                representations[reference.type] = data
            }
            return PasteboardItemSnapshot(representations: representations)
        }
        return PasteboardSnapshot(items: items)
    }

    private func persistBlob(_ data: Data) throws {
        let hash = Self.hash(data)
        let url = blobDirectory.appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: url.path) {
            let saved: Data
            do {
                let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      attributes.fileSize == data.count else { throw HistoryStoreError.corruptBlob }
                saved = try Data(contentsOf: url)
            } catch let error as HistoryStoreError { throw error }
            catch { throw HistoryStoreError.fileIO(operation: "检查已有数据") }
            guard saved.count == data.count, Self.hash(saved) == hash else { throw HistoryStoreError.corruptBlob }
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let file = try FileHandle(forWritingTo: url)
            do { try file.synchronize(); try file.close() }
            catch { try? file.close(); throw error }
            let descriptor = open(blobDirectory.path, O_RDONLY)
            guard descriptor >= 0 else { throw HistoryStoreError.fileIO(operation: "同步数据目录") }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw HistoryStoreError.fileIO(operation: "同步数据目录") }
        } catch let error as HistoryStoreError { throw error }
        catch { throw HistoryStoreError.fileIO(operation: "原子写入和同步") }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct HistorySummary: Codable, Sendable {
    public let id: UUID
    public let preview: String
    public let kind: String
    public let pinned: Bool
    public let copiedAt: Double
    public let types: [String]
    public let readyImageCount: Int
}
