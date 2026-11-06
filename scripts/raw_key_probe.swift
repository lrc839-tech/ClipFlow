import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Standalone, passive system-session observation. This file neither imports ClipFlowCore nor
// posts events, reads key characters/Unicode, accesses a pasteboard, or requests TCC.
// A session event timestamp is not proof of physical keyboard switch ordering.
// cgSessionEventTap avoids relying on root-only HID tap creation; no escalation is attempted.
private let observationPhase = "system session event observation, not physical switch ordering"

private func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private struct Arguments {
    let preflight: Bool
    let targetPID: pid_t?
    let count: Int
    let output: URL?

    static func parse() throws -> Arguments {
        let values = Array(CommandLine.arguments.dropFirst())
        if values == ["--preflight"] {
            return Arguments(preflight: true, targetPID: nil, count: 15, output: nil)
        }
        if values.isEmpty || values.contains("--help") || values.contains("-h") {
            throw ArgumentError.usage
        }
        var targetPID: pid_t?
        var count = 15
        var output: URL?
        var index = 0
        var seen: Set<String> = []
        while index < values.count {
            let option = values[index]
            guard ["--target-pid", "--count", "--output"].contains(option),
                  seen.insert(option).inserted, index + 1 < values.count else {
                throw ArgumentError.invalid
            }
            let value = values[index + 1]
            switch option {
            case "--target-pid":
                guard let number = Int32(value), number > 0 else { throw ArgumentError.invalid }
                targetPID = number
            case "--count":
                guard let number = Int(value), (1...10_000).contains(number) else { throw ArgumentError.invalid }
                count = number
            case "--output":
                guard !value.isEmpty else { throw ArgumentError.invalid }
                output = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
            default: throw ArgumentError.invalid
            }
            index += 2
        }
        guard targetPID != nil, output != nil else { throw ArgumentError.invalid }
        return Arguments(preflight: false, targetPID: targetPID, count: count, output: output)
    }
}

private enum ArgumentError: Error { case usage, invalid }

private struct KeyObservation: Codable {
    let ordinal: Int
    let eventTimestampNs: UInt64
    let callbackReceivedAtNs: UInt64
    let keycode: Int64
    let slot: Int
    let autorepeat: Bool
    let flagsRaw: UInt64
    let frontmostPID: pid_t
}

private struct ObservationReport: Codable {
    let schemaVersion: Int
    let tier: String
    let phase: String
    let status: String
    let stopReason: String?
    let targetPID: pid_t
    let observerPID: pid_t
    let requestedCount: Int
    let observedCount: Int
    let timeoutSeconds: Int
    let armedAtNs: UInt64?
    let finishedAtNs: UInt64?
    let accessibilityTrustedAtStart: Bool
    let listenEventAllowedAtStart: Bool
    let tapDisabledByTimeoutCount: Int
    let tapDisabledByUserInputCount: Int
    let diagnosticErrors: [String]
    let observations: [KeyObservation]
    let interpretation: [String]
}

private final class RawKeyProbe {
    let targetPID: pid_t
    let requestedCount: Int
    let output: URL
    let accessibilityTrusted: Bool
    let listenEventAllowed: Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var observations: [KeyObservation] = []
    private var armedAtNs: UInt64?
    private var finishedAtNs: UInt64?
    private var status = "not-armed"
    private var stopReason: String?
    private var disabledByTimeout = 0
    private var disabledByUserInput = 0
    private var diagnosticErrors: [String] = []
    private(set) var exitCode: Int32 = 1
    private(set) var finished = false

    init(targetPID: pid_t, requestedCount: Int, output: URL,
         accessibilityTrusted: Bool, listenEventAllowed: Bool) {
        self.targetPID = targetPID
        self.requestedCount = requestedCount
        self.output = output
        self.accessibilityTrusted = accessibilityTrusted
        self.listenEventAllowed = listenEventAllowed
    }

