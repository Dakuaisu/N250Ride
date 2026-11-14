import Foundation

/// Which side of the road traffic keeps to. Sets roundabout circulation and the
/// side of U-turns (left-hand traffic, e.g. India: clockwise roundabouts, U-turns
/// to the right).
public enum DrivingSide: String, Sendable, Codable {
    case left
    case right
}

/// Turns a route step into a typed maneuver for providers without structured
/// guidance (Apple MapKit). Geometry is primary; English instruction text refines
/// the kind and must agree on the side. Anything ambiguous is `.unsupported`.
public enum ManeuverClassifier {
    public enum Side: Sendable, Equatable {
        case left, right
    }

    public enum Kind: Sendable, Equatable {
        case arrive, uTurn, roundabout, keep, merge, ramp, sharp, slight, turn, straight
    }

    public struct Cues: Sendable, Equatable {
        public var kind: Kind?
        public var side: Side?
        /// "continue" / "straight": at a roundabout, the exit straight ahead.
        public var continues = false
        /// Roundabout exit number ("take the second exit"), when the text gives one.
        public var exit: Int?
    }

    private static let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
                                   "seventh": 7, "eighth": 8]

    /// Angles in degrees, positive = right. `near` compares ~30 m either side of the
    /// maneuver point; `far` compares the incoming direction with the route a little
    /// further on, which exposes roundabouts and S-bends.
    public struct Geometry: Sendable, Equatable {
        public var near: Double?
        public var far: Double?

        public init(near: Double?, far: Double?) {
            self.near = near
            self.far = far
        }
    }

    static let straightLimit = 12.0
    static let slightLimit = 40.0
    static let turnLimit = 115.0
    static let sharpLimit = 165.0
    /// Near and far angles further apart than this mean the path bends twice
    /// (e.g. an unlabelled roundabout): no single arrow is faithful. Stricter when
    /// the instruction text gives no cue (e.g. a non-English device language).
    static let bendDisagreement = 60.0
    static let bendDisagreementWithoutText = 25.0

    public static func cues(_ instructions: String) -> Cues {
        var text = " " + instructions.lowercased() + " "
        for clause in [" onto ", " toward ", " towards ", " on to "] {
            if let range = text.range(of: clause) { text = String(text[..<range.lowerBound]) + " " }
        }
        let side: Side? = switch (text.contains(" left"), text.contains(" right")) {
        case (true, false): .left
        case (false, true): .right
        default: nil
        }
        let kind: Kind? = if text.contains("u-turn") || text.contains("u turn") || text.contains("make a u") {
            .uTurn
        } else if text.contains("roundabout") || text.contains("rotary") || text.contains("traffic circle") {
            .roundabout
        } else if text.contains("arrive") || text.contains("destination") {
            .arrive
        } else if text.contains("keep ") {
            .keep
        } else if text.contains("merge") {
            .merge
        } else if text.contains(" exit") || text.contains("ramp") {
            .ramp
        } else if text.contains("sharp") {
            .sharp
        } else if text.contains("slight") || text.contains("bear ") {
            .slight
        } else if text.contains("turn") {
            .turn
        } else if text.contains("continue") || text.contains("head ") || text.contains("straight") {
            .straight
        } else {
            nil
        }
        let continues = text.contains("continue") || text.contains("straight")
        var exit: Int?
        if let match = text.firstMatch(of: /(\w+) exit/) {
            let word = String(match.1)
            exit = ordinals[word] ?? word.firstMatch(of: /^(\d)(st|nd|rd|th)$/).flatMap { Int(String($0.1)) }
        }
        return Cues(kind: kind, side: side, continues: continues, exit: exit)
    }

    /// A roundabout from the measured angle between the road in and the road out.
    /// Apple's wording wins when it is explicit: "continue" is straight, and "turn
    /// left/right" is that side (a measured direction on the same side is kept).
    public static func roundabout(_ cues: Cues, angle: Double?, drivingSide: DrivingSide)
        -> (Maneuver, RoundaboutDirection?) {
        let maneuver: Maneuver = drivingSide == .left ? .roundaboutClockwise : .roundaboutCounterClockwise
        var direction = angle.map(roundaboutDirection)
        let leftSide: Set<RoundaboutDirection> = [.sharpLeft, .left, .slightLeft]
        let rightSide: Set<RoundaboutDirection> = [.sharpRight, .right, .slightRight]
        if cues.continues {
            direction = .straight
        } else if cues.side == .left, !(direction.map(leftSide.contains) ?? false) {
            direction = .left
        } else if cues.side == .right, !(direction.map(rightSide.contains) ?? false) {
            direction = .right
        }
        return (maneuver, direction)
    }

    public static func classify(_ cues: Cues, _ geometry: Geometry,
                                drivingSide: DrivingSide) -> (Maneuver, RoundaboutDirection?) {
        if cues.kind == .arrive { return (.arrival, nil) }
        if cues.kind == .roundabout {
            guard let far = geometry.far else { return (.unsupported, nil) }
            return (drivingSide == .left ? .roundaboutClockwise : .roundaboutCounterClockwise, roundaboutDirection(far))
        }
        if cues.kind == .uTurn {
            let side = cues.side ?? (drivingSide == .left ? .right : .left)
            return (side == .left ? .uTurnLeft : .uTurnRight, nil)
        }
        // At a fork both branches can bend the same way; "keep right" / "exit right"
        // names the branch to take, so the text side wins over the road's bend.
        if let side = cues.side, cues.kind == .keep || cues.kind == .ramp {
            switch cues.kind {
            case .keep: return (side == .left ? .keepLeft : .keepRight, nil)
            default: return (side == .left ? .rampLeft : .rampRight, nil)
            }
        }
        guard let near = geometry.near else { return (.unsupported, nil) }
        if let far = geometry.far {
            let sides = (Self.side(near), Self.side(far))
            if let a = sides.0, let b = sides.1, a != b { return (.unsupported, nil) }
            let limit = cues.kind == nil ? bendDisagreementWithoutText : bendDisagreement
            if abs(near - far) > limit { return (.unsupported, nil) }
        }
        let geometrySide = Self.side(near)
        if let textSide = cues.side, let geometrySide, textSide != geometrySide { return (.unsupported, nil) }
        let side = cues.side ?? geometrySide
        let magnitude = abs(near)

        switch cues.kind {
        case .keep:
            return (side.map { $0 == .left ? .keepLeft : .keepRight } ?? .unsupported, nil)
        case .merge:
            return (.merge, nil)
        case .ramp:
            return (side.map { $0 == .left ? .rampLeft : .rampRight } ?? .unsupported, nil)
        case .sharp:
            return (side.map { $0 == .left ? .sharpLeft : .sharpRight } ?? .unsupported, nil)
        case .slight:
            return (side.map { $0 == .left ? .slightLeft : .slightRight } ?? .unsupported, nil)
        case .turn:
            guard let side else { return (.unsupported, nil) }
            if magnitude >= turnLimit { return (side == .left ? .sharpLeft : .sharpRight, nil) }
            return (side == .left ? .turnLeft : .turnRight, nil)
        case .straight:
            return (magnitude < slightLimit ? .straight : .unsupported, nil)
        case .arrive, .roundabout, .uTurn, nil:
            return (byGeometry(near, drivingSide: drivingSide), nil)
        }
    }

    static func byGeometry(_ angle: Double, drivingSide: DrivingSide) -> Maneuver {
        let magnitude = abs(angle)
        let right = angle > 0
        switch magnitude {
        case ..<straightLimit: return .straight
        case ..<slightLimit: return right ? .slightRight : .slightLeft
        case ..<turnLimit: return right ? .turnRight : .turnLeft
        case ..<sharpLimit: return right ? .sharpRight : .sharpLeft
        default: return drivingSide == .left ? .uTurnRight : .uTurnLeft
        }
    }

    static func side(_ angle: Double) -> Side? {
        if angle > straightLimit { return .right }
        if angle < -straightLimit { return .left }
        return nil
    }

    /// Eight 45-degree sectors centred on the compass directions relative to the entry.
    static func roundaboutDirection(_ angle: Double) -> RoundaboutDirection {
        switch angle {
        case -22.5..<22.5: .straight
        case 22.5..<67.5: .slightRight
        case 67.5..<112.5: .right
        case 112.5..<157.5: .sharpRight
        case -67.5 ..< -22.5: .slightLeft
        case -112.5 ..< -67.5: .left
        case -157.5 ..< -112.5: .sharpLeft
        default: .uTurn
        }
    }
}
