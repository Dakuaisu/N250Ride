import Foundation
import Testing
@testable import RideCore

struct GoldenVectors: Decodable {
    struct Tbt: Decodable {
        var name: String
        var type: UInt8
        var icon: UInt8
        var am: Bool
        var stepMetres: Int
        var totalMetres: Int
        var etaHour: Int
        var etaMinute: Int
        var roundaboutExit: Int
        var text: String?
        var hex: String
    }

    struct General: Decodable {
        var name: String
        var profile: String
        var volume: Int
        var battery: Int
        var heartbeat: UInt8
        var model: String
        var hex: String
    }

    var upstreamCommit: String
    var tbt: [Tbt]
    var general: [General]

    static let shared: GoldenVectors = {
        let url = Bundle.module.url(forResource: "golden-vectors", withExtension: "json")!
        return try! JSONDecoder().decode(GoldenVectors.self, from: Data(contentsOf: url))
    }()
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
}

func bytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

extension GoldenVectors.Tbt {
    var fields: TbtFields {
        TbtFields(frameType: TbtFields.FrameType(rawValue: type)!, icon: icon, isAM: am,
                  stepMetres: stepMetres, totalMetres: totalMetres, etaHour: etaHour,
                  etaMinute: etaMinute, roundaboutExit: roundaboutExit, text: text)
    }
}

@Suite("Golden vectors from pinned Ride Relay")
struct GoldenVectorTests {
    @Test func vectorsArePinned() {
        #expect(GoldenVectors.shared.upstreamCommit == "530632e4ae116645a16710a15f73e492159a7699")
        #expect(GoldenVectors.shared.tbt.count > 80)
        #expect(GoldenVectors.shared.general.count > 20)
    }

    @Test(arguments: GoldenVectors.shared.tbt.map(\.name))
    func tbtFrameMatchesOracle(name: String) throws {
        let vector = try #require(GoldenVectors.shared.tbt.first { $0.name == name })
        let frame = name == "stop" ? TbtFrame.stop() : try TbtFrame.encode(vector.fields)
        #expect(hex(frame) == vector.hex)
        #expect(TbtFrame.hasValidChecksum(frame))
    }

    @Test(arguments: GoldenVectors.shared.general.map(\.name))
    func generalPacketMatchesOracle(name: String) throws {
        let vector = try #require(GoldenVectors.shared.general.first { $0.name == name })
        let profile = try #require(vector.profile == "legacy55" ? GeneralStatusProfile.legacy55 : .v2_89)
        let packet = GeneralStatusEncoder.encode(profile, GeneralStatusFields(
            volume: vector.volume, batteryBars: vector.battery, heartbeat: vector.heartbeat, phoneModel: vector.model))
        #expect(hex(packet) == vector.hex)
    }

    @Test func stopFrameIsNotAllZeros() {
        let stop = TbtFrame.stop()
        #expect(stop.count == 48)
        #expect(stop[0] == 0x10)
        #expect(stop[12] == 0x05)
        #expect(stop[47] == 0x15)
        #expect(stop.enumerated().allSatisfy { [0, 12, 47].contains($0.offset) || $0.element == 0 })
    }

    @Test func startFrameMatchesOfficialStart() throws {
        let vector = try #require(GoldenVectors.shared.tbt.first { $0.name == "start" })
        #expect(hex(TbtFrame.start()) == vector.hex)
    }

    @Test func corruptedFixtureIsDetected() throws {
        let vector = try #require(GoldenVectors.shared.tbt.first { $0.name == "step-1010" })
        var corrupted = bytes(vector.hex)
        corrupted[4] ^= 0x01
        #expect(hex(try TbtFrame.encode(vector.fields)) != hex(corrupted))
        #expect(!TbtFrame.hasValidChecksum(corrupted))
    }

