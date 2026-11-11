import Foundation
import Testing
@testable import ClipFlowCore

struct SerialTaskQueueTests {
    @Test @MainActor
    func slowImageWorkDoesNotBlockIndependentPasteQueue() async throws {
        var releaseImage: CheckedContinuation<Void, Never>?
        var imageFinished = false
        var pasted: [Int] = []
        let imageQueue = SerialTaskQueue<Int> { _ in
            await withCheckedContinuation { releaseImage = $0 }
            imageFinished = true
        }
        let pasteQueue = SerialTaskQueue<Int> { pasted.append($0) }
        imageQueue.enqueue(1)
        while releaseImage == nil { await Task.yield() }
        for index in 0..<120 { pasteQueue.enqueue(index) }
        for _ in 0..<1_000 where pasted.count < 120 { await Task.yield() }
        #expect(pasted == Array(0..<120))
        #expect(!imageFinished)
        releaseImage?.resume()
        for _ in 0..<1_000 where !imageFinished { await Task.yield() }
        #expect(imageFinished)
    }
    @Test
    @MainActor
    func testBurstRetainsOrderAndSerializesWork() async {
        var active = 0
        var maximum = 0
        var results: [Int] = []
        let queue = SerialTaskQueue<Int> { value in
            active += 1
            maximum = max(maximum, active)
            try? await Task.sleep(nanoseconds: 1_000_000)
            results.append(value)
            active -= 1
        }
        for value in 0..<120 { queue.enqueue(value) }
        let deadline = Date().addingTimeInterval(5)
        while results.count < 120 && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(results == Array(0..<120))
        #expect(maximum == 1)
    }
}
