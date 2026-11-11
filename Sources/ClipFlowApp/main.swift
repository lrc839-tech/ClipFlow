import AppKit
import ApplicationServices
import ClipFlowCore

@MainActor
final class ClipFlowDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Action {
        case capture(PasteboardSnapshot, String?)
        case paste(Int, pid_t, UInt64, Int)
        case pasteMenu(UUID, Int, pid_t?, UInt64)
        case reload
        case manage(String, UUID?)
    }
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClipFlow")
    private var store: HistoryStore?
    private let hotkeys = HotKeyService()
    private let pasteService = TextPasteService()
    private let imagePreviews = HistoryImagePreviews()
    private var menuThumbnails: [UUID: NSImage] = [:]
    private var completedThumbnails = Set<UUID>()
    private var loadingThumbnails = Set<UUID>()
    private lazy var takeover = HotKeyTakeover(settings: HotKeySettings.load(from: .standard), register: { [unowned self] scheme in self.hotkeys.register(scheme: scheme) }, release: { [unowned self] in self.hotkeys.unregister() })
    private var activationObserver: NSObjectProtocol?
    private var lastExternalBundleID: String?
    private var lastExternalName = ""
    private var lastExternalApplication: NSRunningApplication?
    private var menuTarget: NSRunningApplication?
    private var menuTracking = false
    private var registrations: [HotKeyRegistration] = []
    private var records: [HistoryRecord] = []
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var browser: HistoryBrowser!
    private var browserIDs: [UUID] = []
    private var monitor: ClipboardMonitor!
    private var ready = false
    private var lastDiagnostic = "正在恢复历史…"
    private var events: [[String: Any]] = []
    private var savedCopies = 0
    private var quitting = false
    private var clipboardMode = UserDefaults.standard.bool(forKey: "clipboardTextMode")
    private var clipboardWait = max(150, UserDefaults.standard.integer(forKey: "clipboardWaitMilliseconds"))
    private var autoCompleteImages = UserDefaults.standard.bool(forKey: "autoCompleteDingTalkImages")
    private var pendingImageIDs = Set<UUID>()
    private var imageFailures: [UUID: String] = [:]
    private lazy var imageActions = SerialTaskQueue<UUID> { [weak self] id in await self?.completeImages(id) }
    private lazy var actions = SerialTaskQueue<Action> { [weak self] action in await self?.execute(action) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CF"
        monitor = ClipboardMonitor(onCapture: { [weak self] snapshot, source in
            self?.actions.enqueue(.capture(snapshot, source))
        }, onDiagnostic: { [weak self] message in self?.diagnostic(message) })
        monitor.excludedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? [])
        monitor.paused = UserDefaults.standard.bool(forKey: "monitorPaused")
        makeWindow()
        hotkeys.onPress = { [weak self] slot in self?.enqueuePaste(slot) }
        refreshHotKeys()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHotKeys() }
        }
        buildApplicationMenu()
        updateMenu()
        do {
            store = try HistoryStore(directory: directory)
            browser.store = store
            actions.enqueue(.reload)
        } catch { diagnostic("无法打开历史存储：\(error.localizedDescription)") }
    }

    private func execute(_ action: Action) async {
        switch action {
        case .reload:
            guard let store else { return }
            do {
                records = try await store.load(limit: 12)
                ready = true
                if !quitting { monitor.start() }
                diagnostic("历史已恢复。复制新内容后可用配置的12个全局快捷键。启动时剪贴板不重复导入。")
            } catch { ready = false; monitor.stop(); diagnostic("历史校验失败，已保留数据并停止收录：\(error.localizedDescription)") }
        case let .capture(snapshot, source):
            guard let store else { return }
            do {
                let record = try await store.record(snapshot: snapshot, sourceBundleID: source)
                savedCopies += 1
                if autoCompleteImages && RichTextImageCompletion.canComplete(snapshot) { enqueueImages(record.id) }
            } catch { diagnostic("本次复制未保存成功，请保留原内容：\(error.localizedDescription)"); return }
            do {
                records = try await store.load(limit: 12)
                lastDiagnostic = "已保存复制内容；粘贴不会改变顺序。"
                updateMenu(); writeReport()
            } catch {
                ready = false; monitor.stop()
                diagnostic("复制已提交，但历史重新校验失败；已暂停粘贴与收录，避免使用过时槽位：\(error.localizedDescription)")
            }
        case let .manage(command, id):
            guard let store else { return }
            do {
                switch command {
                case "pin": if let id { try await store.moveToFront(id: id) }
                case "delete": if let id { try await store.delete(id: id) }
                case "copy":
                    if let id, let record = try await store.load(limit: 1, id: id).first {
                        monitor.tick()
                        let snapshot = try await snapshotForPaste(record).materializingImageFiles().forSystemPaste
                        try snapshot.validateFileReferences()
                        let count = try snapshot.write(to: .general, onClaim: { self.monitor.suppress($0) })
                        monitor.suppress(count)
                    }
                case "imageCompletionToggle":
                    autoCompleteImages.toggle()
                    UserDefaults.standard.set(autoCompleteImages, forKey: "autoCompleteDingTalkImages")
                    if autoCompleteImages, let latest = records.first, RichTextImageCompletion.canComplete(latest.snapshot) { enqueueImages(latest.id) }
                case "pause": togglePause()
                case "permissions": openPermissions()
                case "direct": selectDirect()
                case "clipboard": selectClipboard()
                case "wait150", "wait300", "wait500":
                    clipboardWait = Int(command.dropFirst(4)) ?? 150
                    UserDefaults.standard.set(clipboardWait, forKey: "clipboardWaitMilliseconds")
                case "storage": openStorage()
                case "stats": showStats()
                case "reload": reload()
                case "quit": quit(); return
                default: return
                }
                records = try await store.load(limit: 12)
                updateMenu(); writeReport()
                browser.refresh()
                browser.notify(command == "copy" ? "已复制，可到目标应用粘贴。" : command == "pin" ? "已移到第一条，新复制内容会排到它前面。" : "设置已更新。")
            } catch { diagnostic(error.localizedDescription); browser.notify(error.localizedDescription) }
        case let .paste(slot, pid, receivedAt, revision):
            guard takeover.shouldCapture, revision == takeover.revision else { diagnostic("接管状态或前台应用已变化，已取消排队粘贴。"); return }
            guard ready else { diagnostic("历史尚未安全加载，未发送粘贴。", beep: true); return }
            guard records.indices.contains(slot - 1) else { diagnostic("第 \(slot) 条暂无记录，未发送输入。", beep: true); return }
            // A single FIFO orders capture/save and paste actions. Later copies cannot
            // change the chosen slot while this immutable snapshot is being pasted.
            let record = records[slot - 1]
            // A copy made after the shortcut but before this job executes must be
            // captured before a temporary clipboard write can hide its revision.
            monitor.tick()
            var event: [String: Any] = ["slot": slot, "recordID": record.id.uuidString,
                                        "targetPID": pid, "receivedAtNs": receivedAt]
            do {
                let outcome = try await pasteService.paste(snapshot: try await snapshotForPaste(record), targetPID: pid,
                                                           clipboardMode: clipboardMode,
                                                           waitMilliseconds: clipboardWait,
                                                           shouldContinue: { self.takeover.shouldCapture && revision == self.takeover.revision && !self.quitting },
                                                           onBoardChange: { [weak self] count in self?.monitor.suppress(count) })
                event["state"] = "posted-unconfirmed"; event["path"] = outcome.path
                event["restoreSkippedForNewCopy"] = outcome.restoreSkipped
                lastDiagnostic = outcome.restoreSkipped ? "已发送；检测到新复制，保留了新剪贴板。目标消费未确认。" : "已发送，目标接收未自动确认；历史顺序未改动。"
            } catch {
                event["state"] = "failed"; event["reason"] = error.localizedDescription
                lastDiagnostic = "粘贴失败：\(error.localizedDescription)"
                NSSound.beep()
            }
            event["finishedAtNs"] = DispatchTime.now().uptimeNanoseconds
            events.append(event)
            if events.count > 100 { events.removeFirst(events.count - 100) }
            updateMenu(); writeReport()
        case let .pasteMenu(id, slot, pid, receivedAt):
            await pasteMenuRecord(id, slot: slot, targetPID: pid, receivedAt: receivedAt)
        }
    }

    private func pasteMenuRecord(_ id: UUID, slot: Int, targetPID: pid_t?, receivedAt: UInt64) async {
        guard let store, ready else { return }
        var event: [String: Any] = ["origin": "menu", "slot": slot, "recordID": id.uuidString,
                                    "targetPID": targetPID ?? 0, "receivedAtNs": receivedAt]
        defer {
            event["finishedAtNs"] = DispatchTime.now().uptimeNanoseconds
            events.append(event)
            if events.count > 100 { events.removeFirst(events.count - 100) }
            updateMenu(); writeReport()
        }
        do {
            guard let record = try await store.load(limit: 1, id: id).first else { throw TextPasteError.unsupported }
            let snapshot = try await snapshotForPaste(record).materializingImageFiles().forSystemPaste
            try snapshot.validateFileReferences()
            monitor.tick()
            let count = try snapshot.write(to: .general, onClaim: { self.monitor.suppress($0) })
            monitor.suppress(count)
            guard let targetPID else {
                event["state"] = "copied-only"
                lastDiagnostic = "已复制所选记录，请在目标应用按 Command+V。"
                return
            }
            // NSMenu actions may arrive before its tracking loop has unwound.
            for _ in 0..<50 where menuTracking { try await Task.sleep(nanoseconds: 10_000_000) }
            guard !menuTracking, !quitting else { throw TextPasteError.cancelled }
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if foreground == ProcessInfo.processInfo.processIdentifier {
                NSRunningApplication(processIdentifier: targetPID)?.activate(options: [])
                for _ in 0..<25 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            let outcome = try await pasteService.paste(snapshot: snapshot, targetPID: targetPID,
                clipboardMode: true, waitMilliseconds: clipboardWait, keepOnClipboard: true,
                expectedClipboardChangeCount: count, shouldContinue: { !self.quitting },
                onBoardChange: { self.monitor.suppress($0) })
            event["state"] = "posted-unconfirmed"
            event["path"] = outcome.path
            event["restoreSkippedForNewCopy"] = outcome.restoreSkipped
            lastDiagnostic = outcome.restoreSkipped ? "已发送，后续新复制已保留。" : "已发送，Command+V 可继续粘贴所选记录。"
        } catch {
            event["state"] = "failed"
            event["reason"] = error.localizedDescription
            lastDiagnostic = "菜单粘贴未完成。\(error.localizedDescription)"
            NSSound.beep()
        }
    }

    private func snapshotForPaste(_ record: HistoryRecord) async throws -> PasteboardSnapshot {
        if let prepared = try await store?.preparedSnapshot(id: record.id) { return prepared }
        if pendingImageIDs.contains(record.id) { throw ImageCompletionPendingError() }
        return record.snapshot
    }

    private func enqueueImages(_ id: UUID) {
        guard !quitting, !pendingImageIDs.contains(id) else { return }
        guard pendingImageIDs.count < 8 else { diagnostic("图片补全队列已满，原记录已保存，可稍后点补全图片。"); return }
        pendingImageIDs.insert(id); imageFailures[id] = nil
        imageActions.enqueue(id)
        updateMenu(); browser.refresh()
    }

    private func completeImages(_ id: UUID) async {
        defer { pendingImageIDs.remove(id); updateMenu(); browser.refresh(); writeReport() }
        guard !quitting, let store else { return }
        do {
            guard let record = try await store.load(limit: 1, id: id).first,
                  try await store.preparedSnapshot(id: id) == nil else { return }
            diagnostic("正在后台补全钉钉图片，文字复制和其他记录粘贴可继续使用。")
            let completed = try await RichTextImageCompletion.complete(record.snapshot)
            guard !quitting else { return }
            if try await store.savePreparedSnapshot(id: id, sourceFingerprint: record.fingerprint, result: completed) {
                imageFailures[id] = nil
                completedThumbnails.remove(id); menuThumbnails[id] = nil
                diagnostic("已补全并保存 \(completed.imageCount) 张图片，可复制或快捷粘贴。")
                browser.notify(lastDiagnostic)
            }
        } catch {
            // Errors are fixed local messages; signed image URLs never enter logs.
            let message = (error as? ImageCompletionError)?.localizedDescription ?? "图片补全或保存失败，原记录已保留，可重试。"
            imageFailures[id] = message
            if imageFailures.count > 100 { imageFailures.removeValue(forKey: imageFailures.keys.first!) }
            diagnostic(message); browser.notify(message)
        }
    }

    private struct ImageCompletionPendingError: LocalizedError {
        var errorDescription: String? { "这条记录的图片正在补全，请完成后再粘贴。" }
    }

    private func enqueuePaste(_ slot: Int) {
        guard !quitting, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            diagnostic("请先聚焦目标应用的输入位置。", beep: true); return
        }
        takeover.setInputReady(AXIsProcessTrusted() && CGPreflightPostEventAccess())
        registrations = takeover.registrations
        // Capture an unseen copy immediately instead of waiting up to one poll period.
        guard takeover.shouldCapture else { return }
        monitor.tick()
        actions.enqueue(.paste(slot, pid, DispatchTime.now().uptimeNanoseconds, takeover.revision))
    }

    private func buildApplicationMenu() {
        let main = NSMenu()
        let root = NSMenuItem()
        let applicationMenu = NSMenu()
        let quit = NSMenuItem(title: "退出 ClipFlow", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; applicationMenu.addItem(quit)
        root.submenu = applicationMenu; main.addItem(root)
        NSApp.mainMenu = main
    }

    private func updateMenu() {
        let menu = NSMenu()
        func label(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        func item(_ title: String, _ action: Selector, tag: Int = 0, checked: Bool = false) {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
            value.target = self; value.tag = tag; value.state = checked ? .on : .off; menu.addItem(value)
        }
        menu.delegate = self
        item("设置", #selector(showWindow))
        label("全局快捷键 \(registrations.filter(\.registered).count)/12 · AX \(AXIsProcessTrusted() ? "已授权" : "未授权") · 发键 \(CGPreflightPostEventAccess() ? "已授权" : "未授权")")
        label(takeover.status)
        item("Command + 1234567890-=", #selector(useCommand), checked: takeover.settings.scheme == .command)
        item("Option + 1234567890-=（回退）", #selector(useOption), checked: takeover.settings.scheme == .option)
        item(monitor?.paused == true ? "恢复监听（跳过暂停期间内容）" : "暂停监听", #selector(togglePause))
        menu.addItem(.separator())
        if records.isEmpty { label(ready ? "暂无历史；请先复制内容" : "历史尚未加载") }
        for (index, record) in records.enumerated() {
            let summary = (record.snapshot.summary).replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ")
            item("\(takeover.settings.scheme.symbol)\(HotKeyService.labels[index])  \(summary.prefix(64))", #selector(pasteFromMenu(_:)), tag: index + 1)
            menu.items.last?.representedObject = record.id.uuidString
            menu.items.last?.image = menuThumbnails[record.id]
            if !completedThumbnails.contains(record.id), !loadingThumbnails.contains(record.id) { loadMenuThumbnail(record.id) }
        }
        statusItem.menu = menu
        browser.slots = records.map(\.id)
        browser.hotkeyScheme = takeover.settings.scheme
        browser.hotkeyEnabled = takeover.settings.enabled
        browser.hotkeyStatus = takeover.status
        browser.hotkeyExclusions = takeover.settings.excludedBundleIDs.sorted()
        browser.lastExternalName = lastExternalName
        browser.lastExternalBundleID = lastExternalBundleID ?? ""
        browser.autoCompleteImages = autoCompleteImages
        browser.pendingImageIDs = pendingImageIDs
        browser.imageFailures = imageFailures
        browser.clipboardMode = clipboardMode
        browser.clipboardWait = clipboardWait
        browser.lastDiagnostic = lastDiagnostic
        browser.updateHotkeyControls()
        if browserIDs != browser.slots { browserIDs = browser.slots; browser.refresh() }
    }

    private func loadMenuThumbnail(_ id: UUID) {
        guard let store else { return }
        loadingThumbnails.insert(id)
        Task {
            defer { loadingThumbnails.remove(id) }
            let previews = try? await imagePreviews.images(id: id, store: store, size: 160)
            completedThumbnails.insert(id)
            if let preview = previews?.first, let image = NSImage(data: preview.png) {
                let scale = min(72 / image.size.width, 48 / image.size.height)
                image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                menuThumbnails[id] = image
                // Update the displayed item in place. Rebuilding a tracking menu
                // could move the item under the pointer or disturb its target.
                statusItem.menu?.items.first(where: { ($0.representedObject as? String) == id.uuidString })?.image = image
                writeReport()
            }
            if completedThumbnails.count > 128 {
                let keep = Set(records.map(\.id))
                completedThumbnails.formIntersection(keep)
                menuThumbnails = menuThumbnails.filter { keep.contains($0.key) }
            }
        }
    }

    private func makeWindow() {
        browser = HistoryBrowser()
        browser.imagePreviews = imagePreviews
        browser.onHotkeyCommand = { [weak self] command,value in self?.configureHotkeys(command,value) }
        browser.onCommand = { [weak self] command,id in
            guard let self else { return }
            if command == "completeImages", let id { self.enqueueImages(id) }
            else { self.actions.enqueue(.manage(command,id)) }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "ClipFlow — 设置"
        window.isReleasedWhenClosed = false
        window.contentView = browser.view
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    private func diagnostic(_ message: String, beep: Bool = false) {
        lastDiagnostic = message
        if beep { NSSound.beep() }
        updateMenu(); writeReport()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuTracking = true
        let foreground = NSWorkspace.shared.frontmostApplication
        menuTarget = foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApplication : foreground
    }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    @objc private func pasteFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        var pid: pid_t?
        if let target = menuTarget, !target.isTerminated,
           target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            pid = target.processIdentifier
        }
        actions.enqueue(.pasteMenu(id, sender.tag, pid, DispatchTime.now().uptimeNanoseconds))
    }
    @objc private func selectDirect() { clipboardMode = false; UserDefaults.standard.set(false, forKey: "clipboardTextMode"); updateMenu() }
    @objc private func selectClipboard() { clipboardMode = true; UserDefaults.standard.set(true, forKey: "clipboardTextMode"); updateMenu() }
    @objc private func selectWait(_ sender: NSMenuItem) { clipboardWait = sender.tag; UserDefaults.standard.set(clipboardWait, forKey: "clipboardWaitMilliseconds"); updateMenu() }
    @objc private func togglePause() { monitor.paused.toggle(); UserDefaults.standard.set(monitor.paused, forKey: "monitorPaused"); updateMenu(); writeReport() }
    @objc private func reload() { actions.enqueue(.reload) }
    private func refreshHotKeys() {
        guard !quitting else { takeover.stop(); registrations = []; return }
        let app = NSWorkspace.shared.frontmostApplication
        if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalBundleID = app.bundleIdentifier; lastExternalName = app.localizedName ?? app.bundleIdentifier ?? ""
            lastExternalApplication = app
        }
        takeover.setInputReady(AXIsProcessTrusted() && CGPreflightPostEventAccess())
        takeover.activate(app?.bundleIdentifier)
        registrations = takeover.registrations
        updateMenu(); writeReport()
    }
    private func configureHotkeys(_ command: String, _ value: String = "") {
        takeover.setInputReady(AXIsProcessTrusted() && CGPreflightPostEventAccess())
        takeover.activate(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        var settings = takeover.settings
        switch command {
        case "hotkeysToggle": settings.enabled.toggle()
        case "hotkeysCommand": settings.scheme = .command
        case "hotkeysOption": settings.scheme = .option
        case "hotkeysExclusions": settings.excludedBundleIDs = HotKeySettings.parseExclusions(value)
        case "hotkeysExcludeLast": if let id = lastExternalBundleID { settings.excludedBundleIDs.insert(id) }
        case "hotkeysRetry": takeover.retry()
        default: return
        }
        takeover.update(settings)
        settings.save(to: .standard)
        registrations = takeover.registrations
        browserIDs = []
        diagnostic(takeover.status)
    }
    @objc private func toggleHotkeys() { configureHotkeys("hotkeysToggle") }
    @objc private func useCommand() { configureHotkeys("hotkeysCommand") }
    @objc private func useOption() { configureHotkeys("hotkeysOption") }
    @objc private func recheck() { configureHotkeys("hotkeysRetry") }
    @objc private func openPermissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func openStorage() { NSWorkspace.shared.open(directory) }
    @objc private func showStats() {
        guard let store else { return }
        Task {
            do { let stats = try await store.stats(); diagnostic("历史 \(stats.recordCount) 条；本地共 \(ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))，无自动淘汰。") }
            catch { diagnostic("存储统计失败：\(error.localizedDescription)") }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func writeReport() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClipFlow")
        var report: [String: Any] = ["stage": "v0.6-image-previews", "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "ready": ready, "paused": monitor?.paused ?? true,
            "accessibilityTrusted": AXIsProcessTrusted(), "postEventAllowed": CGPreflightPostEventAccess(),
            "autoCompleteDingTalkImages": autoCompleteImages, "pendingImageCount": pendingImageIDs.count, "menuImagePreviewCount": statusItem.menu?.items.filter { $0.image != nil }.count ?? 0,
            "savedCopiesThisRun": savedCopies, "cachedRecordIDsNewestFirst": records.map { $0.id.uuidString },
            "hotkeyTakeoverEnabled": takeover.settings.enabled,
            "hotkeyScheme": takeover.settings.scheme.rawValue,
            "hotkeyExcludedBundleIDs": takeover.settings.excludedBundleIDs.sorted(),
            "hotkeyActiveBundleID": takeover.activeBundleID ?? "",
            "hotkeyStatus": takeover.status,
            "hotkeys": registrations.map { ["slot": $0.slot, "label": $0.label, "status": $0.status] as [String: Any] },
            "events": events, "lastDiagnostic": lastDiagnostic,
            "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if #available(macOS 15.4, *) { report["pasteboardAccessBehavior"] = NSPasteboard.general.accessBehavior.rawValue }
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: logs.appendingPathComponent("diagnostics.json"), options: .atomic)
        } catch { lastDiagnostic = "诊断文件写入失败：\(error.localizedDescription)" }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        monitor?.stop(); quitting = true; takeover.stop()
        guard actions.count > 0 else { return .terminateNow }
        Task {
            while actions.count > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        takeover.stop(); monitor?.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ClipFlowDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
