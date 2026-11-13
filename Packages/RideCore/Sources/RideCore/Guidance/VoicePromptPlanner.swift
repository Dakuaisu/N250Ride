import Foundation

public enum VoiceStyle: String, Sendable, Codable, CaseIterable {
    /// Every stage, with road names (the original behaviour).
    case detailed
    /// No early 1 km warning and no road names: shorter, fewer interruptions.
    case concise
}

public struct VoicePrompt: Sendable, Equatable {
    public enum Priority: Int, Sendable, Comparable {
        case turn, status
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var text: String
    /// Status changes (rerouting, GPS lost, arrival) replace pending turn prompts.
    public var priority: Priority
    /// Which route the prompt belongs to; a prompt for another session or
    /// generation is obsolete and must not be spoken.
    public var session: SessionID
    public var generation: RouteGeneration

    public init(text: String, priority: Priority, session: SessionID, generation: RouteGeneration) {
        self.text = text
        self.priority = priority
        self.session = session
        self.generation = generation
    }
}

/// Decides when to speak and what to say, from the same snapshots that drive the
/// dashboard. Each distance stage is spoken at most once per maneuver; a maneuver is
/// identified by session, route generation and its position in the route.
public struct VoicePromptPlanner: Sendable {
    public static let farMetres = 1_200
    public static let farFloorMetres = 700
    public static let midMetres = 300
    public static let nowMetres = 60

    private struct StepKey: Equatable {
        var session: SessionID
        var generation: RouteGeneration
        var maneuver: Maneuver
        var direction: RoundaboutDirection?
        var road: String?
        var sequence: Int?
    }

    private enum Stage: Int, Comparable {
        case none, far, mid, now
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    private var step: StepKey?
    private var spoken: Stage = .none
    private var lastState: NavigationState?
    public var style: VoiceStyle

    public init(style: VoiceStyle = .detailed) {
        self.style = style
    }

    public mutating func prompt(for snapshot: NavigationSnapshot) -> String? {
        next(for: snapshot)?.text
    }

    public mutating func next(for snapshot: NavigationSnapshot) -> VoicePrompt? {
        let status = snapshot.state != .active
        return plan(snapshot).map {
            VoicePrompt(text: $0, priority: status ? .status : .turn, session: snapshot.session,
                        generation: snapshot.generation)
        }
    }

    /// The current instruction again, on request. Nil unless guidance is active.
    public func repeatPrompt(for snapshot: NavigationSnapshot) -> String? {
        guard snapshot.state == .active, let next = snapshot.step, next.maneuver != .unsupported else { return nil }
        if next.maneuver == .straight { return "Continue straight for \(Self.spoken(next.distanceMetres))." }
        return "In \(Self.spoken(next.distanceMetres)), \(phrase(next))."
    }

    private mutating func plan(_ snapshot: NavigationSnapshot) -> String? {
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

        let key = StepKey(session: snapshot.session, generation: snapshot.generation, maneuver: next.maneuver,
                          direction: next.roundaboutDirection, road: next.roadText, sequence: next.sequence)
        if key != step {
            step = key
            spoken = .none
        }
        let d = next.distanceMetres
        let phrase = phrase(next)

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
        if style == .detailed, d <= Self.farMetres, d >= Self.farFloorMetres {
            guard spoken < .far else { return nil }
            spoken = .far
            return "In \(Self.spoken(d)), \(phrase)."
        }
        return nil
    }

    func phrase(_ step: GuidanceStep) -> String {
        Self.phrase(step, roads: style == .detailed)
    }

    static func phrase(_ step: GuidanceStep, roads: Bool = true) -> String {
        let road = roads ? step.roadText : nil
        let onto = road.map { " onto \($0)" } ?? ""
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
                + (road.map { ", towards \($0)" } ?? "")
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
