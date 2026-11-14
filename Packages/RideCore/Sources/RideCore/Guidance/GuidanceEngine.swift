import Foundation

/// One step of a provider route. Apple MapKit's instruction describes the maneuver
/// at the END of the step's line (the line is the approach to it): verified on real
/// Bengaluru routes 2026-11-12, where every turn angle matched the text this way.
public struct PlannedStep: Sendable, Equatable {
    public var points: [Coordinate]
    public var instructions: String

    public init(points: [Coordinate], instructions: String) {
        self.points = points
        self.instructions = instructions
    }
}

public struct PlannedRoute: Sendable, Equatable {
    public var steps: [PlannedStep]
    public var expectedTravelSeconds: Double

    public init(steps: [PlannedStep], expectedTravelSeconds: Double) {
        self.steps = steps
        self.expectedTravelSeconds = expectedTravelSeconds
    }
}

public struct LocationFix: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Metres; negative means invalid (Core Location convention).
    public var horizontalAccuracy: Double
    public var observedAt: MonotonicInstant

    public init(coordinate: Coordinate, horizontalAccuracy: Double, observedAt: MonotonicInstant) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.observedAt = observedAt
    }
}

public struct GuidanceEngineConfiguration: Sendable, Equatable {
    public var drivingSide: DrivingSide
    /// Fixes with worse accuracy count as no location.
    public var maxAccuracyMetres: Double
    public var offRouteMetres: Double
    public var offRouteFixes: Int
    public var rerouteInterval: Duration
    public var arrivalMetres: Double
    /// Snapping window around the current progress; stops a fix jumping to a
    /// parallel or overlapping part of the route.
    public var searchBehindMetres: Double
    public var searchAheadMetres: Double
    /// The forward window also grows by this speed times the time since the last
    /// on-route fix, so a GPS gap (tunnel) does not look like leaving the route.
    public var maxSpeedMetresPerSecond: Double

    public init(
        drivingSide: DrivingSide = .left,
        maxAccuracyMetres: Double = 50,
        offRouteMetres: Double = 40,
        offRouteFixes: Int = 3,
        rerouteInterval: Duration = .seconds(15),
        arrivalMetres: Double = 25,
        searchBehindMetres: Double = 50,
        searchAheadMetres: Double = 400,
        maxSpeedMetresPerSecond: Double = 40
    ) {
        self.drivingSide = drivingSide
        self.maxAccuracyMetres = maxAccuracyMetres
        self.offRouteMetres = offRouteMetres
        self.offRouteFixes = offRouteFixes
        self.rerouteInterval = rerouteInterval
        self.arrivalMetres = arrivalMetres
        self.searchBehindMetres = searchBehindMetres
        self.searchAheadMetres = searchAheadMetres
        self.maxSpeedMetresPerSecond = maxSpeedMetresPerSecond
    }
}

public struct GuidanceUpdate: Sendable, Equatable {
    public var snapshot: NavigationSnapshot
    /// The rider has left the route; the owner should request a new route (already throttled).
    public var requestReroute: Bool
}

/// Turn-by-turn guidance over a static provider route: snaps fixes to the route,
/// tracks progress, picks the next maneuver, detects leaving the route and arrival,
/// and estimates time remaining. Pure logic driven by injected fixes and times.
public final class GuidanceEngine {
    struct PlannedManeuver: Equatable {
        /// Where the maneuver is complete (for a roundabout: where you leave the ring).
        var along: Double
        var maneuver: Maneuver
        var roundaboutDirection: RoundaboutDirection?
        var road: String?
        /// Where the countdown ends (for a roundabout: where you enter the ring).
        var countdownAlong: Double
        var exitNumber: Int?

        init(along: Double, maneuver: Maneuver, roundaboutDirection: RoundaboutDirection? = nil, road: String? = nil,
             countdownAlong: Double? = nil, exitNumber: Int? = nil) {
            self.along = along
            self.maneuver = maneuver
            self.roundaboutDirection = roundaboutDirection
            self.road = road
            self.countdownAlong = countdownAlong ?? along
            self.exitNumber = exitNumber
        }
    }

    public let session: SessionID
    public let generation: RouteGeneration
    public let totalMetres: Double
    let maneuvers: [PlannedManeuver]

    private let polyline: RoutePolyline
    private let expectedTravelSeconds: Double
    private let configuration: GuidanceEngineConfiguration
    public private(set) var progressMetres = 0.0
    private var offRouteCount = 0
    private var rerouting = false
    private var arrived = false
    private var lastRerouteRequest: MonotonicInstant?
    private var lastOnRoute: MonotonicInstant?
    private var lastSnapshot: NavigationSnapshot?

