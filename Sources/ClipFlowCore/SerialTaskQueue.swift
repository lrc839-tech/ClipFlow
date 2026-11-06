import Foundation

/// Every accepted request is retained; there is no debounce/drop window.
@MainActor
public final class SerialTaskQueue<Request> {
    private var pending: [Request] = []
    private var worker: Task<Void, Never>?
    private let execute: (Request) async -> Void
    public var count: Int { pending.count + (worker == nil ? 0 : 1) }
    public init(execute: @escaping (Request) async -> Void) { self.execute = execute }

    public func enqueue(_ request: Request) {
        pending.append(request)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty {
                let request = pending.removeFirst()
                await execute(request)
            }
            worker = nil
        }
    }
}
