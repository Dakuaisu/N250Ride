/// Icon ids the cluster renders from TBT byte 1 (Ride Relay `PrimaryTurns`).
/// Values 66-90 are solid; adding 32 selects the blinking variant.
public enum ClusterIcon {
    public static let wrongWay: UInt8 = 66
    public static let slightLeft: UInt8 = 67
    public static let slightRight: UInt8 = 68
    public static let sharpLeft: UInt8 = 69
    public static let sharpRight: UInt8 = 70
    public static let straight: UInt8 = 71
    public static let destinationReached: UInt8 = 72
    public static let turnLeft: UInt8 = 73
    public static let turnRight: UInt8 = 74
    public static let rampLeft: UInt8 = 75
    public static let rampRight: UInt8 = 76
    public static let roundaboutRight: UInt8 = 78
    public static let uTurnLeft: UInt8 = 79
    public static let uTurnRight: UInt8 = 80
    public static let forkLeft: UInt8 = 81
    public static let forkRight: UInt8 = 82
    public static let ferryTrain: UInt8 = 84
    public static let roundaboutLeft: UInt8 = 85
    public static let merge: UInt8 = 86
    public static let keepRight: UInt8 = 88
    public static let ferry: UInt8 = 89
    public static let keepLeft: UInt8 = 90

    public static let blinkOffset: UInt8 = 32

    public static let solid: Set<UInt8> = [
        wrongWay, slightLeft, slightRight, sharpLeft, sharpRight, straight, destinationReached,
        turnLeft, turnRight, rampLeft, rampRight, roundaboutRight, uTurnLeft, uTurnRight,
        forkLeft, forkRight, ferryTrain, roundaboutLeft, merge, keepRight, ferry, keepLeft,
    ]

    public static func isKnown(_ icon: UInt8) -> Bool {
        solid.contains(icon) || (icon >= blinkOffset && solid.contains(icon - blinkOffset))
    }

    public static func name(_ icon: UInt8) -> String {
        let base = icon >= 98 ? icon - blinkOffset : icon
        let blink = base != icon ? " (blinking)" : ""
        let names: [UInt8: String] = [
            wrongWay: "Wrong way", slightLeft: "Slight left", slightRight: "Slight right",
            sharpLeft: "Sharp left", sharpRight: "Sharp right", straight: "Straight",
            destinationReached: "Destination", turnLeft: "Turn left", turnRight: "Turn right",
            rampLeft: "Ramp left", rampRight: "Ramp right", roundaboutRight: "Roundabout right",
            uTurnLeft: "U-turn left", uTurnRight: "U-turn right", forkLeft: "Fork left",
            forkRight: "Fork right", ferryTrain: "Ferry train", roundaboutLeft: "Roundabout left",
            merge: "Merge", keepRight: "Keep right", ferry: "Ferry", keepLeft: "Keep left",
        ]
        return (names[base] ?? "Icon \(icon)") + blink
    }
}

/// Provider-independent maneuver. Navigation adapters translate SDK values into
/// this; anything they cannot classify is `.unsupported` and is suppressed, never
/// shown as straight.
public enum Maneuver: String, Sendable, Hashable, CaseIterable, Codable {
    case straight
    case turnLeft, turnRight
    case slightLeft, slightRight
    case sharpLeft, sharpRight
    case keepLeft, keepRight
    case forkLeft, forkRight
    case rampLeft, rampRight
    case merge
    case uTurnLeft, uTurnRight
    /// Roundabout circulated clockwise (left-hand traffic, e.g. India).
    case roundaboutClockwise
    case roundaboutCounterClockwise
    case ferry, ferryTrain
    case arrival
    case unsupported
}

/// Where a roundabout exit leaves relative to the entry.
public enum RoundaboutDirection: String, Sendable, Hashable, CaseIterable, Codable {
    case sharpLeft, left, slightLeft, straight, slightRight, right, sharpRight, uTurn
}

