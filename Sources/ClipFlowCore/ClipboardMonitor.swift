import AppKit
import UniformTypeIdentifiers

/// M1 polling service. Starting or resuming establishes a fresh change-count baseline;
/// it never imports the clipboard that was present before monitoring became active.
///
/// The reported source application is an approximation: NSPasteboard does not expose
/// the copying application's identity, so the frontmost application at capture time is
/// used. App switching and background clipboard writers can defeat this exclusion rule.
/// Synchronous/lazy pasteboard providers can block a read; a hard provider deadline is
/// not claimed. The 64 MiB limit bounds retained data, not a provider's allocation.
@MainActor
public final class ClipboardMonitor {
    public let pollInterval: TimeInterval
    public private(set) var isRunning = false

    public var paused = false {
        didSet {
            guard paused != oldValue else { return }
            // In particular, resuming without a tick during the pause must not archive
            // something that was copied while the user thought monitoring was off.
            establishBaseline()
        }
    }

    public var excludedBundleIDs: Set<String> = []
    public private(set) var suppressedChangeCounts: Set<Int> = []

    private let pasteboard: NSPasteboard
    private let onCapture: (PasteboardSnapshot, String?) -> Void
    private let onDiagnostic: (String) -> Void
    private let sourceBundleIdentifier: () -> String?
    private let maxBytes: Int
    private var observedChangeCount: Int?
    private var timer: Timer?

    public init(pasteboard: NSPasteboard = .general,
                onCapture: @escaping (PasteboardSnapshot, String?) -> Void,
                onDiagnostic: @escaping (String) -> Void,
                pollInterval: TimeInterval = 0.05,
                maxBytes: Int = 64 * 1024 * 1024,
                sourceBundleIdentifier: @escaping () -> String? = {
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                }) {
        self.pasteboard = pasteboard
        self.onCapture = onCapture
        self.onDiagnostic = onDiagnostic
        self.pollInterval = pollInterval.isFinite && pollInterval > 0 ? pollInterval : 0.05
        self.maxBytes = max(0, maxBytes)
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }

    deinit {
        timer?.invalidate()
    }

    public func start() {
        guard !isRunning else { return }
        establishBaseline()
        isRunning = true
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            // This timer is installed exclusively on RunLoop.main. Process its event
            // synchronously, including during nested runloops, instead of enqueueing
            // an actor Task that may be delayed until the current actor job returns.
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        establishBaseline()
    }

    /// Suppress exactly this self-authored pasteboard revision. A subsequent external
    /// copy, including a copy of identical bytes, has a different change count and is
    /// still eligible. Call synchronously at both claim and completed-write revisions.
    public func suppress(_ changeCount: Int) {
        suppressedChangeCounts.insert(changeCount)
    }

    /// Public for deterministic tests. Production invokes it from the main-runloop timer.
    public func tick() {
        guard isRunning else { return }
        let changeCount = pasteboard.changeCount
        guard observedChangeCount != changeCount else { return }
        observedChangeCount = changeCount
        let isSelfAuthored = suppressedChangeCounts.remove(changeCount) != nil
        // Revision counters increase for each new owner. Retain only not-yet-observed
        // revisions, so normal operation does not accumulate suppression tokens.
        suppressedChangeCounts = suppressedChangeCounts.filter { $0 > changeCount }
        guard !paused, !isSelfAuthored else { return }

        let source = sourceBundleIdentifier()
        if let source, excludedBundleIDs.contains(source) {
            onDiagnostic("已跳过排除应用的剪贴板变化；来源按前台应用估计，存在时序误差。")
            return
        }
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            onDiagnostic("系统已禁止剪贴板读取；请在系统设置中检查 ClipFlow 的剪贴板访问权限。")
            return
        }

        do {
            let snapshot = try PasteboardSnapshot.capture(from: pasteboard, maxBytes: maxBytes)
            guard !snapshot.items.isEmpty else { return }
            onCapture(snapshot, source)
        } catch let error as PasteboardSnapshotError {
            // Type names can be supplied by another process; diagnostics use fixed text
            // instead of interpolating any clipboard-provided string or payload.
            switch error {
            case .sensitiveType:
                onDiagnostic("检测到已识别的敏感或临时剪贴板标记，未保存。")
            case .unsupportedFilePromise:
                onDiagnostic("检测到文件承诺；M1 不保存其延迟提供者，已跳过。")
            case .sizeLimitExceeded:
                onDiagnostic("剪贴板超过单次快照容量上限，整条拒绝保存，未裁剪数据。")
            case .changedDuringRead:
                onDiagnostic("剪贴板在读取期间变化，本次不完整快照已放弃。")
            default:
                onDiagnostic("剪贴板快照读取失败，未保存；请检查访问权限或源应用的数据提供状态。")
            }
        } catch {
            onDiagnostic("剪贴板快照读取失败，未保存；请检查访问权限或源应用的数据提供状态。")
        }
    }

    private func establishBaseline() {
        observedChangeCount = pasteboard.changeCount
        suppressedChangeCounts.removeAll()
    }

    private static func isImageOrFileType(_ rawValue: String) -> Bool {
        let normalized = rawValue.lowercased()
        if normalized == NSPasteboard.PasteboardType.fileURL.rawValue.lowercased() ||
            normalized == "nsfilenamespboardtype" ||
            normalized == "nspictpboardtype" ||
            normalized.hasPrefix("com.apple.finder.") {
            return true
        }
        guard let type = UTType(rawValue) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .fileURL)
    }
}
