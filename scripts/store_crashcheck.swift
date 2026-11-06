import Foundation
import CryptoKit
import CSQLite
import Darwin

// Standalone M1 test executable. All data is a known fixture in a dedicated
// temporary directory supplied by test_crash.py. This never opens user history,
// accesses NSPasteboard.general, posts CGEvents, or launches either .app.
private struct FixtureIdentity: Codable {
    let id: UUID
    let fingerprint: String
}
private struct FixtureBaseline: Codable {
    let identities: [FixtureIdentity]
}
private enum FixtureFailure: Error { case failed(String) }

private func requireFixture(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw FixtureFailure.failed(reason) }
}
private func blobHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func emitFixture(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

private func readReferenceHashes(directory: URL) throws -> Set<String> {
    var opened: OpaquePointer?
    let code = sqlite3_open_v2(directory.appendingPathComponent("history.sqlite3").path,
                               &opened, SQLITE_OPEN_READONLY, nil)
    guard code == SQLITE_OK, let opened else {
        if let opened { sqlite3_close_v2(opened) }
        throw FixtureFailure.failed("reference_open")
    }
    defer { sqlite3_close_v2(opened) }
    var query: OpaquePointer?
    guard sqlite3_prepare_v2(opened, "SELECT manifest FROM history", -1, &query, nil) == SQLITE_OK,
          let query else { throw FixtureFailure.failed("reference_prepare") }
    defer { sqlite3_finalize(query) }
    var hashes: Set<String> = []
    var records = 0
    while true {
        let step = sqlite3_step(query)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW, let text = sqlite3_column_text(query, 0) else {
            throw FixtureFailure.failed("reference_step")
        }
        let json = Data(String(cString: text).utf8)
        guard let descriptor = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              descriptor["version"] as? Int == 1,
              let items = descriptor["items"] as? [[String: Any]], items.count == 1,
              let representations = items[0]["representations"] as? [[String: Any]],
              representations.count == 1,
              representations[0]["type"] as? String == "public.utf8-plain-text",
              representations[0]["length"] as? Int == 1,
              let hash = representations[0]["hash"] as? String else {
            throw FixtureFailure.failed("reference_manifest")
        }
        hashes.insert(hash)
        records += 1
    }
    try requireFixture(records == 3, "reference_record_count")

    var sequence: OpaquePointer?
    guard sqlite3_prepare_v2(opened, "SELECT value FROM store_state WHERE key='sort_sequence'", -1, &sequence, nil) == SQLITE_OK,
          let sequence else { throw FixtureFailure.failed("sequence_prepare") }
    defer { sqlite3_finalize(sequence) }
    guard sqlite3_step(sequence) == SQLITE_ROW, sqlite3_column_int64(sequence, 0) == 3 else {
        throw FixtureFailure.failed("sequence_not_rolled_back")
    }
    return hashes
}

@main
private struct StoreCrashcheck {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, ["committed", "uncommitted", "check"].contains(arguments[1]) else {
            emitFixture(["event": "failed", "reason": "invalid_fixture_arguments"])
            exit(2)
        }
        let mode = arguments[1]
        let fixtureRoot = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let directory = fixtureRoot.appendingPathComponent("history", isDirectory: true)
        let baselineURL = fixtureRoot.appendingPathComponent("expected-fixture-identities.json")
        do {
            let store = try HistoryStore(directory: directory)
            if mode == "committed" {
                var records: [HistoryRecord] = []
                for text in ["A", "B", "C"] {
                    records.append(try await store.record(snapshot: .text(text), sourceBundleID: "org.clipflow.crash-fixture"))
                }
                let baseline = FixtureBaseline(identities: records.reversed().map {
                    FixtureIdentity(id: $0.id, fingerprint: $0.fingerprint)
                })
                try JSONEncoder().encode(baseline).write(to: baselineURL, options: .atomic)
                let stats = try await store.stats()
                emitFixture(["event": "ready", "mode": mode, "recordCount": stats.recordCount,
                             "blobCount": stats.blobCount])
                // The Python parent must deliver real SIGKILL after reading READY.
                while true { try await Task.sleep(nanoseconds: 60_000_000_000) }
            } else if mode == "uncommitted" {
                try requireFixture(try await store.load().map { $0.snapshot.plainText } == ["C", "B", "A"], "pre_interrupt_order")
                await store.setBeforeCommitHookForTesting {
                    // All D payload fsync and SQLite mutations have completed, but
                    // COMMIT has not run. No thrown-error simulation is involved.
                    emitFixture(["event": "ready", "mode": "uncommitted", "recordCount": 3,
                                 "fixtureBlobWritten": true])
                    while true { _ = pause() }
                }
                _ = try await store.record(snapshot: .text("D"), sourceBundleID: "org.clipflow.crash-fixture")
                throw FixtureFailure.failed("uncommitted_hook_returned")
            } else {
                guard arguments.count == 4, let expectedOrphans = Int(arguments[3]), [0, 1].contains(expectedOrphans) else {
                    throw FixtureFailure.failed("check_orphan_argument")
                }
                let baseline = try JSONDecoder().decode(FixtureBaseline.self, from: Data(contentsOf: baselineURL))
                let records = try await store.load()
                try requireFixture(records.map { $0.snapshot.plainText } == ["C", "B", "A"], "recovered_order")
                try requireFixture(records.map(\.id) == baseline.identities.map(\.id), "recovered_identity")
                try requireFixture(records.map(\.fingerprint) == baseline.identities.map(\.fingerprint), "recovered_fingerprint")
                try requireFixture(records.allSatisfy { $0.sourceBundleID == "org.clipflow.crash-fixture" }, "recovered_source")
                let expectedHashes = Set(["A", "B", "C"].map { blobHash(Data($0.utf8)) })
                let references = try readReferenceHashes(directory: directory)
                try requireFixture(references == expectedHashes, "recovered_references")
                // load() itself verifies each blob's existence, length and SHA-256,
                // then recomputes the complete snapshot fingerprint against SQLite.
                let stats = try await store.stats()
                try requireFixture(stats.recordCount == 3, "recovered_record_count")
                try requireFixture(stats.blobCount == 3 + expectedOrphans, "recovered_blob_count")
                let dHash = blobHash(Data("D".utf8))
                try requireFixture(!references.contains(dHash), "uncommitted_blob_was_referenced")
                let orphanURL = directory.appendingPathComponent("blobs").appendingPathComponent(dHash)
                if expectedOrphans == 1 {
                    try requireFixture(FileManager.default.fileExists(atPath: orphanURL.path), "orphan_missing")
                    let orphan = try Data(contentsOf: orphanURL)
                    try requireFixture(orphan == Data("D".utf8), "orphan_corrupt")
                } else {
                    try requireFixture(!FileManager.default.fileExists(atPath: orphanURL.path), "unexpected_orphan")
                }
                emitFixture(["event": "checked", "result": "passed", "recordCount": stats.recordCount,
                             "blobCount": stats.blobCount, "referenceCount": references.count,
                             "orphanCount": expectedOrphans, "identitiesEqual": true,
                             "fingerprintsEqual": true, "orderEqual": true])
            }
        } catch FixtureFailure.failed(let reason) {
            emitFixture(["event": "failed", "reason": reason, "mode": mode])
            exit(1)
        } catch {
            // Fixed error code only; no clipboard payloads or user file paths.
            emitFixture(["event": "failed", "reason": "fixture_storage_error", "mode": mode])
            exit(1)
        }
    }
}
