import Foundation
import Testing
@testable import ClipFlowCore

@Suite struct ShortcutSlotsTests {
    @Test func rollingHistorySkipsPinnedIdentitiesAndPreservesPhysicalSlots() {
        let ids = (0..<20).map { _ in UUID() }
        var settings = ShortcutSlots()
        for slot in 9...12 { settings.bind(ids[slot], to: slot) }
        let resolved = settings.resolve(newest: ids)
        #expect(Array(resolved.prefix(8)) == ids.prefix(8).map(Optional.some))
        for slot in 9...12 { #expect(resolved[slot-1] == ids[slot]) }
        let new = UUID()
        let updated = settings.resolve(newest: [new] + ids)
        #expect(updated[0] == new)
        #expect(Array(updated.suffix(4)) == Array(resolved.suffix(4)))
    }
    @Test func sparseSlotsNeverRenumberAndSupportOneRecordOnMultipleKeys() {
        let fixed = UUID(), rolling = UUID(); var settings = ShortcutSlots()
        settings.bind(fixed, to: 10); settings.bind(fixed, to: 12)
        let result = settings.resolve(newest: [fixed, rolling])
        #expect(result[0] == rolling); #expect(result[1] == nil)
        #expect(result[9] == fixed); #expect(result[11] == fixed)
        #expect(result.count == 12)
    }
    @Test func reassignUnfixAndDeleteReturnRecordsToNormalHistory() {
        let a = UUID(), b = UUID(); var settings = ShortcutSlots()
        settings.bind(a, to: 9); settings.bind(b, to: 9)
        #expect(settings.resolve(newest: [a,b])[0] == a)
        settings.bind(nil, to: 9)
        #expect(settings.resolve(newest: [b,a])[0] == b)
        settings.bind(a, to: 1); settings.bind(a, to: 12); settings.remove(a)
        #expect(settings.bindings.isEmpty)
        settings.bind(b, to: 0); settings.bind(b, to: 13)
        #expect(settings.bindings.isEmpty)
    }
    @Test func fixedIdentitiesPersistAcrossSettingsReopen() throws {
        let suite = "ClipFlow.tests.slots.\(UUID())", id = UUID()
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        #expect(try ShortcutSlots.load(from: defaults).bindings.isEmpty)
        var settings = ShortcutSlots(); settings.bind(id, to: 11); try settings.save(to: defaults)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(try ShortcutSlots.load(from: reopened) == settings)
        defaults.set(Data("bad JSON".utf8), forKey: "shortcutSlots.v1")
        #expect(throws: (any Error).self) { try ShortcutSlots.load(from: defaults) }
    }
    @Test func metadataSelectionDoesNotChangeStoredFormatsOrOrdering() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let image = PasteboardSnapshot(items:[.init(representations:["public.png":Data([0,1,2])])])
        let a = try await store.record(snapshot: image), b = try await store.record(snapshot: .text("new"))
        var settings = ShortcutSlots(); settings.bind(a.id, to: 12)
        #expect(settings.resolve(newest: try await store.newestIDs(limit: 24))[11] == a.id)
        #expect(try await store.newestIDs(limit: 1) == [b.id])
        #expect(try await store.load(id: a.id).first?.snapshot == image)
        try await store.delete(id: a.id); settings.remove(a.id)
        #expect(settings.resolve(newest: try await store.newestIDs(limit: 24))[0] == b.id)
    }
}
