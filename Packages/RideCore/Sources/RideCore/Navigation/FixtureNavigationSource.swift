import Foundation

/// Anything that turns a provider's guidance into typed snapshots: the fixture
/// replay, the Google adapter, or (task 19 only) the Apple fallback.
public protocol NavigationSource: AnyObject {
    var onSnapshot: ((NavigationSnapshot) -> Void)? { get set }
    func stop()
}

public struct FixtureStep: Sendable, Equatable {
    public var maneuver: Maneuver
    public var roundaboutExit: Int?
    public var roundaboutDirection: RoundaboutDirection?
    /// Distance travelled before reaching this maneuver.
    public var lengthMetres: Int
    public var roadText: String?

    public init(_ maneuver: Maneuver, after lengthMetres: Int, exit: Int? = nil,
                direction: RoundaboutDirection? = nil, road: String? = nil) {
        self.maneuver = maneuver
        self.roundaboutExit = exit
        self.roundaboutDirection = direction
        self.lengthMetres = lengthMetres
        self.roadText = road
    }
}

public struct FixtureRoute: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var steps: [FixtureStep]
    public var metresPerSecond: Double

    public init(name: String, steps: [FixtureStep], metresPerSecond: Double = 12) {
        self.name = name
        self.steps = steps
        self.metresPerSecond = metresPerSecond
    }

    public var totalMetres: Int { steps.reduce(0) { $0 + $1.lengthMetres } }

    /// Synthetic demo used by the no-key simulation; no real place or route.
    public static let demo = FixtureRoute(name: "Demo loop", steps: [
        FixtureStep(.straight, after: 150, road: "Start Road"),
        FixtureStep(.turnLeft, after: 400, road: "First Cross"),
        FixtureStep(.turnRight, after: 650, road: "Second Main"),
        FixtureStep(.roundaboutClockwise, after: 1_200, exit: 2, direction: .straight, road: "Circle"),
        FixtureStep(.slightLeft, after: 500, road: "Service Road"),
        FixtureStep(.uTurnRight, after: 300),
        FixtureStep(.arrival, after: 250, road: "Destination"),
    ])
}

/// Replays a synthetic route on an injected clock. Never touches the network.
public final class FixtureNavigationSource: NavigationSource {
    public var onSnapshot: ((NavigationSnapshot) -> Void)?

    public let route: FixtureRoute
    private let clock: RideClock
    private var session: SessionID?
    private var generation = RouteGeneration(0)
    private var startedAt: MonotonicInstant?
    private var finished = false

    public init(route: FixtureRoute, clock: RideClock) {
        self.route = route
        self.clock = clock
    }

    public func preview(session: SessionID, generation: RouteGeneration) {
        self.session = session
        self.generation = generation
        startedAt = nil
        finished = false
        emit(.preview)
    }

    public func start() {
        guard session != nil else { return }
        startedAt = clock.now
        tick()
    }

    /// Advances the simulated rider; call on the app's tick.
    public func tick() {
        guard let startedAt, !finished else { return }
        let elapsed = clock.now.duration(since: startedAt).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let travelled = Int(seconds * route.metresPerSecond)
        let total = route.totalMetres
        guard travelled < total else {
            finished = true
            emit(.arrived, remainingMetres: 0, remainingSeconds: 0)
            return
        }

        var boundary = 0
        for (index, step) in route.steps.enumerated() {
            boundary += step.lengthMetres
            if travelled < boundary {
                let remaining = total - travelled
                emit(
                    .active,
                    step: GuidanceStep(maneuver: step.maneuver, roundaboutExit: step.roundaboutExit,
                                       roundaboutDirection: step.roundaboutDirection,
                                       distanceMetres: boundary - travelled, roadText: step.roadText,
                                       sequence: index),
                    remainingMetres: remaining,
                    remainingSeconds: Int(Double(remaining) / route.metresPerSecond)
                )
                return
            }
        }
    }

    public func stop() {
        guard session != nil else { return }
        emit(.stopped)
        startedAt = nil
        session = nil
    }

    private func emit(_ state: NavigationState, step: GuidanceStep? = nil,
                      remainingMetres: Int? = nil, remainingSeconds: Int? = nil) {
        guard let session else { return }
        onSnapshot?(NavigationSnapshot(
            session: session, generation: generation, observedAt: clock.now, state: state,
            step: step, remainingMetres: remainingMetres, remainingSeconds: remainingSeconds,
            measurementAt: clock.now
        ))
    }
}
