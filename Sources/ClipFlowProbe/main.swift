import AppKit
import ApplicationServices
import Carbon
import ClipFlowCore

private func reportDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["CLIPFLOW_REPORT_DIR"] { return URL(fileURLWithPath: path) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClipFlowM0")
}

private func permissions() -> [String: Any] {
    var result: [String: Any] = [
        "accessibilityTrusted": AXIsProcessTrusted(),
        "postEventAllowed": CGPreflightPostEventAccess(),
        "inputMonitoringRequested": false,
        "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "architecture": "arm64",
        "stage": "M0 experiment, not production clipboard history"
    ]
    if #available(macOS 15.4, *) {
        result["pasteboardAccessBehavior"] = NSPasteboard.general.accessBehavior.rawValue
    }
    return result
}

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let status = NSTextField(wrappingLabelWithString: "")
    let mode = NSPopUpButton()
    let hotkeys = HotKeyService()
    var registrations: [HotKeyRegistration] = []
    var diagnostics: [[String: Any]] = []
    var fixtures = ["C", "B", "A", "4", "5", "6", "7", "8", "9", "0", "-", "="]
    var report: [String: Any] = [:]
    struct Request {
        let id: Int
        let slot: Int
        let text: String
        let pid: pid_t
        let receivedAt: UInt64
        let clipboardMode: Bool
    }
    lazy var queue = SerialTaskQueue<Request> { [weak self] request in await self?.execute(request) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeMenu()
        makeWindow()
        report = permissions()
        report["sameProcessDuplicateRegistrationExperiment"] = HotKeyService.conflictExperiment()
        hotkeys.onPress = { [weak self] slot in self?.pressed(slot) }
        registrations = hotkeys.register()
        refresh()
    }

    func makeMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "ClipFlow M0 诊断", action: #selector(show), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出（释放全部热键）", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CF·M0"
        statusItem.menu = menu
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = menu.copy() as? NSMenu
        appMenu.addItem(root)
        NSApp.mainMenu = appMenu
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 530),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ClipFlow M0 — 技术验证"
        window.isReleasedWhenClosed = false
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        column.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            column.topAnchor.constraint(equalTo: window.contentView!.topAnchor)
        ])
        let title = NSTextField(labelWithString: "M0 最小验证；尚无历史持久化服务")
        title.font = .boldSystemFont(ofSize: 18)
        column.addArrangedSubview(title)
        let help = NSTextField(wrappingLabelWithString: "已装载固定测试数据：1=C、2=B、3=A。打开独立 ClipFlow M0 Target，聚焦输入区后测试 Option+123。此窗口不会在热键触发时弹出。")
        help.preferredMaxLayoutWidth = 610
        column.addArrangedSubview(help)
        mode.addItems(withTitles: ["纯文本：Unicode 事件（优先速度，兼容性待测）", "纯文本：临时剪贴板 + Command+V（实验等待 150ms）"])
        column.addArrangedSubview(mode)
        for (title, action) in [
            ("重新检查权限与注册结果", #selector(recheck)),
            ("打开辅助功能设置（请手工授权此 App）", #selector(openAccessibility)),
            ("读取并原样恢复当前剪贴板（显式 M0 实验）", #selector(roundTrip)),
            ("切换中文 / Emoji / 换行测试数据", #selector(unicodeFixtures)),
            ("恢复 CBA 数据并清空本轮事件记录", #selector(resetFixtures))
        ] {
            let button = NSButton(title: title, target: self, action: action)
            column.addArrangedSubview(button)
        }
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.preferredMaxLayoutWidth = 610
        column.addArrangedSubview(status)
        window.center()
        show()
    }

    @objc func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func recheck() {
        guard queue.count == 0 else { refresh(message: "请等待队列结束后重新注册热键。") ; return }
        report.merge(permissions()) { _, new in new }
        registrations = hotkeys.register()
        refresh()
    }
    @objc func unicodeFixtures() { fixtures[0] = "中文🙂\n"; refresh(message: "测试槽位 1 已改为中文、Emoji、换行；2=B、3=A。") }
    @objc func resetFixtures() {
        guard queue.count == 0 else { refresh(message: "请等待当前任务队列结束后重置。") ; return }
        fixtures[0] = "C"; diagnostics.removeAll(); refresh(message: "固定 CBA 数据已恢复。")
    }

    @objc func roundTrip() {
        guard queue.count == 0 else { refresh(message: "请等待粘贴队列结束后再运行剪贴板实验。") ; return }
        do {
            let board = NSPasteboard.general
            let originalCount = board.changeCount
            let snapshot = try PasteboardSnapshot.capture(from: board)
            guard board.changeCount == originalCount else { throw ProbeError.changedClipboard }
            let lease = try PasteboardLease(board: board, replacement: snapshot)
            defer {
                do {
                    if try !lease.restoreIfOwned() { report["roundTripRestoreSkippedForNewCopy"] = true }
                } catch { report["lastRestoreFailure"] = error.localizedDescription }
                refresh()
            }
            let restored = try PasteboardSnapshot.capture(from: board)
            guard lease.stillOwnsClipboard else { throw ProbeError.changedClipboard }
            let equal = snapshot == restored
            report["generalRoundTrip"] = ["equal": equal, "items": snapshot.items.count,
                "typeCounts": snapshot.items.map { $0.representations.count },
                "bytes": snapshot.items.flatMap { $0.representations.values }.reduce(0) { $0 + $1.count },
                "testedAt": ISO8601DateFormatter().string(from: Date())]
            refresh(message: equal ? "当前剪贴板原始数据往返一致；未证明目标应用格式兼容。" : "原始类型或数据往返不一致；请查看报告。")
        } catch { recordFailure("pasteboard-roundtrip", error.localizedDescription) }
    }

    func pressed(_ slot: Int) {
        guard let target = NSWorkspace.shared.frontmostApplication, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            recordFailure("focus", "目标是 ClipFlow 自身；请先聚焦独立测试输入区。")
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let id = diagnostics.count + 1
        diagnostics.append(["id": id, "slot": slot, "hotkeyReceivedAtNs": now,
                            "targetPID": target.processIdentifier, "state": "queued"])
        queue.enqueue(Request(id: id, slot: slot, text: fixtures[slot - 1], pid: target.processIdentifier,
                              receivedAt: now, clipboardMode: mode.indexOfSelectedItem == 1))
        refresh()
    }

    func checkFocus(_ pid: pid_t) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw ProbeError.focusChanged }
    }

    func execute(_ request: Request) async {
        var event = diagnostics.first { ($0["id"] as? Int) == request.id } ?? ["id": request.id]
        do {
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw ProbeError.permission }
            try checkFocus(request.pid)
            if request.clipboardMode {
                try await clipboardPaste(request)
                event["path"] = "temporary-clipboard; heuristic wait, no ACK"
            } else {
                // Chunk by Character so surrogate pairs are never split. A long grapheme is rejected.
                for character in request.text {
                    try checkFocus(request.pid)
                    let units = Array(String(character).utf16)
                    guard units.count <= 20 else { throw ProbeError.unicodeLength }
                    try postUnicode(units)
                }
                event["path"] = "unicode-events"
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            event["state"] = "posted-unconfirmed"
            event["finishedAtNs"] = DispatchTime.now().uptimeNanoseconds
        } catch {
            event["state"] = "failed"
            event["reason"] = error.localizedDescription
            NSSound.beep()
        }
        if let index = diagnostics.firstIndex(where: { ($0["id"] as? Int) == request.id }) { diagnostics[index] = event }
        report.merge(permissions()) { _, new in new }
        refresh()
    }

    func postUnicode(_ units: [UniChar]) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw ProbeError.eventCreation }
        down.flags = []; up.flags = []
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    func clipboardPaste(_ request: Request) async throws {
        let board = NSPasteboard.general
        let lease = try PasteboardLease(board: board, replacement: .text(request.text))
        defer {
            // Public NSPasteboard has no atomic compare-and-swap. Recheck immediately before restoring.
            do {
                if try !lease.restoreIfOwned() { report["restoreSkippedBecauseClipboardChanged"] = true }
            } catch { report["lastRestoreFailure"] = error.localizedDescription }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        try checkFocus(request.pid)
        guard lease.stillOwnsClipboard else { throw ProbeError.changedClipboard }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw ProbeError.eventCreation }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    func recordFailure(_ kind: String, _ reason: String) {
        report["lastFailure"] = ["kind": kind, "reason": reason]
        NSSound.beep()
        refresh(message: reason)
    }

    func refresh(message: String? = nil) {
        report["hotkeys"] = registrations.map { ["slot": $0.slot, "label": $0.label, "status": $0.status] as [String: Any] }
        report["events"] = diagnostics
        report["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let successCount = registrations.filter(\.registered).count
        let failed = registrations.filter { !$0.registered }
        let hotkeyFailure = failed.isEmpty ? "" : "\n注册失败码：\(Set(failed.map(\.status)).sorted())；-9878 表示已被注册，请停用旧热键后重新检查。"
        status.stringValue = "独占热键：\(successCount)/12；AX：\(AXIsProcessTrusted())；事件发布：\(CGPreflightPostEventAccess())\n"
            + "热键接收：\(diagnostics.count) 次；报告：~/Library/Logs/ClipFlowM0/probe.json\n"
            + (message ?? (diagnostics.last?["reason"] as? String) ?? "事件 posted 仅代表已发布，目标是否接收请核对独立 Target。")
            + hotkeyFailure
        do {
            let directory = reportDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("probe.json"), options: .atomic)
        } catch { status.stringValue += "\n报告写入失败：\(error.localizedDescription)" }
    }

    func applicationWillTerminate(_ notification: Notification) { hotkeys.unregister() }
}

enum ProbeError: LocalizedError {
    case permission, focusChanged, changedClipboard, unicodeLength, eventCreation
    var errorDescription: String? {
        switch self {
        case .permission: return "事件发布权限未就绪。请在系统设置→隐私与安全性→辅助功能中授权 ClipFlow M0，再重新检查。"
        case .focusChanged: return "排队期间前台应用已变化，此任务取消以防输入到错误应用。"
        case .changedClipboard: return "实验期间系统剪贴板已改变；已中止，避免覆盖新复制内容。"
        case .unicodeLength: return "字符的 UTF-16 长度超过直接注入实验上限；需要改用剪贴板模式。"
        case .eventCreation: return "系统无法创建输入事件；未声称已粘贴。"
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = ProbeDelegate()
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
}
