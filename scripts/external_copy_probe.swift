import AppKit
import Dispatch
import Darwin

// Explicit M1 T11 controlled experiment only. This independent writer simulates
// a new copy through NSPasteboard.general; it is NOT a physical Command+C test.
// The first change after arming is assumed to be the app's temporary paste write.
// The probe cannot attribute that change to a process: avoid other copies while
// armed. It never reads/snapshots the initial clipboard and never restores it.
// The known test fixture intentionally remains as the user's simulated new copy.
// NSPasteboard has no atomic cross-process compare-and-swap: the last ownership
// check and fixture write still have a small unavoidable race window.

private func emitProbe(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

private func failProbe(_ reason: String, code: Int32 = 1) -> Never {
    emitProbe(["armed": false, "reason": reason])
    exit(code)
}

@main
private struct ExternalCopyProbe {
    @MainActor
    static func main() {
        let board = NSPasteboard.general
        if #available(macOS 15.4, *) {
            guard board.accessBehavior == .alwaysAllow else {
                failProbe("clipboard_access_required_no_payload_read", code: 2)
            }
        } else {
            failProbe("clipboard_access_preflight_unavailable", code: 2)
        }

        // Metadata only. Do not capture, retain, print, or hash the user's data.
        let baseline = board.changeCount
        emitProbe(["armed": true])
        let triggerDeadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        var temporaryWriteCount: Int?
        while DispatchTime.now().uptimeNanoseconds < triggerDeadline {
            let current = board.changeCount
            if current != baseline {
                temporaryWriteCount = current
                break
            }
            usleep(5_000)
        }
        guard let temporaryWriteCount else {
            failProbe("trigger_timeout_no_fixture_written")
        }

        usleep(50_000)
        guard board.changeCount == temporaryWriteCount else {
            failProbe("another_copy_observed_no_fixture_written")
        }
        if #available(macOS 15.4, *), board.accessBehavior != .alwaysAllow {
            failProbe("clipboard_access_changed_no_fixture_written", code: 2)
        }

        let fixtureText = "ClipFlow-M1-NewCopy"
        let writeCount: Int
        do {
            // Snapshot.write uses currentHostOnly. No original user data is read.
            // Recheck immediately before writing; there is no atomic CAS API.
            guard board.changeCount == temporaryWriteCount else {
                failProbe("another_copy_observed_no_fixture_written")
            }
            writeCount = try PasteboardSnapshot.text(fixtureText).write(to: board)
        } catch {
            failProbe("fixture_write_failed")
        }

        // Observe the full interval so a delayed restoration cannot be hidden by
        // checking immediately after our write. The app's configured wait should
        // be below this interval (the intended M1 experiment uses 500 ms).
        let observationDeadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while DispatchTime.now().uptimeNanoseconds < observationDeadline {
            usleep(5_000)
        }

        let captureCount = board.changeCount
        var preserved = false
        do {
            let final = try PasteboardSnapshot.capture(from: board)
            preserved = final.items.count == 1 && final.plainText == fixtureText
        } catch {
            // Never serialize the error or any final clipboard payload/type/hash.
            preserved = false
        }
        let finalCount = board.changeCount
        // A change after the comparison invalidates the result, even if a previous
        // read happened to match our fixture. Do not write anything else afterwards.
        preserved = preserved && finalCount == captureCount
        emitProbe(["newCopyPreserved": preserved,
                   "writeChangeCount": writeCount,
                   "finalChangeCount": finalCount])
        exit(preserved ? 0 : 1)
    }
}