/// Which exit value makes the N250 draw its exit arrow in a given direction.
/// The cluster draws the value as an angle on a fixed roundabout picture, entry at
/// the bottom, one-eighth turn per step (owner bench, 2026-11-12):
/// - glyph 85 sweeps clockwise from sharp left (1) over the top to sharp right (7);
/// - glyph 78 sweeps anticlockwise from right (1) over the top to sharp left (6).
/// Directions missing from a table cannot be drawn on that glyph.
public struct RoundaboutCalibration: Sendable, Equatable {
    public var clockwise: [RoundaboutDirection: Int]
    public var counterClockwise: [RoundaboutDirection: Int]

    public init(clockwise: [RoundaboutDirection: Int], counterClockwise: [RoundaboutDirection: Int]) {
        self.clockwise = clockwise
        self.counterClockwise = counterClockwise
    }

    public static let n250 = RoundaboutCalibration(
        clockwise: [.sharpLeft: 1, .left: 2, .slightLeft: 3, .straight: 4, .slightRight: 5, .right: 6, .sharpRight: 7],
        counterClockwise: [.right: 1, .slightRight: 2, .straight: 3, .slightLeft: 4, .left: 5, .sharpLeft: 6]
    )

    func value(for maneuver: Maneuver, direction: RoundaboutDirection) -> Int? {
        switch maneuver {
        case .roundaboutClockwise: clockwise[direction]
        case .roundaboutCounterClockwise: counterClockwise[direction]
        default: nil
        }
    }
}

public enum ManeuverMapper {
    /// Upstream blinks the icon when the maneuver is under 100 m away, except arrival.
    public static let blinkThresholdMetres = 100

    /// Cluster icon for a maneuver, or nil when the dashboard has no faithful glyph.
    /// Clockwise roundabouts use glyph 85 and anticlockwise ones glyph 78: the bench
    /// test showed 85 sweeping clockwise and 78 anticlockwise, whatever upstream named them.
    public static func icon(for maneuver: Maneuver, stepMetres: Int) -> UInt8? {
        let base: UInt8
        switch maneuver {
        case .straight: base = ClusterIcon.straight
        case .turnLeft: base = ClusterIcon.turnLeft
        case .turnRight: base = ClusterIcon.turnRight
        case .slightLeft: base = ClusterIcon.slightLeft
        case .slightRight: base = ClusterIcon.slightRight
        case .sharpLeft: base = ClusterIcon.sharpLeft
        case .sharpRight: base = ClusterIcon.sharpRight
        case .keepLeft: base = ClusterIcon.keepLeft
        case .keepRight: base = ClusterIcon.keepRight
        case .forkLeft: base = ClusterIcon.forkLeft
        case .forkRight: base = ClusterIcon.forkRight
        case .rampLeft: base = ClusterIcon.rampLeft
        case .rampRight: base = ClusterIcon.rampRight
        case .merge: base = ClusterIcon.merge
        case .uTurnLeft: base = ClusterIcon.uTurnLeft
        case .uTurnRight: base = ClusterIcon.uTurnRight
        case .roundaboutClockwise: base = ClusterIcon.roundaboutLeft
        case .roundaboutCounterClockwise: base = ClusterIcon.roundaboutRight
        case .ferry: base = ClusterIcon.ferry
        case .ferryTrain: base = ClusterIcon.ferryTrain
        case .arrival: return ClusterIcon.destinationReached
        case .unsupported: return nil
        }
        if (0..<blinkThresholdMetres).contains(stepMetres) {
            return base + ClusterIcon.blinkOffset
        }
        return base
    }

    /// Value for the byte-7 exit nibble: 0 for non-roundabouts. For roundabouts, the
    /// value that draws the exit in its real direction, or nil when the direction is
    /// unknown or not drawable on that glyph (suppress; the exit count is never used,
    /// because the cluster draws it as an angle and it would point the wrong way).
    public static func roundaboutExit(for maneuver: Maneuver, direction: RoundaboutDirection?,
                                      calibration: RoundaboutCalibration = .n250) -> Int? {
        guard maneuver == .roundaboutClockwise || maneuver == .roundaboutCounterClockwise else { return 0 }
        guard let direction, let value = calibration.value(for: maneuver, direction: direction),
              (1...TbtFrame.maxRoundaboutExit).contains(value) else { return nil }
        return value
    }
}
