import Foundation

/// Decides when to speak and what to say, from the same snapshots that drive the
/// dashboard. Each distance stage is spoken at most once per maneuver.
public struct VoicePromptPlanner: Sendable {
    public static let farMetres = 1_200
    public static let farFloorMetres = 700
    public static let midMetres = 300
    public static let nowMetres = 60

    private struct StepKey: Equatable {
        var generation: RouteGeneration
        var maneuver: Maneuver
        var direction: RoundaboutDirection?
        var road: String?
    }

    private enum Stage: Int, Comparable {
        case none, far, mid, now
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    private var step: StepKey?
    private var spoken: Stage = .none
    private var lastState: NavigationState?

    public init() {}

    public mutating func prompt(for snapshot: NavigationSnapshot) -> String? {
        defer { lastState = snapshot.state }
        switch snapshot.state {
        case .rerouting:
            return lastState == .rerouting ? nil : "Rerouting."
        case .noLocation:
            return lastState == .noLocation ? nil : "GPS signal lost."
        case .arrived:
            return lastState == .arrived ? nil : "You have arrived."
        case .active:
            break
        default:
            step = nil
            spoken = .none
            return nil
        }
        guard let next = snapshot.step, next.maneuver != .unsupported else { return nil }

        let key = StepKey(generation: snapshot.generation, maneuver: next.maneuver,
                          direction: next.roundaboutDirection, road: next.roadText)
        if key != step {
            step = key
            spoken = .none
        }
        let d = next.distanceMetres
        let phrase = Self.phrase(next)

        if next.maneuver == .straight {
            guard spoken == .none, d >= 1_000 else { return nil }
            spoken = .now
            return "Continue straight for \(Self.spoken(d))."
        }
        if d <= Self.nowMetres {
            guard spoken < .now else { return nil }
            spoken = .now
            return "Now, \(phrase)."
        }
        if d <= Self.midMetres {
            guard spoken < .mid else { return nil }
            spoken = .mid
            return "In \(Self.spoken(d)), \(phrase)."
        }
        if d <= Self.farMetres, d >= Self.farFloorMetres {
            guard spoken < .far else { return nil }
            spoken = .far
            return "In \(Self.spoken(d)), \(phrase)."
        }
        return nil
    }

    static func phrase(_ step: GuidanceStep) -> String {
        let onto = step.roadText.map { " onto \($0)" } ?? ""
        switch step.maneuver {
        case .turnLeft: return "turn left" + onto
        case .turnRight: return "turn right" + onto
        case .slightLeft: return "bear left" + onto
        case .slightRight: return "bear right" + onto
        case .sharpLeft: return "turn sharp left" + onto
        case .sharpRight: return "turn sharp right" + onto
        case .keepLeft: return "keep left" + onto
        case .keepRight: return "keep right" + onto
        case .forkLeft: return "keep left at the fork" + onto
        case .forkRight: return "keep right at the fork" + onto
        case .rampLeft: return "take the exit on the left" + onto
        case .rampRight: return "take the exit on the right" + onto
        case .merge: return "merge" + onto
        case .uTurnLeft, .uTurnRight: return "make a U-turn"
        case .roundaboutClockwise, .roundaboutCounterClockwise:
            return "at the roundabout, " + roundabout(step.roundaboutDirection)
                + (step.roadText.map { ", towards \($0)" } ?? "")
        case .ferry: return "take the ferry"
        case .ferryTrain: return "take the train ferry"
        case .arrival: return "you will arrive at your destination"
        case .straight: return "continue straight" + onto
        case .unsupported: return "follow the route"
        }
    }

    static func roundabout(_ direction: RoundaboutDirection?) -> String {
        switch direction {
        case .straight: "go straight on"
        case .left: "take the exit on the left"
        case .right: "take the exit on the right"
        case .slightLeft: "bear left"
        case .slightRight: "bear right"
        case .sharpLeft: "take the sharp left exit"
        case .sharpRight: "take the sharp right exit"
        case .uTurn: "go all the way round"
        case nil: "take your exit"
        }
    }

    /// "300 metres" (nearest 50) or "1.5 kilometres".
    static func spoken(_ metres: Int) -> String {
        if metres < 1_000 {
            let rounded = max(50, Int((Double(metres) / 50).rounded()) * 50)
            return "\(rounded) metres"
        }
        let km = (Double(metres) / 100).rounded() / 10
        if km == km.rounded() {
            let whole = Int(km)
            return whole == 1 ? "1 kilometre" : "\(whole) kilometres"
        }
        return String(format: "%.1f kilometres", km)
    }
}
