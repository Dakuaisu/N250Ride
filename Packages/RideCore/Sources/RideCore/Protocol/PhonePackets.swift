import Foundation

/// Phone-event packets from Ride Relay's protocol notes (docs/protocol/provenance.md),
/// used only by the Bluetooth console's bench presets. Not sent during navigation.
public enum PhonePackets {
    public static let missedCallCharacteristic = "0310676E-6972-6565-6E69-676E4543544F"
    public static let alertCharacteristic = "0410676E-6972-6565-6E69-676E4543544F"

    public enum AlertKind: UInt8, Sendable, CaseIterable {
        case sms = 1
        case whatsApp = 2
    }

    /// 63 bytes: [0]=1, [1]=name length, [2..33] name, [34]=number length,
    /// [35..52] number, [53..56] epoch seconds big-endian, rest zero. No checksum.
    public static func missedCall(name: String, number: String, epochSeconds: UInt32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 63)
        b[0] = 1
        let nameBytes = GeneralStatusEncoder.utf8Prefix(GeneralStatusEncoder.cleaned(name), maxBytes: 32)
        let numberBytes = GeneralStatusEncoder.utf8Prefix(GeneralStatusEncoder.cleaned(number), maxBytes: 18)
        let showName = !nameBytes.isEmpty && name != number
        b[1] = showName ? UInt8(nameBytes.count) : 0
        if showName { b.replaceSubrange(2..<(2 + nameBytes.count), with: nameBytes) }
        b[34] = UInt8(numberBytes.count)
        b.replaceSubrange(35..<(35 + numberBytes.count), with: numberBytes)
        putBigEndian(epochSeconds, into: &b, at: 53)
        return b
    }

    /// 44 bytes: [0]=kind, [1]=sender length, [2..33] sender, [34..37] epoch BE. No checksum.
    public static func alert(_ kind: AlertKind, sender: String, epochSeconds: UInt32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 44)
        b[0] = kind.rawValue
        let senderBytes = GeneralStatusEncoder.utf8Prefix(GeneralStatusEncoder.cleaned(sender), maxBytes: 32)
        b[1] = UInt8(senderBytes.count)
        b.replaceSubrange(2..<(2 + senderBytes.count), with: senderBytes)
        putBigEndian(epochSeconds, into: &b, at: 34)
        return b
    }

    private static func putBigEndian(_ value: UInt32, into b: inout [UInt8], at offset: Int) {
        b[offset] = UInt8(value >> 24)
        b[offset + 1] = UInt8((value >> 16) & 0xFF)
        b[offset + 2] = UInt8((value >> 8) & 0xFF)
        b[offset + 3] = UInt8(value & 0xFF)
    }
}

/// Call state nibble of the status packet (upstream `enums.CallState`).
public enum ClusterCallState: Int, Sendable, CaseIterable {
    case none = 0, incoming = 1, outgoing = 2, active = 3, ended = 4

    var showsCaller: Bool { self == .incoming || self == .outgoing || self == .active }
}
