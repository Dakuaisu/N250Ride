import Foundation
import Testing
@testable import RideCore

@Suite("Bench probes and runtime status profile")
struct DiagnosticProbeTests {
    let clock = ManualClock()
    let transport = FakeTransport()
    let withoutResponse = ClusterLinkInfo(navigationWriteMode: .withoutResponse, statusWriteMode: .withoutResponse,
                                          maximumWriteLength: 182)

    func ready(_ configuration: SessionConfiguration = SessionConfiguration()) -> SessionCoordinator {
        let c = SessionCoordinator(clock: clock, configuration: configuration)
        c.linkReady(ClusterWritePump(transport: transport, clock: clock, link: withoutResponse))
        return c
    }

    func roundabout(nibble: Int) throws -> [UInt8] {
        let base = try TbtFrame.encode(TbtFields(frameType: .navigation, icon: ClusterIcon.roundaboutRight, isAM: true,
                                                 stepMetres: 300, totalMetres: 4_200, etaHour: 9, etaMinute: 30))
        return try #require(TbtFrame.withRoundaboutNibble(base, nibble))
    }

    @Test func nibbleHelperKeepsHourAndChecksum() throws {
        let frame = try roundabout(nibble: 13)
        #expect(frame[7] == 0xD9)
        #expect(TbtFrame.hasValidChecksum(frame))
        #expect(TbtFrame.withRoundaboutNibble(frame, 16) == nil)
    }

    @Test func probeIsHeldResentThenCleared() throws {
        let c = ready()
        let frame = try roundabout(nibble: 3)
        #expect(c.showDiagnosticFrame(frame))
        #expect(transport.navigationWrites == [TbtFrame.stop(), frame])
        clock.advance(by: .milliseconds(800))
        c.tick()
        #expect(transport.navigationWrites.last == frame)
        clock.advance(by: .seconds(5))
        c.tick()
        #expect(transport.navigationWrites.last == TbtFrame.stop())
        #expect(!c.isShowingDiagnosticFrame)
    }

    @Test func probeRefusedDuringNavigationAndCancelledByIt() throws {
        let c = ready()
        let frame = try roundabout(nibble: 1)
        c.beginSession(SessionID())
        #expect(!c.showDiagnosticFrame(frame))
        c.endSession()
        #expect(c.showDiagnosticFrame(frame))
        c.beginSession(SessionID())
        #expect(!c.isShowingDiagnosticFrame)
        #expect(transport.navigationWrites.last == TbtFrame.stop())
    }

    @Test func manualClearEndsProbe() throws {
        let c = ready()
        c.showDiagnosticFrame(try roundabout(nibble: 2))
        c.clearDiagnosticFrame()
        #expect(transport.navigationWrites.last == TbtFrame.stop())
        var corrupted = try roundabout(nibble: 2)
        corrupted[47] &+= 1
        #expect(!c.showDiagnosticFrame(corrupted))
    }

    func roundaboutSnapshot(_ c: SessionCoordinator, _ maneuver: Maneuver,
                            direction: RoundaboutDirection?) -> NavigationSnapshot {
        NavigationSnapshot(
            session: c.session!, generation: c.generation, observedAt: clock.now, state: .active,
            step: GuidanceStep(maneuver: maneuver, roundaboutExit: 3, roundaboutDirection: direction,
                               distanceMetres: 300),
            remainingMetres: 4_000, remainingSeconds: 600)
    }

    @Test func roundaboutPointsTheRealWayNotTheExitCount() {
        let c = ready(SessionConfiguration(timeZone: TimeZone(identifier: "UTC")!))
        c.beginSession(SessionID())
        c.receive(roundaboutSnapshot(c, .roundaboutClockwise, direction: .straight))
        let summary = TbtFrameSummary(frame: transport.navigationWrites.last!)
        #expect(summary?.icon == ClusterIcon.roundaboutLeft && summary?.roundaboutExit == 4)
        clock.advance(by: .milliseconds(100))
        c.receive(roundaboutSnapshot(c, .roundaboutCounterClockwise, direction: .left))
        let ccw = TbtFrameSummary(frame: transport.navigationWrites.last!)
        #expect(ccw?.icon == ClusterIcon.roundaboutRight && ccw?.roundaboutExit == 5)
    }

