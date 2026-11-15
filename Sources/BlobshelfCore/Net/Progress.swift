import Foundation
import os

public typealias ProgressHandler = @Sendable (_ done: Int64, _ total: Int64) -> Void

/// Lets a progress report through at most every `interval`, plus the final one, so a fast transfer
/// does not flood the UI with an update per network write.
struct ProgressThrottle: Sendable {
    static let interval: Duration = .milliseconds(100)
    private var last: ContinuousClock.Instant?

    mutating func shouldReport(done: Int64, total: Int64, at now: ContinuousClock.Instant = .now) -> Bool {
        if total > 0 && done >= total || last.map({ now - $0 >= Self.interval }) ?? true {
            last = now
            return true
        }
        return false
    }
}

/// Reports one request's upload or download progress to `handler`, throttled.
final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: ProgressHandler
    private let throttle = OSAllocatedUnfairLock(initialState: ProgressThrottle())
    private var observation: NSKeyValueObservation?

    init(_ handler: @escaping ProgressHandler) { self.handler = handler }

    private func report(_ done: Int64, _ total: Int64) {
        if throttle.withLock({ $0.shouldReport(done: done, total: total) }) { handler(done, total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard task is URLSessionDownloadTask else { return }
        observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
            self?.report(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
        }
    }
}

/// Sums the bytes sent by parts uploading in parallel into one progress for the whole file.
/// A part's count never goes down, so a retried part cannot move the total backwards.
final class PartProgress: Sendable {
    private let size: Int64
    private let handler: ProgressHandler
    private let sent = OSAllocatedUnfairLock(initialState: (parts: [Int: Int64](), total: Int64(0)))

    init(size: Int64, handler: @escaping ProgressHandler) {
        self.size = size
        self.handler = handler
    }

    func handler(forPart part: Int) -> ProgressHandler {
        { [self] done, _ in
            let total = sent.withLock { state in
                let previous = state.parts[part] ?? 0
                if done > previous {
                    state.parts[part] = done
                    state.total += done - previous
                }
                return state.total
            }
            handler(total, size)
        }
    }
}
