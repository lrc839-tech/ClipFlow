import AppKit

// M0, explicit manual execution only. This checks known fixtures on the real
// general pasteboard, not another application's rendering or paste fidelity.
// Order: PNG, then RTF + HTML + plain-text representations.
// The original clipboard is held only in memory by PasteboardLease. Each fixture
// has its own lease, so the second test never mistakes the first fixture for the
// user's original clipboard. A named destination verifies the captured data's
// write/read roundtrip without disturbing the general-pasteboard lease count.

private enum GeneralRoundtripError: Error {
    case permissionHandoff
    case externalCopy
    case fixtureMismatch
    case restoreFailed
    case fixtureConstruction
}

private struct FixtureLog: Encodable {
    let items: Int
    let typeCounts: [Int]
    let byteCount: Int
    let equal: Bool
    let restore: Bool
}

private func writeDiagnostic(_ message: String) {
    // Fixed messages only: do not interpolate clipboard errors, types, hashes,
    // original data, or original file paths into diagnostics.
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func emitLog(for knownFixture: PasteboardSnapshot, equal: Bool, restored: Bool) {
    let log = FixtureLog(
        items: knownFixture.items.count,
        typeCounts: knownFixture.items.map { $0.representations.count },
        byteCount: knownFixture.items.reduce(0) { sum, item in
            sum + item.representations.values.reduce(0) { $0 + $1.count }
        },
        equal: equal,
        restore: restored
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(log) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

@MainActor
private func makeFixtures() throws -> [PasteboardSnapshot] {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw GeneralRoundtripError.fixtureConstruction }
    bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
    bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 1, y: 0)
    bitmap.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: 0, y: 1)
    bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: 1, y: 1)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw GeneralRoundtripError.fixtureConstruction
    }
    let image = PasteboardSnapshot(items: [.init(representations: [
        NSPasteboard.PasteboardType.png.rawValue: png
    ])])

    let text = "ClipFlow M0 known fixture 中文"
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.boldSystemFont(ofSize: 18),
        .foregroundColor: NSColor(deviceRed: 0.7, green: 0, blue: 0, alpha: 1)
    ])
    let rtf = try attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    let rich = PasteboardSnapshot(items: [.init(representations: [
        NSPasteboard.PasteboardType.rtf.rawValue: rtf,
        NSPasteboard.PasteboardType.html.rawValue:
            Data("<html><body><b>ClipFlow M0 known fixture 中文</b></body></html>".utf8),
        NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)
    ])])
    return [image, rich]
}

@MainActor
private func runFixture(_ fixture: PasteboardSnapshot, on board: NSPasteboard) throws {
    var equal = false
    var restored = false
    var didReplace = false
    var restoreError: Error?
    var operationError: Error?
    var knownCapture = fixture

    // A nested scope guarantees defer restoration before emitting the result.
    // The lease captures/validates the original BEFORE writing any fixture.
    // If the original is sensitive, unreadable, promised, unstable, or >64 MiB,
    // initialization throws and this test performs no intentional replacement.
    func perform() throws {
        let lease = try PasteboardLease(board: board, replacement: fixture)
        didReplace = true
        defer {
            do { restored = try lease.restoreIfOwned() }
            catch { restoreError = error }
        }
        guard lease.stillOwnsClipboard else { throw GeneralRoundtripError.externalCopy }
        let captured = try PasteboardSnapshot.capture(from: board)
        guard lease.stillOwnsClipboard else { throw GeneralRoundtripError.externalCopy }

        // Reject any fixture mismatch before using captured metadata in logs.
        // System-synthesized types are permitted but every input byte must match.
        guard captured.items.count == fixture.items.count else {
            throw GeneralRoundtripError.fixtureMismatch
        }
        for (saved, input) in zip(captured.items, fixture.items) {
            for (type, data) in input.representations {
                guard saved.representations[type] == data else {
                    throw GeneralRoundtripError.fixtureMismatch
                }
            }
        }
        knownCapture = captured

        let destination = NSPasteboard.withUniqueName()
        defer { destination.releaseGlobally() }
        try captured.write(to: destination)
        let reread = try PasteboardSnapshot.capture(from: destination)
        equal = (reread == captured)
        guard lease.stillOwnsClipboard else { throw GeneralRoundtripError.externalCopy }
        guard equal else { throw GeneralRoundtripError.fixtureMismatch }
    }

    do { try perform() }
    catch { operationError = error }

    if didReplace {
        emitLog(for: knownCapture, equal: equal, restored: restored)
    }
    if restoreError != nil { throw GeneralRoundtripError.restoreFailed }
    // A false restore means a later external copy won. Do not proceed to another
    // fixture, and never overwrite the new clipboard merely to finish testing.
    if didReplace && !restored { throw GeneralRoundtripError.externalCopy }
    if let operationError { throw operationError }
}

@main
private struct GeneralRoundtrip {
    @MainActor
    static func main() {
        do {
            let fixtures = try makeFixtures()
            let board = NSPasteboard.general
            if #available(macOS 15.4, *), board.accessBehavior != .alwaysAllow {
                // Do not initiate a possibly blocking clipboard-access prompt.
                // The user must explicitly handle access before this test runs.
                throw GeneralRoundtripError.permissionHandoff
            }
            for fixture in fixtures {
                try runFixture(fixture, on: board)
            }
        } catch GeneralRoundtripError.permissionHandoff {
            writeDiagnostic("当前剪贴板访问未设为始终允许。已在读取和写入前终止，请由用户处理系统剪贴板访问许可后重试。")
            exit(2)
        } catch GeneralRoundtripError.externalCopy {
            writeDiagnostic("检测到外部复制，已保留新剪贴板并中止剩余测试；restore=false 表示跳过旧快照恢复。")
            exit(3)
        } catch GeneralRoundtripError.restoreFailed {
            writeDiagnostic("原剪贴板恢复失败，请重新复制需要的内容。")
            exit(1)
        } catch PasteboardLeaseError.writeAndRestoreFailed {
            writeDiagnostic("测试写入和原剪贴板恢复均失败，请重新复制需要的内容。")
            exit(1)
        } catch GeneralRoundtripError.fixtureMismatch {
            writeDiagnostic("已知测试内容的非文本读取或往返比较失败；已按剪贴板归属尝试恢复。")
            exit(1)
        } catch {
            writeDiagnostic("测试已终止：原剪贴板可能敏感、不可读、超限、包含未支持承诺，或发生数据读写错误。未输出剪贴板内容。")
            exit(1)
        }
    }
}