    @Test(arguments: [(Maneuver.roundaboutClockwise, RoundaboutDirection?.some(.uTurn)),
                      (.roundaboutClockwise, nil),
                      (.roundaboutCounterClockwise, RoundaboutDirection?.some(.sharpRight))])
    func undrawableRoundaboutIsSuppressed(maneuver: Maneuver, direction: RoundaboutDirection?) {
        let c = ready()
        c.beginSession(SessionID())
        c.receive(roundaboutSnapshot(c, maneuver, direction: direction))
        #expect(c.intent == .clear(.unsupportedManeuver))
        #expect(transport.navigationWrites.allSatisfy { $0 == TbtFrame.stop() })
    }

    @Test func statusProfileSwitchesAtRuntime() {
        let c = ready()
        #expect(transport.writes.allSatisfy { $0.channel == .navigation })
        c.phoneStatus = PhoneStatus(volume: 9, batteryBars: 1)
        c.statusProfile = .legacy55
        let legacy = transport.writes.last!
        #expect(legacy.channel == .status && legacy.bytes.count == 55)
        #expect(legacy.bytes[1] == 1 << 3)
        c.statusProfile = .v2_89
        #expect(transport.writes.last!.bytes.count == 89)
        c.statusProfile = nil
        let count = transport.writes.count
        clock.advance(by: .seconds(10))
        c.tick()
        #expect(transport.writes.count == count)
    }

    @Test func newProbeReplacesHeldOneAndSessionStaysIdle() throws {
        let c = ready()
        let first = try roundabout(nibble: 1)
        let second = try roundabout(nibble: 2)
        #expect(c.showDiagnosticFrame(first))
        #expect(c.showDiagnosticFrame(second))
        #expect(transport.navigationWrites.last == second)
        #expect(c.session == nil)
        #expect(c.navigationState == .idle)
    }
}

@Suite("Roundabout direction calibration")
struct RoundaboutCalibrationTests {
    @Test func customCalibrationIsHonoured() {
        let custom = RoundaboutCalibration(clockwise: [.straight: 2], counterClockwise: [:])
        #expect(ManeuverMapper.roundaboutExit(for: .roundaboutClockwise, direction: .straight, calibration: custom) == 2)
        #expect(ManeuverMapper.roundaboutExit(for: .roundaboutClockwise, direction: .left, calibration: custom) == nil)
        #expect(ManeuverMapper.roundaboutExit(for: .roundaboutCounterClockwise, direction: .straight,
                                              calibration: custom) == nil)
    }

    @Test func outOfRangeCalibrationEntryIsIgnored() {
        let broken = RoundaboutCalibration(clockwise: [.uTurn: 9], counterClockwise: [:])
        #expect(ManeuverMapper.roundaboutExit(for: .roundaboutClockwise, direction: .uTurn, calibration: broken) == nil)
    }

    @Test func benchTableIsOneEighthTurnPerStep() {
        let order: [RoundaboutDirection] = [.sharpLeft, .left, .slightLeft, .straight, .slightRight, .right, .sharpRight]
        #expect(order.map { RoundaboutCalibration.n250.clockwise[$0] } == [1, 2, 3, 4, 5, 6, 7])
        #expect(order.reversed().compactMap { RoundaboutCalibration.n250.counterClockwise[$0] } == [1, 2, 3, 4, 5, 6])
    }
}

@Suite("Custom status packet")
struct CustomStatusTests {
    @Test func signalIsEncodedInBothProfiles() {
        for profile in GeneralStatusProfile.allCases {
            #expect(GeneralStatusEncoder.encode(profile, GeneralStatusFields(signal: 2, heartbeat: 1))[2] == 2)
            #expect(GeneralStatusEncoder.encode(profile, GeneralStatusFields(signal: 9, heartbeat: 1))[2] == 1)
        }
    }

    @Test func overridesKeepV2ChecksumValidUnlessTargeted() {
        let base = GeneralStatusEncoder.encode(.v2_89, GeneralStatusFields(heartbeat: 1))
        let patched = GeneralStatusEncoder.applying([3: 0x1F, 200: 1], to: base, profile: .v2_89)
        #expect(patched[3] == 0x1F)
        #expect(patched[88] == patched.prefix(88).reduce(UInt8(0)) { $0 &+ $1 })
        #expect(patched.count == 89)
        let forced = GeneralStatusEncoder.applying([88: 0], to: base, profile: .v2_89)
        #expect(forced[88] == 0)
        let legacy = GeneralStatusEncoder.applying([53: 7], to: GeneralStatusEncoder.encode(.legacy55, GeneralStatusFields(heartbeat: 1)),
                                                   profile: .legacy55)
        #expect(legacy[53] == 7 && legacy.count == 55)
    }

