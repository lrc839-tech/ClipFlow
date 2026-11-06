import Foundation
import Testing
@testable import ClipFlowCore

struct SerialTaskQueueTests {
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
