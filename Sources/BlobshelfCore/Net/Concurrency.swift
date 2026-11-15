import Foundation

/// Runs `operation` on every element, at most `limit` at a time, and hands each result to
/// `onResult` in completion order. The first error thrown by either cancels the rest.
func concurrentForEach<Element: Sendable, Output: Sendable>(
    _ elements: some Sequence<Element>, limit: Int,
    operation: @escaping @Sendable (Element) async throws -> Output,
    onResult: (Output) throws -> Void = { _ in }
) async throws {
    try await withThrowingTaskGroup(of: Output.self) { group in
        var iterator = elements.makeIterator()
        func addNext() -> Bool {
            guard let element = iterator.next() else { return false }
            group.addTask { try await operation(element) }
            return true
        }
        for _ in 0..<limit {
            guard addNext() else { break }
        }
        while let output = try await group.next() {
            try onResult(output)
            _ = addNext()
        }
    }
}

/// Caps how many multipart parts are held in memory at once across all uploads, so parallel
/// backups of large files stay within `limit` × part size.
actor PartBudget {
    static let shared = PartBudget(limit: 8)

    private var available: Int
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) { available = limit }

    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty { available += 1 } else { waiting.removeFirst().continuation.resume() }
    }
}
