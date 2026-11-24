import Foundation

/// Stable record identities, independent of history ordering. Missing bindings are
/// removed by the app only after the store confirms the record no longer exists.
public struct ShortcutSlots: Codable, Equatable, Sendable {
    public private(set) var bindings: [Int: UUID] = [:]
    public init() {}
    public mutating func bind(_ id: UUID?, to slot: Int) {
        guard (1...12).contains(slot) else { return }
        bindings[slot] = id
    }
    public mutating func remove(_ id: UUID) { bindings = bindings.filter { $0.value != id } }
    public func resolve(newest: [UUID]) -> [UUID?] {
        let fixed = Set(bindings.values)
        var rolling = newest.filter { !fixed.contains($0) }.makeIterator()
        return (1...12).map { bindings[$0] ?? rolling.next() }
    }
    public static func load(from defaults: UserDefaults) throws -> Self {
        guard let data = defaults.data(forKey: "shortcutSlots.v1") else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.bindings.keys.allSatisfy({ (1...12).contains($0) }) else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
    public func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "shortcutSlots.v1")
    }
}
