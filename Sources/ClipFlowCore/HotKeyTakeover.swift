import Foundation
import Carbon

public enum HotKeyScheme: String, Codable, Sendable {
    case command, option
    public var symbol: String { self == .command ? "⌘" : "⌥" }
    public var name: String { self == .command ? "Command" : "Option" }
    public var carbonModifiers: UInt32 { self == .command ? UInt32(cmdKey) : UInt32(optionKey) }
}

public struct HotKeySettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var scheme: HotKeyScheme = .command
    public var excludedBundleIDs: Set<String> = []
    public init() {}
    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "hotKeyTakeover.v1"),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "hotKeyTakeover.v1") }
    }
    public static func parseExclusions(_ value: String) -> Set<String> {
        Set(value.components(separatedBy: CharacterSet(charactersIn: ",;\n "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 255 && $0.range(of: "^[a-zA-Z0-9][a-zA-Z0-9.\\-]*$", options: .regularExpression) != nil }
            .prefix(200))
    }
}

/// Owns registration state, independent of clipboard collection. No event replay or
/// active event tap: an excluded app receives its normal key stream after release.
@MainActor public final class HotKeyTakeover {
    public private(set) var settings: HotKeySettings
    public private(set) var activeBundleID: String?
    public private(set) var registrations: [HotKeyRegistration] = []
    public private(set) var revision = 0
    public private(set) var inputReady = true
    private var boundScheme: HotKeyScheme?
    private let registerKeys: (HotKeyScheme) -> [HotKeyRegistration]
    private let releaseKeys: () -> Void
    public var shouldCapture: Bool {
        settings.enabled && inputReady && activeBundleID != nil && !settings.excludedBundleIDs.contains(activeBundleID!)
    }
    public var status: String {
        if !settings.enabled { return "快捷键已释放；其他软件恢复原快捷键。历史监听独立运行。" }
        if !inputReady { return "输入权限未就绪，未接管快捷键。授权后退出重开或点重试注册。" }
        if let app = activeBundleID, settings.excludedBundleIDs.contains(app) { return "当前应用已排除；快捷键已释放。" }
        if activeBundleID == nil { return "无可确认的前台应用，快捷键已释放。" }
        let failed = registrations.filter { !$0.registered }
        if !failed.isEmpty {
            return "注册失败：" + failed.map { "\($0.label)（\($0.status)）" }.joined(separator: "、") + "。请停用占用组合的全局工具，或选择Option回退后重试。"
        }
        return "\(settings.scheme.name)接管中：\(registrations.filter(\.registered).count)/12。原应用同组合功能被占用。"
    }
    public init(settings: HotKeySettings,
                register: @escaping (HotKeyScheme) -> [HotKeyRegistration], release: @escaping () -> Void) {
        self.settings = settings; registerKeys = register; releaseKeys = release
    }
    public func setInputReady(_ value: Bool) {
        guard value != inputReady else { return }
        inputReady = value; revision += 1; reconcile()
    }
    public func update(_ value: HotKeySettings) {
        guard value != settings else { return }
        settings = value; revision += 1; reconcile()
    }
    public func activate(_ bundleID: String?) {
        guard bundleID != activeBundleID else { return }
        activeBundleID = bundleID; revision += 1; reconcile()
    }
    public func retry() { revision += 1; unbind(); reconcile() }
    public func stop() { revision += 1; unbind() }
    private func reconcile() {
        guard shouldCapture else { unbind(); return }
        if boundScheme != settings.scheme {
            unbind()
            registrations = registerKeys(settings.scheme)
            boundScheme = settings.scheme
        }
    }
    private func unbind() {
        if boundScheme != nil { releaseKeys() }
        boundScheme = nil; registrations = []
    }
}
