import Foundation
import RideCore

/// Cancels a scheduled action. Cancelling twice, or after it ran, does nothing.
@MainActor
final class TimerToken {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// Every delayed action in the app goes through this, so tests can run the same
/// production code on virtual time instead of sleeping.
@MainActor
protocol RideTimers: AnyObject {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> TimerToken
}

/// Real time, via structured tasks on the main actor.
@MainActor
final class SystemRideTimers: RideTimers {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> TimerToken {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return TimerToken { task.cancel() }
    }
}

/// Virtual time: actions run, in deadline order, only when the test advances the clock.
@MainActor
final class ManualRideTimers: RideTimers {
    private struct Entry {
        let id: Int
        let due: MonotonicInstant
        let action: @MainActor () -> Void
    }

    let clock: ManualClock
    private var entries: [Entry] = []
    private var nextID = 0
    private(set) var fired = 0

    init(clock: ManualClock) {
        self.clock = clock
    }

    var pending: Int { entries.count }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> TimerToken {
        nextID += 1
        let id = nextID
        entries.append(Entry(id: id, due: clock.now + delay, action: action))
        return TimerToken { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    /// Moves time forward, running every action that falls due on the way.
    func advance(by duration: Duration) {
        let end = clock.now + duration
        while let next = entries.filter({ $0.due <= end }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            entries.removeAll { $0.id == next.id }
            if next.due > clock.now { clock.advance(by: next.due.duration(since: clock.now)) }
            fired += 1
            next.action()
        }
        if end > clock.now { clock.advance(by: end.duration(since: clock.now)) }
    }
}
