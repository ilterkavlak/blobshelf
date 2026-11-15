import Foundation

/// Runs `action` once `tick()` has been called `count` times (immediately if `count` is zero).
@MainActor
public final class Countdown {
    private var remaining: Int?
    private var ticks = 0
    private let action: @MainActor () -> Void

    public init(_ count: Int? = nil, action: @escaping @MainActor () -> Void) {
        self.action = action
        if let count { start(count) }
    }

    public func start(_ count: Int) {
        remaining = count
        fire()
    }

    public func tick() {
        ticks += 1
        fire()
    }

    private func fire() {
        guard let remaining, ticks >= remaining else { return }
        self.remaining = nil
        action()
    }
}
