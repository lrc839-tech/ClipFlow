import Foundation

public enum LoginLaunchState: String { case notRegistered, enabled, requiresApproval, notFound }

@MainActor public final class LoginLaunchController {
    private let defaults: UserDefaults
    private let readState: () -> LoginLaunchState
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    public private(set) var desiredEnabled: Bool
    public private(set) var errorMessage = ""
    public var state: LoginLaunchState { readState() }
    public init(defaults: UserDefaults, state: @escaping () -> LoginLaunchState,
                register: @escaping () throws -> Void, unregister: @escaping () throws -> Void) {
        self.defaults = defaults; readState = state; self.register = register; self.unregister = unregister
        desiredEnabled = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
    }
    public func start() { apply(desiredEnabled) }
    public func apply(_ enabled: Bool) {
        desiredEnabled = enabled; defaults.set(enabled, forKey: "launchAtLogin"); errorMessage = ""
        do {
            if enabled, state == .notRegistered || state == .notFound { try register() }
            if !enabled, state == .enabled || state == .requiresApproval { try unregister() }
        } catch { errorMessage = "开机自启设置未完成：\(error.localizedDescription)" }
    }
    public var statusText: String {
        if !errorMessage.isEmpty { return errorMessage }
        switch state {
        case .enabled: return "已开启：登录 Mac 后自动启动"
        case .requiresApproval: return "等待系统批准，请在系统登录项设置中允许 mac复制工具"
        case .notRegistered: return desiredEnabled ? "尚未成功注册，请重试" : "已关闭"
        case .notFound: return "系统未找到当前安装副本，请从应用程序文件夹启动后重试"
        }
    }
}