    func install() -> Bool {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            emit(["armed": false, "reason": "output-already-exists; refusing to overwrite evidence", "output": output.path])
            exitCode = 3
            return false
        }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Prove the chosen destination is writable before installing any observer.
            try persist()
        } catch {
            emit(["armed": false, "reason": "cannot-create-output", "error": error.localizedDescription])
            exitCode = 3
            return false
        }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let probe = Unmanaged<RawKeyProbe>.fromOpaque(userInfo).takeUnretainedValue()
            probe.observe(type: type, event: event)
            // listenOnly cannot modify the event stream; no event is suppressed.
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback, userInfo: context) else {
            finish(reason: "tap-install-failed; no permission request was made", code: 3)
            emit(["armed": false, "tier": "session", "reason": "tap-install-failed; not evidence of missing keys", "output": output.path])
            return false
        }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            finish(reason: "tap-runloop-source-failed", code: 3)
            emit(["armed": false, "reason": "tap-runloop-source-failed", "output": output.path])
            cleanup()
            return false
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true) // Initial install only; never auto-recovers.
        guard CGEvent.tapIsEnabled(tap: tap) else {
            finish(reason: "tap-installed-but-not-enabled; not evidence of missing keys", code: 3)
            cleanup()
            emit(["armed": false, "tier": "session", "reason": "tap-installed-but-not-enabled", "output": output.path])
            return false
        }
        armedAtNs = DispatchTime.now().uptimeNanoseconds
        status = "armed"
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            self?.finish(reason: "timeout-60s", code: 1)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        do { try persist() }
        catch {
            diagnosticErrors.append("output-write-failed: " + error.localizedDescription)
            finish(reason: "output-write-failed", code: 3)
            cleanup()
            emit(["armed": false, "reason": "output-write-failed", "output": output.path])
            return false
        }
        emit(["armed": true, "targetPID": targetPID, "requestedCount": requestedCount,
              "output": output.path, "timeoutSeconds": 60,
              "phase": observationPhase, "tier": "session", "tapEnabled": true,
              "mode": "cgSessionEventTap/headInsertEventTap/listenOnly; Option+1/2/3 keyDown for target PID only"])
        return true
    }

    private func observe(type: CGEventType, event: CGEvent) {
        guard !finished else { return }
        let callbackReceivedAt = DispatchTime.now().uptimeNanoseconds
        if type == .tapDisabledByTimeout {
            disabledByTimeout += 1
            finish(reason: "tap-disabled-by-timeout; stopped without re-enabling", code: 4)
            return
        }
        if type == .tapDisabledByUserInput {
            disabledByUserInput += 1
            finish(reason: "tap-disabled-by-user-input; stopped without re-enabling", code: 4)
            return
        }
        guard type == .keyDown else { return }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let slot: Int
        switch keycode {
        case 18: slot = 1
        case 19: slot = 2
        case 20: slot = 3
        default: return
        }
        guard event.flags.contains(.maskAlternate),
              let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID == targetPID else { return }
        observations.append(KeyObservation(
            ordinal: observations.count + 1,
            eventTimestampNs: event.timestamp,
            callbackReceivedAtNs: callbackReceivedAt,
            keycode: keycode, slot: slot,
            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            flagsRaw: event.flags.rawValue, frontmostPID: frontmostPID))
        if observations.count >= requestedCount {
            finish(reason: "requested-count-observed", code: 0)
        }
    }

    func finish(reason: String, code: Int32) {
        guard !finished else { return }
        finished = true
        finishedAtNs = DispatchTime.now().uptimeNanoseconds
        stopReason = reason
        status = code == 0 ? "observation-complete" : "partial"
        exitCode = code
        timer?.invalidate()
        do { try persist() }
        catch {
            diagnosticErrors.append("final-output-write-failed: " + error.localizedDescription)
            exitCode = 3
            status = "partial"
            emit(["armed": false, "reason": "final-output-write-failed", "error": error.localizedDescription])
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func cleanup() {
        timer?.invalidate()
        timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    func summary() -> [String: Any] {
        ["armed": false, "status": status, "stopReason": stopReason ?? "not-set",
         "observedCount": observations.count, "requestedCount": requestedCount,
         "output": output.path,
         "phase": observationPhase, "tier": "session",
         "note": "No ordering verdict. Compare system session timestamps/callback order with M1 sender and Target receipts externally."]
    }

    private func persist() throws {
        let report = ObservationReport(
            schemaVersion: 1, tier: "session", phase: observationPhase,
            status: status, stopReason: stopReason, targetPID: targetPID,
            observerPID: ProcessInfo.processInfo.processIdentifier,
            requestedCount: requestedCount, observedCount: observations.count,
            timeoutSeconds: 60, armedAtNs: armedAtNs, finishedAtNs: finishedAtNs,
            accessibilityTrustedAtStart: accessibilityTrusted,
            listenEventAllowedAtStart: listenEventAllowed,
            tapDisabledByTimeoutCount: disabledByTimeout,
            tapDisabledByUserInputCount: disabledByUserInput,
            diagnosticErrors: diagnosticErrors, observations: observations,
            interpretation: [
                "Only keycodes 18/19/20 with Option and the chosen frontmost PID are retained.",
                "No characters, Unicode strings, clipboard contents, or other keystrokes are recorded.",
                "Events are retained in callback arrival order; event timestamps are not sorted or rewritten.",
                "This is a passive system-session stream observation, not proof of physical switch ordering.",
                "No root-only HID tap is attempted and no privilege escalation or permission request is made.",
                "A three-stage comparison still requires separately reading M1 sender and Target receipt logs.",
                "No PASS, input correctness, or application compatibility verdict is made."
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}

do {
    let arguments = try Arguments.parse()
    let accessibilityTrusted = AXIsProcessTrusted()
    let listenEventAllowed = CGPreflightListenEventAccess()
    if arguments.preflight {
        emit(["preflight": true, "accessibilityTrusted": accessibilityTrusted,
              "listenEventAllowed": listenEventAllowed, "installsTap": false,
              "requestsPermission": false,
              "tier": "session", "phase": "permission preflight only; no event observation"])
        exit(0)
    }
    // A passive listen-only tap uses ListenEvent authorization. AX is reported but
    // is not an additional permission requirement when ListenEvent is already allowed.
    guard listenEventAllowed else {
        emit(["armed": false, "reason": "listen-event-preflight-denied", "exitCode": 2,
              "accessibilityTrusted": accessibilityTrusted, "listenEventAllowed": false,
              "requestsPermission": false, "installsTap": false])
        exit(2)
    }
    let probe = RawKeyProbe(targetPID: arguments.targetPID!, requestedCount: arguments.count,
                            output: arguments.output!, accessibilityTrusted: accessibilityTrusted,
                            listenEventAllowed: listenEventAllowed)
    guard probe.install() else { exit(probe.exitCode) }
    CFRunLoopRun()
    if !probe.finished { probe.finish(reason: "runloop-ended-before-count", code: 1) }
    probe.cleanup()
    emit(probe.summary())
    exit(probe.exitCode)
} catch {
    emit(["armed": false, "reason": "invalid-arguments",
          "usage": "raw-key-probe --preflight OR --target-pid N --count 15 --output PATH; 60s timeout, passive observation only"])
    exit(2)
}