    @Test func distanceKeepsUpstreamFloatingPointTruncation() {
        #expect(TbtFrame.distanceWords(999) == .init(unit: 1, integer: 999, hundredths: 0))
        #expect(TbtFrame.distanceWords(1_000) == .init(unit: 0, integer: 1, hundredths: 0))
        #expect(TbtFrame.distanceWords(1_010) == .init(unit: 0, integer: 1, hundredths: 1))
        #expect(TbtFrame.distanceWords(1_999) == .init(unit: 0, integer: 1, hundredths: 99))
        #expect(TbtFrame.distanceWords(4_350) == .init(unit: 0, integer: 4, hundredths: 34))
    }
}

@Suite("TBT encoder validation")
struct TbtValidationTests {
    private func fields(icon: UInt8 = ClusterIcon.turnLeft, step: Int = 250, total: Int = 4_000,
                        hour: Int = 9, minute: Int = 30, exit: Int = 0) -> TbtFields {
        TbtFields(frameType: .navigation, icon: icon, isAM: true, stepMetres: step, totalMetres: total,
                  etaHour: hour, etaMinute: minute, roundaboutExit: exit)
    }

    @Test func rejectsValuesTheClusterCannotShow() {
        #expect(throws: TbtEncodingError.distanceOutOfRange(-1)) { try TbtFrame.encode(fields(step: -1)) }
        #expect(throws: TbtEncodingError.distanceOutOfRange(65_536_000)) { try TbtFrame.encode(fields(total: 65_536_000)) }
        #expect(throws: TbtEncodingError.etaHourOutOfRange(13)) { try TbtFrame.encode(fields(hour: 13)) }
        #expect(throws: TbtEncodingError.etaMinuteOutOfRange(60)) { try TbtFrame.encode(fields(minute: 60)) }
        #expect(throws: TbtEncodingError.roundaboutExitOutOfRange(8)) { try TbtFrame.encode(fields(exit: 8)) }
        #expect(throws: TbtEncodingError.unknownIcon(77)) { try TbtFrame.encode(fields(icon: 77)) }
        #expect(throws: TbtEncodingError.unknownIcon(0)) { try TbtFrame.encode(fields(icon: 0)) }
    }

    @Test func textIsBoundedAscii() throws {
        var f = fields()
        f.text = String(repeating: "é", count: 50) + "Road"
        let frame = try TbtFrame.encode(f)
        #expect(frame[14] == 4)
        #expect(Array(frame[15..<19]) == Array("Road".utf8))
        f.text = String(repeating: "A", count: 40)
        #expect(try TbtFrame.encode(f)[14] == 31)
    }

    @Test func summaryDecodesFrame() throws {
        var f = fields(icon: ClusterIcon.roundaboutRight, step: 1_250, exit: 3)
        f.text = "MG Road"
        f.isAM = false
        let summary = try #require(TbtFrameSummary(frame: try TbtFrame.encode(f)))
        #expect(summary.icon == ClusterIcon.roundaboutRight)
        #expect(summary.stepText == "1.25 km")
        #expect(summary.totalText == "4.00 km")
        #expect(summary.roundaboutExit == 3)
        #expect(summary.isPM)
        #expect(summary.text == "MG Road")
        #expect(summary.checksumValid)
    }
}

@Suite("Maneuver mapping")
struct ManeuverMapperTests {
    @Test(arguments: Maneuver.allCases.filter { $0 != .unsupported })
    func everySupportedManeuverHasAKnownIcon(maneuver: Maneuver) throws {
        let far = try #require(ManeuverMapper.icon(for: maneuver, stepMetres: 500))
        let near = try #require(ManeuverMapper.icon(for: maneuver, stepMetres: 50))
        #expect(ClusterIcon.isKnown(far))
        #expect(ClusterIcon.isKnown(near))
    }

    @Test func unsupportedIsSuppressedNotStraight() {
        #expect(ManeuverMapper.icon(for: .unsupported, stepMetres: 500) == nil)
        #expect(ManeuverMapper.icon(for: .unsupported, stepMetres: 10) == nil)
    }

