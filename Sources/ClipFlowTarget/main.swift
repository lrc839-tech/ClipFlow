import AppKit
import CryptoKit
import Foundation

// Deliberately separate from ClipFlowProbe. A callback here is evidence of receipt in
// another process, not a guarantee that a frame has appeared on the display.
private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private struct TargetEvent: Codable {
    let kind: String
    let timestampNs: UInt64
    let targetPID: Int32
    let frontmostPID: Int32?
    let isAppActive: Bool
    let keyCode: UInt16?
    let modifierFlagsRaw: UInt?
    let contentUTF16Length: Int
    let contentSHA256: String
    let isCBA: Bool
    let incomingUTF16Length: Int?
    let incomingSHA256: String?
}

private struct TargetReport: Codable {
    let schemaVersion: Int
    let measurement: String
    let generatedAt: Date
    let targetPID: Int32
    let session: UUID
    let contentUTF16Length: Int
    let contentSHA256: String
    let isCBA: Bool
    let events: [TargetEvent]
}

private final class ReceiptTextView: NSTextView {
    var observe: ((String, NSEvent?, String?) -> Void)?

    override func keyDown(with event: NSEvent) {
        // Log the arrival before AppKit processes the key. Never record characters.
        observe?("keyDown.received", event, nil)
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        observe?("flagsChanged.received", event, nil)
        super.flagsChanged(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let input = (insertString as? NSAttributedString)?.string ?? (insertString as? String)
        let event = NSApp.currentEvent
        super.insertText(insertString, replacementRange: replacementRange)
        observe?("insertText.completed", event, input)
    }

    override func paste(_ sender: Any?) {
        let event = NSApp.currentEvent
        observe?("paste.requested", event, nil)
        super.paste(sender)
        observe?("paste.returned", event, nil)
    }
}

private final class TargetDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private var textView: ReceiptTextView!
    private let status = NSTextField(labelWithString: "输入区为空；Option + 1、2、3 的预期结果是 CBA。")
    private let logStatus = NSTextField(labelWithString: "")
    private var events: [TargetEvent] = []
    private var session = UUID()
    private var reportURL: URL {
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["CLIPFLOW_REPORT_DIR"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/ClipFlowM0", isDirectory: true)
        }
        return directory.appendingPathComponent("target-events.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        record("target.ready", event: nil, input: nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        // No NSApp.activate: launching the receiver must not silently steal focus.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 ClipFlow M0 Target", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let newItem = NSMenuItem(title: "新建空白测试", action: #selector(reset(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "ClipFlow M0 Target"
        window.delegate = self
        window.center()

        let root = NSView()
        window.contentView = root
        let title = NSTextField(labelWithString: "ClipFlow M0 · 独立目标输入窗口")
        title.font = .boldSystemFont(ofSize: 18)
        let instructions = NSTextField(wrappingLabelWithString:
            "在 Probe 中准备 C、B、A 后，将焦点放在下方输入区，按 Option + 1、2、3。\n此窗口记录跨进程接收回调和内容摘要；回调时间不等于屏幕可见时间。")
        let resetButton = NSButton(title: "清空测试输入", target: self, action: #selector(reset(_:)))
        resetButton.setAccessibilityIdentifier("resetTarget")
        status.setAccessibilityIdentifier("targetResult")
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        logStatus.font = .systemFont(ofSize: 11)
        logStatus.textColor = .secondaryLabelColor
        logStatus.lineBreakMode = .byTruncatingMiddle

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView = ReceiptTextView(frame: NSRect(x: 0, y: 0, width: 716, height: 250))
        textView.isRichText = true
        textView.importsGraphics = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 24)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("ClipFlow 测试输入区")
        textView.setAccessibilityIdentifier("targetInput")
        textView.observe = { [weak self] kind, event, input in
            self?.record(kind, event: event, input: input)
        }
        scroll.documentView = textView

        [title, instructions, resetButton, status, scroll, logStatus].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            instructions.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            instructions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            instructions.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            resetButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            resetButton.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: resetButton.trailingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            status.centerYAnchor.constraint(equalTo: resetButton.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: instructions.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: resetButton.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: logStatus.topAnchor, constant: -10),
            logStatus.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            logStatus.trailingAnchor.constraint(equalTo: instructions.trailingAnchor),
            logStatus.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
        window.minSize = NSSize(width: 650, height: 420)
    }

    @objc private func reset(_ sender: Any?) {
        textView.string = ""
        textView.undoManager?.removeAllActions()
        events.removeAll(keepingCapacity: true)
        session = UUID()
        window.makeFirstResponder(textView)
        record("target.reset", event: NSApp.currentEvent, input: nil)
    }

    func textDidChange(_ notification: Notification) {
        record("textDidChange.received", event: NSApp.currentEvent, input: nil)
    }

    private func record(_ kind: String, event: NSEvent?, input: String?) {
        let value = textView.string
        let isKeyboard = event.map { [.keyDown, .keyUp, .flagsChanged].contains($0.type) } ?? false
        let item = TargetEvent(
            kind: kind,
            timestampNs: DispatchTime.now().uptimeNanoseconds,
            targetPID: ProcessInfo.processInfo.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            isAppActive: NSApp.isActive,
            keyCode: isKeyboard ? event?.keyCode : nil,
            modifierFlagsRaw: event?.modifierFlags.rawValue,
            contentUTF16Length: value.utf16.count,
            contentSHA256: digest(value),
            isCBA: value == "CBA",
            incomingUTF16Length: input?.utf16.count,
            incomingSHA256: input.map(digest))
        events.append(item)
        if value.isEmpty {
            status.stringValue = "输入区为空；Option + 1、2、3 的预期结果是 CBA。"
        } else if value == "CBA" {
            status.stringValue = "已收到 CBA（内容匹配；仍需检查实键连续按住和屏幕表现）。"
        } else {
            status.stringValue = "已收到 \(value.utf16.count) 个 UTF-16 单元；当前内容不等于 CBA。"
        }
        persist(value: value)
    }

    private func persist(value: String) {
        let report = TargetReport(schemaVersion: 1,
                                  measurement: "Cross-process AppKit receipt callbacks; not screen-visible latency",
                                  generatedAt: Date(),
                                  targetPID: ProcessInfo.processInfo.processIdentifier,
                                  session: session,
                                  contentUTF16Length: value.utf16.count,
                                  contentSHA256: digest(value), isCBA: value == "CBA", events: events)
        do {
            let destination = reportURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: destination, options: .atomic)
            logStatus.stringValue = "本地摘要日志：\(destination.path) · 不写入输入明文"
        } catch {
            // Errors can include filesystem paths, but never the value of the text view.
            logStatus.stringValue = "日志写入失败：\(error.localizedDescription)"
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
private let delegate = TargetDelegate()
application.delegate = delegate
application.run()
