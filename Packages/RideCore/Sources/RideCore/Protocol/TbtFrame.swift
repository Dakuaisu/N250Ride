/// The 48-byte turn-by-turn frame written to the cluster's navigation characteristic.
///
/// Layout and arithmetic follow Ride Relay `TbtFrame.java` at the pinned revision
/// (see docs/protocol/provenance.md). Behaviour is defined by the golden vectors,
/// not by the upstream comments: the "16.16" distance actually stores decimal
/// hundredths in the low word, truncated through binary floating point exactly as
/// Java does (4,350 m encodes as 4.34 km).
///
/// ```
/// off  size  field
///  0   1     frame type (bit0) | step unit (bit4, 1 = metres) | PM (bit7)
///  1   1     icon id
///  2-5 4     step distance, LE (integer << 16 | hundredths)
///  6   1     ETA minute
///  7   1     ETA hour (1-12) | roundabout exit << 4
///  8-11 4    total distance, LE
/// 12   1     total unit (bit0) | GPS active (bits 2-3 = 1)
/// 13   1     take-me-home ack (always 0)
/// 14   1     text length (<= 31)
/// 15-45 31   text, ASCII [0-9A-Za-z.] and space
/// 46   1     unused
/// 47   1     checksum = sum(0...46) & 0xFF
/// ```
public struct TbtFields: Sendable, Equatable {
    public enum FrameType: UInt8, Sendable {
        case stop = 0
        case navigation = 1
    }

    public var frameType: FrameType
    public var icon: UInt8
    public var isAM: Bool
    public var stepMetres: Int
    public var totalMetres: Int
    public var etaHour: Int
    public var etaMinute: Int
    public var roundaboutExit: Int
    public var text: String?

    public init(
        frameType: FrameType,
        icon: UInt8,
        isAM: Bool,
        stepMetres: Int,
        totalMetres: Int,
        etaHour: Int,
        etaMinute: Int,
        roundaboutExit: Int = 0,
        text: String? = nil
    ) {
        self.frameType = frameType
        self.icon = icon
        self.isAM = isAM
        self.stepMetres = stepMetres
        self.totalMetres = totalMetres
        self.etaHour = etaHour
        self.etaMinute = etaMinute
        self.roundaboutExit = roundaboutExit
        self.text = text
    }
}

public enum TbtEncodingError: Error, Equatable, Sendable {
    case unknownIcon(UInt8)
    case distanceOutOfRange(Int)
    case etaHourOutOfRange(Int)
    case etaMinuteOutOfRange(Int)
    case roundaboutExitOutOfRange(Int)
}

public enum TbtFrame {
    public static let length = 48
    public static let maxTextBytes = 31
    /// Largest distance whose kilometre integer still fits the 16-bit word.
    public static let maxDistanceMetres = 65_535_999
    public static let maxRoundaboutExit = 7

    private static let gpsActive: UInt8 = 1

    /// Encodes a frame, rejecting values the cluster cannot represent instead of
    /// silently wrapping them as upstream would.
    public static func encode(_ fields: TbtFields) throws(TbtEncodingError) -> [UInt8] {
        if fields.frameType == .navigation, !ClusterIcon.isKnown(fields.icon) {
            throw .unknownIcon(fields.icon)
        }
        for distance in [fields.stepMetres, fields.totalMetres] where !(0...maxDistanceMetres).contains(distance) {
            throw .distanceOutOfRange(distance)
        }
        guard (0...12).contains(fields.etaHour) else { throw .etaHourOutOfRange(fields.etaHour) }
        guard (0...59).contains(fields.etaMinute) else { throw .etaMinuteOutOfRange(fields.etaMinute) }
        guard (0...maxRoundaboutExit).contains(fields.roundaboutExit) else {
            throw .roundaboutExitOutOfRange(fields.roundaboutExit)
        }

        let step = distanceWords(fields.stepMetres)
        let total = distanceWords(fields.totalMetres)
        let text = sanitizedText(fields.text)

        var b = [UInt8](repeating: 0, count: length)
        b[0] = fields.frameType.rawValue | (step.unit << 4) | ((fields.isAM ? 0 : 1) << 7)
        b[1] = fields.icon
        putDistance(step, into: &b, at: 2)
        b[6] = UInt8(fields.etaMinute)
        b[7] = UInt8(fields.etaHour) | (UInt8(fields.roundaboutExit) << 4)
        putDistance(total, into: &b, at: 8)
        b[12] = total.unit | (gpsActive << 2)
        b[13] = 0
        b[14] = UInt8(text.count)
        b.replaceSubrange(15..<(15 + text.count), with: text)
        b[47] = checksum(b)
        return b
    }