    @Test func parsesOverrideText() {
        #expect(GeneralStatusEncoder.parseOverrides("54=7, 3=0x1F") == [54: 7, 3: 31])
        #expect(GeneralStatusEncoder.parseOverrides("") == [:])
        #expect(GeneralStatusEncoder.parseOverrides("3=256") == nil)
        #expect(GeneralStatusEncoder.parseOverrides("x=1") == nil)
        #expect(GeneralStatusEncoder.parseOverrides("-1=1") == nil)
    }

    @Test func coordinatorSendsCustomValuesImmediately() {
        let clock = ManualClock()
        let transport = FakeTransport()
        let c = SessionCoordinator(clock: clock, configuration: SessionConfiguration(statusProfile: .legacy55))
        c.linkReady(ClusterWritePump(transport: transport, clock: clock, link: ClusterLinkInfo(
            navigationWriteMode: .withoutResponse, statusWriteMode: .withoutResponse, maximumWriteLength: 182)))
        c.phoneStatus = PhoneStatus(volume: 15, batteryBars: 1, signal: 2, rawOverrides: [17: 9])
        c.sendStatusNow()
        let packet = transport.writes.last!.bytes
        #expect(packet[0] == 0xCF && packet[1] == 1 << 3 && packet[2] == 2 && packet[17] == 9)
    }
}

@Suite("Phone event packets (console presets)")
struct PhonePacketTests {
    @Test func missedCallLayout() {
        let p = PhonePackets.missedCall(name: "Ravi", number: "+919876543210", epochSeconds: 0x6543_2100)
        #expect(p.count == 63 && p[0] == 1 && p[1] == 4)
        #expect(Array(p[2..<6]) == Array("Ravi".utf8))
        #expect(p[34] == 13 && Array(p[35..<48]) == Array("+919876543210".utf8))
        #expect(Array(p[53..<57]) == [0x65, 0x43, 0x21, 0x00])
        #expect(PhonePackets.missedCall(name: "123", number: "123", epochSeconds: 0)[1] == 0, "name equal to number is omitted")
    }

    @Test func alertLayout() {
        let p = PhonePackets.alert(.whatsApp, sender: "Asha", epochSeconds: 1)
        #expect(p.count == 44 && p[0] == 2 && p[1] == 4 && p[37] == 1)
        #expect(Array(p[2..<6]) == Array("Asha".utf8))
    }

    @Test func callerFieldsFollowUpstreamOffsets() {
        let legacy = GeneralStatusEncoder.encode(.legacy55, GeneralStatusFields(heartbeat: 1, callState: .incoming, callerName: "Ravi"))
        #expect(legacy[1] & 0x07 == 1 && legacy[18] == 1 && legacy[20] == 4)
        #expect(Array(legacy[21..<25]) == Array("Ravi".utf8))
        #expect(legacy[3] == 0 && legacy[4] == 1)
        let active = GeneralStatusEncoder.encode(.legacy55, GeneralStatusFields(heartbeat: 1, callState: .active, callerName: "Ravi"))
        #expect(active[3] == 1 && active[4] == 0)
        let v2 = GeneralStatusEncoder.encode(.v2_89, GeneralStatusFields(heartbeat: 1, callState: .incoming, callerName: "Ravi"))
        #expect(v2[1] & 0x0F == 1 && v2[18] == 1 && v2[19] == 4)
        #expect(Array(v2[20..<24]) == Array("Ravi".utf8))
        #expect(v2[88] == v2.prefix(88).reduce(UInt8(0)) { $0 &+ $1 })
        let ended = GeneralStatusEncoder.encode(.v2_89, GeneralStatusFields(heartbeat: 1, callState: .ended, callerName: "Ravi"))
        #expect(ended[18] == 0 && ended[19] == 0)
    }
}

@Suite("Hex bytes")
struct HexBytesTests {
    @Test func parsesCommonForms() {
        #expect(HexBytes.parse("11 47 00") == [0x11, 0x47, 0x00])
        #expect(HexBytes.parse("0x11,0x47") == [0x11, 0x47])
        #expect(HexBytes.parse("aBcD") == [0xAB, 0xCD])
        #expect(HexBytes.parse("114") == nil)
        #expect(HexBytes.parse("zz") == nil)
        #expect(HexBytes.parse("") == nil)
    }

    @Test func formats() {
        #expect(HexBytes.format([0x01, 0xAB, 0x0F]) == "01 AB 0F")
        #expect(HexBytes.format([0x01, 0xAB, 0x0F, 0x10], grouping: 2) == "01AB 0F10")
        #expect(HexBytes.parse(HexBytes.format(TbtFrame.stop())) == TbtFrame.stop())
    }
}