    public init?(route: PlannedRoute, session: SessionID, generation: RouteGeneration,
                 configuration: GuidanceEngineConfiguration = GuidanceEngineConfiguration()) {
        var points: [Coordinate] = []
        var stepStarts: [Int] = []
        for step in route.steps {
            let skipJoint = points.last != nil && step.points.first == points.last
            stepStarts.append(skipJoint ? points.count - 1 : points.count)
            points.append(contentsOf: skipJoint ? Array(step.points.dropFirst()) : step.points)
        }
        stepStarts = stepStarts.map { min($0, max(points.count - 1, 0)) }
        guard let polyline = RoutePolyline(points), route.expectedTravelSeconds.isFinite,
              route.expectedTravelSeconds >= 0 else { return nil }
        self.polyline = polyline
        self.session = session
        self.generation = generation
        self.configuration = configuration
        totalMetres = polyline.length
        expectedTravelSeconds = route.expectedTravelSeconds

        var pointAlong = [0.0]
        for i in points.indices.dropFirst() {
            let d = polyline.local(points[i]) - polyline.local(points[i - 1])
            pointAlong.append(pointAlong[i - 1] + (d.x * d.x + d.y * d.y).squareRoot())
        }
        let alongs = stepStarts.map { pointAlong[$0] }
        let ends = Array(alongs.dropFirst()) + [polyline.length]
        var maneuvers: [PlannedManeuver] = []
        for index in route.steps.indices {
            let instructions = route.steps[index].instructions
            let along = ends[index]
            guard along > 0 || !instructions.isEmpty else { continue }
            let next = index + 1 < ends.count ? ends[index + 1] : polyline.length
            let cues = ManeuverClassifier.cues(instructions)
            if cues.kind == .roundabout {
                // Apple's roundabout step ends where the route leaves the ring; the ring is
                // the end of this step. Measure from the road in to the road out.
                let ring = Self.roundabout(polyline, exit: along, floor: maneuvers.last?.along ?? 0,
                                           stepAfter: next - along, drivingSide: configuration.drivingSide)
                let (maneuver, direction) = ManeuverClassifier.roundabout(cues, angle: ring?.angle,
                                                                          drivingSide: configuration.drivingSide)
                maneuvers.append(PlannedManeuver(along: along, maneuver: maneuver, roundaboutDirection: direction,
                                                 road: Self.road(instructions), countdownAlong: ring?.entry,
                                                 exitNumber: cues.exit))
                continue
            }
            let geometry = Self.geometry(polyline, at: along, stepLength: next - along, roundabout: false)
            let (maneuver, direction) = ManeuverClassifier.classify(cues, geometry,
                                                                    drivingSide: configuration.drivingSide)
            maneuvers.append(PlannedManeuver(along: along, maneuver: maneuver, roundaboutDirection: direction,
                                             road: Self.road(instructions)))
        }
        if maneuvers.last?.maneuver != .arrival {
            maneuvers.append(PlannedManeuver(along: polyline.length, maneuver: .arrival))
        }
        self.maneuvers = maneuvers
    }

    public func update(_ fix: LocationFix) -> GuidanceUpdate {
        var update = evaluate(fix)
        update.snapshot.measurementAt = fix.observedAt
        lastSnapshot = update.snapshot
        return update
    }

    /// The last result, re-stamped. For a rider standing still while Core Location is
    /// quiet: it is not a new measurement, so it never counts towards leaving the route.
    public func refresh(at instant: MonotonicInstant) -> NavigationSnapshot? {
        guard var snapshot = lastSnapshot else { return nil }
        snapshot.observedAt = instant
        lastSnapshot = snapshot
        return snapshot
    }

    private func evaluate(_ fix: LocationFix) -> GuidanceUpdate {
        if arrived { return GuidanceUpdate(snapshot: snapshot(.arrived, at: fix.observedAt), requestReroute: false) }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= configuration.maxAccuracyMetres else {
            return GuidanceUpdate(snapshot: snapshot(.noLocation, at: fix.observedAt), requestReroute: false)
        }

        let tolerance = configuration.offRouteMetres + min(fix.horizontalAccuracy, 25)
        let gap = lastOnRoute.map { fix.observedAt.duration(since: $0) } ?? .zero
        let gapSeconds = Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18
        let ahead = configuration.searchAheadMetres + max(gapSeconds, 0) * configuration.maxSpeedMetresPerSecond
        let projected = polyline.project(fix.coordinate,
                                         within: progressMetres - configuration.searchBehindMetres,
                                         progressMetres + ahead)
        guard let projected, projected.offset <= tolerance else {
            offRouteCount += 1
            guard offRouteCount >= configuration.offRouteFixes else {
                return GuidanceUpdate(snapshot: guidance(at: fix.observedAt), requestReroute: false)
            }
            rerouting = true
            let due = lastRerouteRequest.map { fix.observedAt.duration(since: $0) >= configuration.rerouteInterval } ?? true
            if due { lastRerouteRequest = fix.observedAt }
            return GuidanceUpdate(snapshot: snapshot(.rerouting, at: fix.observedAt), requestReroute: due)
        }

        offRouteCount = 0
        rerouting = false
        lastOnRoute = fix.observedAt
        progressMetres = max(progressMetres, projected.along)
        if totalMetres - progressMetres <= configuration.arrivalMetres {
            arrived = true
            return GuidanceUpdate(snapshot: snapshot(.arrived, at: fix.observedAt), requestReroute: false)
        }
        return GuidanceUpdate(snapshot: guidance(at: fix.observedAt), requestReroute: false)
    }