    @Test func blinksBelowOneHundredMetres() {
        #expect(ManeuverMapper.icon(for: .turnLeft, stepMetres: 100) == ClusterIcon.turnLeft)
        #expect(ManeuverMapper.icon(for: .turnLeft, stepMetres: 99) == ClusterIcon.turnLeft + 32)
        #expect(ManeuverMapper.icon(for: .turnLeft, stepMetres: 0) == ClusterIcon.turnLeft + 32)
        #expect(ManeuverMapper.icon(for: .arrival, stepMetres: 10) == ClusterIcon.destinationReached)
    }

    @Test func directionsAreNotSwapped() {
        #expect(ManeuverMapper.icon(for: .turnLeft, stepMetres: 500) == 73)
        #expect(ManeuverMapper.icon(for: .turnRight, stepMetres: 500) == 74)
        #expect(ManeuverMapper.icon(for: .uTurnLeft, stepMetres: 500) == 79)
        #expect(ManeuverMapper.icon(for: .uTurnRight, stepMetres: 500) == 80)
        #expect(ManeuverMapper.icon(for: .keepLeft, stepMetres: 500) == 90)
        #expect(ManeuverMapper.icon(for: .keepRight, stepMetres: 500) == 88)
    }

    @Test func roundaboutValueComesFromBenchCalibratedAngle() {
        #expect(ManeuverMapper.icon(for: .roundaboutClockwise, stepMetres: 500) == ClusterIcon.roundaboutLeft)
        #expect(ManeuverMapper.icon(for: .roundaboutCounterClockwise, stepMetres: 500) == ClusterIcon.roundaboutRight)
        let clockwise: [(RoundaboutDirection, Int)] = [(.sharpLeft, 1), (.left, 2), (.slightLeft, 3), (.straight, 4),
                                                       (.slightRight, 5), (.right, 6), (.sharpRight, 7)]
        for (direction, value) in clockwise {
            #expect(ManeuverMapper.roundaboutExit(for: .roundaboutClockwise, direction: direction) == value, "\(direction)")
        }
        let anticlockwise: [(RoundaboutDirection, Int)] = [(.right, 1), (.slightRight, 2), (.straight, 3),
                                                           (.slightLeft, 4), (.left, 5), (.sharpLeft, 6)]
        for (direction, value) in anticlockwise {
            #expect(ManeuverMapper.roundaboutExit(for: .roundaboutCounterClockwise, direction: direction) == value, "\(direction)")
        }
    }

    @Test func undrawableOrUnknownRoundaboutDirectionIsSuppressed() {
        #expect(ManeuverMapper.roundaboutExit(for: .roundaboutClockwise, direction: .uTurn) == nil)
        #expect(ManeuverMapper.roundaboutExit(for: .roundaboutCounterClockwise, direction: .sharpRight) == nil)
        #expect(ManeuverMapper.roundaboutExit(for: .roundaboutClockwise, direction: nil) == nil)
        #expect(ManeuverMapper.roundaboutExit(for: .turnLeft, direction: nil) == 0)
    }
}

@Suite("General status")
struct GeneralStatusTests {
    @Test func heartbeatWraps() {
        var counter = HeartbeatCounter()
        #expect(counter.next() == 1)
        for _ in 0..<253 { _ = counter.next() }
        #expect(counter.next() == 255)
        #expect(counter.next() == 0)
        #expect(counter.next() == 1)
    }

    @Test func modelIsCleanedAndBounded() {
        let long = String(repeating: "é", count: 20)
        let packet = GeneralStatusEncoder.encode(.v2_89, GeneralStatusFields(heartbeat: 1, phoneModel: long))
        #expect(packet[55] == 32)
        let tabbed = GeneralStatusEncoder.encode(.v2_89, GeneralStatusFields(heartbeat: 1, phoneModel: "\tiPhone\u{200B}\n"))
        #expect(Array(tabbed[56..<62]) == Array("iPhone".utf8))
        #expect(tabbed[55] == 6)
    }

    @Test func batteryBarsFollowOfficialScale() {
        #expect(GeneralStatusFields.batteryBars(forLevel: 0.1) == 0)
        #expect(GeneralStatusFields.batteryBars(forLevel: 0.5) == 2)
        #expect(GeneralStatusFields.batteryBars(forLevel: 1.0) == 4)
    }
}
