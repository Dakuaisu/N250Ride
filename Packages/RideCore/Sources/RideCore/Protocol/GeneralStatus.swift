/// General status packet written to the cluster's status characteristic.
///
/// Two layouts exist upstream and the cluster firmware accepts one of them; which
/// one the N250 takes must be observed on the bench, never inferred from the model
/// name. N250Ride mirrors no calls, SMS or media, so every phone field is the
/// neutral "no call" value Ride Relay sends when idle.
public enum GeneralStatusProfile: String, Sendable, Codable, CaseIterable {
    /// `utils.CallFrame.phoneStatusNew`: 55 bytes, no checksum.
    case legacy55
    /// `NewGeneralPacketV2.build`: 89 bytes, checksum at byte 88.
    case v2_89

    public var length: Int {
        switch self {
        case .legacy55: 55
        case .v2_89: 89
        }
    }
}

public struct GeneralStatusFields: Sendable, Equatable {
    /// Media volume nibble, 0...15.
    public var volume: Int
    /// Phone battery in five bars, 0...4 (v2 clamps to 3 on the wire).
    public var batteryBars: Int
    /// Network bars 0...7. iOS gives apps no signal strength, so the default is
    /// upstream's fixed placeholder (4).
    public var signal: Int
    public var heartbeat: UInt8
    public var phoneModel: String
    /// Bench presets only; navigation always sends no call.
    public var callState: ClusterCallState
    public var callerName: String

    public init(volume: Int = 5, batteryBars: Int = 3, signal: Int = 4, heartbeat: UInt8, phoneModel: String = "iPhone",
                callState: ClusterCallState = .none, callerName: String = "") {
        self.volume = volume
        self.batteryBars = batteryBars
        self.signal = signal
        self.heartbeat = heartbeat
        self.phoneModel = phoneModel
        self.callState = callState
        self.callerName = callerName
    }

    /// Five bars as the official app scales battery percentage.
    public static func batteryBars(forLevel level: Double) -> Int {
        let pct = level * 100
        switch pct {
        case ..<20: return 0
        case ..<40: return 1
        case ..<60: return 2
        case ..<80: return 3
        default: return 4
        }
    }
}

public enum GeneralStatusEncoder {
    private static let modelMaxBytes = 32

    public static func encode(_ profile: GeneralStatusProfile, _ fields: GeneralStatusFields) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: profile.length)
        b[0] = UInt8(fields.volume & 0x0F) | 0xC0
        b[2] = UInt8(fields.signal & 0x07)
        switch profile {
        case .legacy55:
            b[1] = UInt8((fields.batteryBars & 0x07) << 3) | UInt8(fields.callState.rawValue & 0x0F)
            b[3] = fields.callState == .active ? 1 : 0
            // [4] is "call accept ack" = 1 whenever no call is active.
            b[4] = fields.callState == .active ? 0 : 1
            putCaller(fields, into: &b, flag: 18, length: 20, offset: 21, max: 30)
            b[53] = fields.heartbeat
        case .v2_89:
            b[1] = UInt8((min(fields.batteryBars & 0xFF, 3) & 3) << 4) | UInt8(fields.callState.rawValue & 0x0F)
            putCaller(fields, into: &b, flag: 18, length: 19, offset: 20, max: 32)
            b[54] = fields.heartbeat
            let model = utf8Prefix(cleaned(fields.phoneModel), maxBytes: modelMaxBytes)
            b[55] = UInt8(model.count)
            b.replaceSubrange(56..<(56 + model.count), with: model)
            b[88] = b.prefix(88).reduce(UInt8(0)) { $0 &+ $1 }
        }
        return b
    }

    private static func putCaller(_ fields: GeneralStatusFields, into b: inout [UInt8],
                                  flag: Int, length: Int, offset: Int, max: Int) {
        guard fields.callState.showsCaller else { return }
        let name = utf8Prefix(cleaned(fields.callerName), maxBytes: max)
        guard !name.isEmpty else { return }
        b[flag] = 1
        b[length] = UInt8(name.count)
        b.replaceSubrange(offset..<(offset + name.count), with: name)
    }

    /// Bench testing: overwrite raw bytes after encoding. The v2 checksum is
    /// recomputed unless an override targets the checksum byte itself.
    /// Offsets outside the packet are ignored.
    public static func applying(_ overrides: [Int: UInt8], to packet: [UInt8],
                                profile: GeneralStatusProfile) -> [UInt8] {
        var b = packet
        for (offset, value) in overrides where b.indices.contains(offset) { b[offset] = value }
        if profile == .v2_89, overrides[88] == nil {
            b[88] = b.prefix(88).reduce(UInt8(0)) { $0 &+ $1 }
        }
        return b
    }

    /// Parses "54=7, 3=0x1F" style overrides; nil when any entry is malformed.
    public static func parseOverrides(_ text: String) -> [Int: UInt8]? {
        var result: [Int: UInt8] = [:]
        for entry in text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            let parts = entry.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let offset = Int(parts[0]), offset >= 0,
                  let value = byte(parts[1]) else { return nil }
            result[offset] = value
        }
        return result
    }

    private static func byte(_ s: String) -> UInt8? {
        let lower = s.lowercased()
        if lower.hasPrefix("0x") { return UInt8(lower.dropFirst(2), radix: 16) }
        return UInt8(lower)
    }

    /// Upstream `Pack.clean`: newlines/tabs to spaces, drop control/format/unassigned.
    static func cleaned(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                out.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .unassigned: continue
            default: out.append(scalar)
            }
        }
        return String(out).trimmingCharacters(in: " ")
    }

    /// UTF-8 bytes limited to `maxBytes` without splitting a character.
    static func utf8Prefix(_ s: String, maxBytes: Int) -> [UInt8] {
        let all = Array(s.utf8)
        guard all.count > maxBytes else { return all }
        var end = maxBytes
        while end > 0, all[end] & 0xC0 == 0x80 { end -= 1 }
        return Array(all[..<end])
    }
}

/// Wrapping per-link heartbeat, starting at 1 like upstream's pre-increment.
public struct HeartbeatCounter: Sendable, Equatable {
    public private(set) var value: UInt8 = 0

    public init() {}

    public mutating func next() -> UInt8 {
        value &+= 1
        return value
    }
}

private extension String {
    func trimmingCharacters(in character: Character) -> String {
        var s = Substring(self)
        while s.first == character { s.removeFirst() }
        while s.last == character { s.removeLast() }
        return String(s)
    }
}