    private func guidance(at instant: MonotonicInstant) -> NavigationSnapshot {
        if rerouting { return snapshot(.rerouting, at: instant) }
        let index = maneuvers.firstIndex { $0.along > progressMetres + 1 } ?? maneuvers.count - 1
        let next = maneuvers[index]
        let remaining = max(totalMetres - progressMetres, 0)
        var s = snapshot(.active, at: instant)
        // A roundabout counts down to its entry and stays current until its exit.
        s.step = GuidanceStep(maneuver: next.maneuver, roundaboutExit: next.exitNumber,
                              roundaboutDirection: next.roundaboutDirection,
                              distanceMetres: Int(max(next.countdownAlong - progressMetres, 0).rounded()),
                              roadText: next.road, sequence: index)
        s.remainingMetres = Int(remaining.rounded())
        s.remainingSeconds = totalMetres > 0 ? Int((expectedTravelSeconds * remaining / totalMetres).rounded()) : 0
        return s
    }

    private func snapshot(_ state: NavigationState, at instant: MonotonicInstant) -> NavigationSnapshot {
        NavigationSnapshot(session: session, generation: generation, observedAt: instant, state: state)
    }

    static let nearMetres = 30.0
    static let farMetres = 80.0
    static let roundaboutFarMetres = 150.0

    static func geometry(_ line: RoutePolyline, at along: Double, stepLength: Double,
                         roundabout: Bool) -> ManeuverClassifier.Geometry {
        guard let incoming = line.bearing(from: along - nearMetres, to: along) else {
            return ManeuverClassifier.Geometry(near: nil, far: nil)
        }
        let near = line.bearing(from: along, to: along + min(nearMetres, stepLength))
            .map { RoutePolyline.turn(from: incoming, to: $0) }
        let reach = min(roundabout ? roundaboutFarMetres : farMetres, stepLength)
        let far = reach > nearMetres
            ? line.bearing(from: along, to: along + reach).map { RoutePolyline.turn(from: incoming, to: $0) }
            : nil
        return ManeuverClassifier.Geometry(near: near, far: far)
    }

    /// The ring of a roundabout whose exit is at `exit`, and the exit angle.
    ///
    /// Walking back from the exit in 5 m pieces, the ring is the stretch that keeps
    /// turning the way traffic circulates (right for clockwise, left-hand traffic); it
    /// ends at a turn the other way (the entry flare) or 25 m without turning. The
    /// angle is the total heading change from the road in (30 m ending 15 m before the
    /// entry) through the ring to the road out (from 5 m after the exit), summed in
    /// small steps so a U-turn and sharp turns can't be confused. With no ring in the
    /// line it is the plain angle between the road before and after the exit.
    static func roundabout(_ line: RoutePolyline, exit: Double, floor: Double, stepAfter: Double,
                           drivingSide: DrivingSide) -> (entry: Double, angle: Double)? {
        let piece = 5.0
        let circulation = drivingSide == .left ? 1.0 : -1.0
        let outEnd = exit + max(min(35, stepAfter), 10)
        guard let out = line.bearing(from: min(exit + 5, outEnd - 5), to: outEnd) else { return nil }
        var ring: [Double] = []
        var curved = 0.0, straight = 0.0, firstRingPiece = 0
        while ring.count < 100, exit - Double(ring.count + 1) * piece >= floor {
            let k = Double(ring.count)
            guard let bearing = line.bearing(from: exit - (k + 1) * piece, to: exit - k * piece) else { break }
            if let later = ring.last {
                let forward = circulation * RoutePolyline.turn(from: bearing, to: later)
                if forward < -8, curved >= 10 { break }
                if forward > 2 {
                    curved += forward
                    straight = 0
                    firstRingPiece = ring.count
                } else {
                    straight += piece
                }
                if curved >= 20, straight >= 25 { break }
            }
            ring.append(bearing)
        }
        guard curved >= 20 else {
            guard let before = line.bearing(from: max(exit - 40, 0), to: max(exit - 5, 1)) else { return nil }
            return (exit, RoutePolyline.turn(from: before, to: out))
        }
        let entry = exit - Double(firstRingPiece + 1) * piece
        let approachEnd = entry >= 20 ? entry - 15 : entry
        guard let approach = line.bearing(from: max(approachEnd - 30, 0), to: approachEnd) else { return nil }
        let path = [approach] + ring[0...firstRingPiece].reversed() + [out]
        let angle = zip(path, path.dropFirst()).reduce(0.0) { $0 + RoutePolyline.turn(from: $1.0, to: $1.1) }
        return (entry, angle)
    }

    /// Road name after "onto"/"on" in an instruction, if any.
    static func road(_ instructions: String) -> String? {
        for marker in [" onto ", " on to "] {
            if let range = instructions.range(of: marker, options: .caseInsensitive) {
                let name = instructions[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }
}
