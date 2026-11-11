// Explicit local acceptance helper. Input remains private; stdout is metadata only.
// Compile with PasteboardSnapshot, ContentDescriptor, HistoryStore and
// RichTextImageCompletion sources plus -I Sources/CSQLite -parse-as-library.
import AppKit
import Foundation

@main struct DingTalkImageCheck {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do {
            let args = CommandLine.arguments
            guard args.count == 3 else { throw ImageCompletionError.invalidHTML }
            let source = try JSONDecoder().decode(PasteboardSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            let result = try await RichTextImageCompletion.complete(source)
            let directory = URL(fileURLWithPath: args[2])
            let store = try HistoryStore(directory: directory)
            let record = try await store.record(snapshot: source)
            guard try await store.savePreparedSnapshot(id: record.id, sourceFingerprint: record.fingerprint, result: result) else { throw HistoryStoreError.invalidSnapshot }
            let reopened = try HistoryStore(directory: directory)
            guard let saved = try await reopened.preparedSnapshot(id: record.id) else { throw HistoryStoreError.invalidSnapshot }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            try saved.forSystemPaste.write(to: board)
            let target = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
            target.isRichText = true; target.importsGraphics = true
            guard target.readSelection(from: board) else { throw ImageCompletionError.invalidHTML }
            var attachments = 0
            target.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: target.string.utf16.count)) { value, _, _ in
                if value is NSTextAttachment { attachments += 1 }
            }
            guard attachments == result.imageCount else { throw ImageCompletionError.invalidHTML }
            let json: [String: Any] = ["result": "passed", "downloadedImages": result.imageCount,
                "receivedAttachments": attachments, "reopenedSnapshotMatches": saved == result.snapshot,
                "textMatches": target.string == saved.plainText, "sourceRetained": try await reopened.load().first?.snapshot == source,
                "outputBytes": saved.items.flatMap { Array($0.representations.values) }.reduce(0) { $0 + $1.count }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            // Never expose private image URLs or HTML through a thrown error.
            let reason = (error as? ImageCompletionError)?.localizedDescription ?? "local_conversion_or_store_failed"
            print(String(decoding: (try? JSONSerialization.data(withJSONObject: ["result":"failed", "reason":reason])) ?? Data(), as: UTF8.self))
            exit(1)
        }
    }
}