    /// Navigation-start frame used by the official app: straight arrow, everything else zero.
    public static func start() -> [UInt8] {
        // Constant inputs are always valid.
        try! encode(TbtFields(frameType: .navigation, icon: ClusterIcon.straight, isAM: true,
                              stepMetres: 0, totalMetres: 0, etaHour: 0, etaMinute: 0))
    }

    /// Navigation-stop frame. Not all zeros: the shared builder keeps the metre
    /// unit bits, the GPS bit and the checksum (`10 … 05 … 15`).
    public static func stop() -> [UInt8] {
        try! encode(TbtFields(frameType: .stop, icon: 0, isAM: true,
                              stepMetres: 0, totalMetres: 0, etaHour: 0, etaMinute: 0))
    }

    /// Bench probe only: sets the raw roundabout nibble (byte 7, bits 4-7) to any
    /// 0-15 value and re-checksums, to discover what the N250 does with it.
    public static func withRoundaboutNibble(_ frame: [UInt8], _ nibble: Int) -> [UInt8]? {
        guard frame.count == length, (0...15).contains(nibble) else { return nil }
        var b = frame
        b[7] = (b[7] & 0x0F) | UInt8(nibble << 4)
        b[47] = checksum(b)
        return b
    }

    public static func checksum(_ frame: [UInt8]) -> UInt8 {
        frame.prefix(47).reduce(UInt8(0)) { $0 &+ $1 }
    }

    public static func hasValidChecksum(_ frame: [UInt8]) -> Bool {
        frame.count == length && frame[47] == checksum(frame)
    }

    struct DistanceWords: Equatable {
        var unit: UInt8
        var integer: UInt16
        var hundredths: UInt16
    }

    /// Mirrors `TbtFrame.formatDistance`: metres below 1 km, else km with
    /// hundredths truncated through Double arithmetic.
    static func distanceWords(_ metres: Int) -> DistanceWords {
        let d = Double(metres)
        if d < 1000.0 {
            return DistanceWords(unit: 1, integer: UInt16(metres), hundredths: 0)
        }
        let v = d / 1000.0
        let integer = Int(v)
        let hundredths = Int((v - Double(integer)) * 100.0)
        return DistanceWords(unit: 0, integer: UInt16(integer), hundredths: UInt16(hundredths))
    }

    private static func putDistance(_ w: DistanceWords, into b: inout [UInt8], at offset: Int) {
        b[offset] = UInt8(w.hundredths & 0xFF)
        b[offset + 1] = UInt8(w.hundredths >> 8)
        b[offset + 2] = UInt8(w.integer & 0xFF)
        b[offset + 3] = UInt8(w.integer >> 8)
    }

    /// Mirrors upstream `replaceAll("[^0-9a-zA-Z.]", " ").trim()` (one space per
    /// code point) and its 31-byte cut.
    static func sanitizedText(_ text: String?) -> [UInt8] {
        guard let text else { return [] }
        var bytes: [UInt8] = text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E: UInt8(scalar.value)
            default: 0x20
            }
        }
        while bytes.last == 0x20 { bytes.removeLast() }
        let leading = bytes.prefix { $0 == 0x20 }.count
        bytes.removeFirst(leading)
        return Array(bytes.prefix(maxTextBytes))
    }
}

/// Decoded view of a TBT frame, for the diagnostic packet preview and tests.
public struct TbtFrameSummary: Sendable, Equatable {
    public var frameType: UInt8
    public var icon: UInt8
    public var isPM: Bool
    public var stepText: String
    public var totalText: String
    public var etaHour: Int
    public var etaMinute: Int
    public var roundaboutExit: Int
    public var text: String
    public var checksumValid: Bool

    public init?(frame: [UInt8]) {
        guard frame.count == TbtFrame.length else { return nil }
        frameType = frame[0] & 0x01
        icon = frame[1]
        isPM = frame[0] & 0x80 != 0
        stepText = Self.distanceText(metresUnit: frame[0] & 0x10 != 0, bytes: frame[2...5])
        totalText = Self.distanceText(metresUnit: frame[12] & 0x01 != 0, bytes: frame[8...11])
        etaHour = Int(frame[7] & 0x0F)
        etaMinute = Int(frame[6])
        roundaboutExit = Int(frame[7] >> 4)
        let count = min(Int(frame[14]), TbtFrame.maxTextBytes)
        text = String(decoding: frame[15..<(15 + count)], as: UTF8.self)
        checksumValid = TbtFrame.hasValidChecksum(frame)
    }

    private static func distanceText(metresUnit: Bool, bytes: ArraySlice<UInt8>) -> String {
        let b = Array(bytes)
        let hundredths = Int(b[0]) | Int(b[1]) << 8
        let integer = Int(b[2]) | Int(b[3]) << 8
        if metresUnit { return "\(integer) m" }
        let padded = hundredths < 10 ? "0\(hundredths)" : "\(hundredths)"
        return "\(integer).\(padded) km"
    }
}
