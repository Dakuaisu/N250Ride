import Testing
@testable import RideCore

final class FakeTransport: ClusterWriteTransport {
    struct Write: Equatable {
        var bytes: [UInt8]
        var channel: ClusterChannel
        var mode: WriteMode
    }

    var maximumLength = 244
    var canSendWriteWithoutResponse = true
    private(set) var writes: [Write] = []

    func maximumWriteLength(for mode: WriteMode) -> Int { maximumLength }

    func write(_ bytes: [UInt8], to channel: ClusterChannel, mode: WriteMode) {
        writes.append(Write(bytes: bytes, channel: channel, mode: mode))
    }

    var navigationWrites: [[UInt8]] { writes.filter { $0.channel == .navigation }.map(\.bytes) }
}

func frame(icon: UInt8, step: Int) -> [UInt8] {
    try! TbtFrame.encode(TbtFields(frameType: .navigation, icon: icon, isAM: true, stepMetres: step,
                                   totalMetres: 5_000, etaHour: 10, etaMinute: 0))
}

let responseLink = ClusterLinkInfo(navigationWriteMode: .withResponse, statusWriteMode: .withResponse, maximumWriteLength: 244)

@Suite("Write pump")
struct WritePumpTests {
    @Test func heldCompletionKeepsOneWriteOutstandingAndLatestWins() {
        let clock = ManualClock()
        let transport = FakeTransport()
        let pump = ClusterWritePump(transport: transport, clock: clock, link: responseLink)

        pump.submitNavigation(frame(icon: ClusterIcon.straight, step: 1_000))
        #expect(transport.writes.count == 1)
        for i in 1...20 {
            clock.advance(by: .milliseconds(100))
            pump.tick()
            pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 1_000 - i * 10))
        }
        #expect(clock.now.offset == .seconds(2))
        #expect(transport.writes.count == 1, "only one response write may be outstanding")

        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(transport.writes.count == 2)
        #expect(transport.writes[1].bytes == frame(icon: ClusterIcon.turnLeft, step: 800))

        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(transport.writes.count == 2, "intermediate frames were coalesced")
        #expect(pump.isIdle)
    }

    @Test func stopTakesPriorityOverPendingGuidance() {
        let transport = FakeTransport()
        let pump = ClusterWritePump(transport: transport, clock: ManualClock(), link: responseLink)
        var events: [ClusterWriteEvent] = []
        pump.onEvent = { events.append($0) }

        pump.submitNavigation(frame(icon: ClusterIcon.straight, step: 900))
        pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 800))
        pump.submitStatus([1, 2, 3])
        pump.submitClear()
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(transport.writes[1].bytes == TbtFrame.stop())
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(events.contains(.clearAcknowledged))
        #expect(transport.writes[2].channel == .status)
        pump.didCompleteWrite(on: .status, success: true)
        #expect(transport.navigationWrites.count == 2, "the superseded turn-left frame is never sent")
    }

    @Test func freshGuidanceAfterClearIsSentAfterIt() {
        let transport = FakeTransport()
        let pump = ClusterWritePump(transport: transport, clock: ManualClock(), link: responseLink)
        pump.submitStatus([9])
        pump.submitClear()
        pump.submitNavigation(frame(icon: ClusterIcon.turnRight, step: 300))
        pump.didCompleteWrite(on: .status, success: true)
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(transport.navigationWrites == [TbtFrame.stop(), frame(icon: ClusterIcon.turnRight, step: 300)])
    }

    @Test func insufficientWriteLengthSendsNothing() {
        let transport = FakeTransport()
        transport.maximumLength = 20
        let pump = ClusterWritePump(transport: transport, clock: ManualClock(), link: responseLink)
        var events: [ClusterWriteEvent] = []
        pump.onEvent = { events.append($0) }
        pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 300))
        #expect(transport.writes.isEmpty)
        #expect(events == [.rejectedTooLarge(.navigation, size: 48, maximum: 20)])
    }

    @Test func failuresAndTimeoutsReportUnhealthyOnce() {
        let clock = ManualClock()
        let transport = FakeTransport()
        let pump = ClusterWritePump(transport: transport, clock: clock, link: responseLink)
        var events: [ClusterWriteEvent] = []
        pump.onEvent = { events.append($0) }

        pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 300))
        pump.didCompleteWrite(on: .navigation, success: false)
        pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 290))
        clock.advance(by: .seconds(2))
        pump.tick()
        #expect(pump.hasWriteInFlight, "2 s is below the 3 s timeout")
        clock.advance(by: .seconds(1))
        pump.tick()
        pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 280))
        pump.didCompleteWrite(on: .navigation, success: false)
        pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 270))
        pump.didCompleteWrite(on: .navigation, success: false)

        #expect(events == [.failed(.navigation), .timedOut(.navigation), .failed(.navigation),
                           .unhealthy(consecutiveFailures: 3), .failed(.navigation)])
    }

    @Test func resetPurgesAndIgnoresLateCompletion() {
        let transport = FakeTransport()
        let pump = ClusterWritePump(transport: transport, clock: ManualClock(), link: responseLink)
        var events: [ClusterWriteEvent] = []
        pump.onEvent = { events.append($0) }
        pump.submitClear()
        pump.submitNavigation(frame(icon: ClusterIcon.turnLeft, step: 300))
        pump.reset()
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(events.isEmpty, "a clear in flight at link loss is never reported delivered")
        #expect(transport.writes.count == 1)
        #expect(pump.isIdle)
    }

    @Test func withoutResponseHonoursReadiness() {
        let transport = FakeTransport()
        transport.canSendWriteWithoutResponse = false
        let link = ClusterLinkInfo(navigationWriteMode: .withoutResponse, statusWriteMode: nil, maximumWriteLength: 244)
        let pump = ClusterWritePump(transport: transport, clock: ManualClock(), link: link)
        var events: [ClusterWriteEvent] = []
        pump.onEvent = { events.append($0) }

        pump.submitClear()
        pump.submitStatus([1])
        #expect(transport.writes.isEmpty)
        transport.canSendWriteWithoutResponse = true
        pump.transportReadyForWriteWithoutResponse()
        #expect(transport.writes.map(\.bytes) == [TbtFrame.stop()])
        #expect(events == [.clearHandedOff], "without-response clears are never claimed acknowledged")
    }
}

@Suite("GATT validation and reconnect policy")
struct LinkPolicyTests {
    @Test func validatesDiscoveredCharacteristics() {
        let ok = ClusterGATT.validate(serviceFound: true, navigation: [.write], status: [.writeWithoutResponse]) { _ in 244 }
        #expect(ok == .success(ClusterLinkInfo(navigationWriteMode: .withResponse, statusWriteMode: .withoutResponse,
                                               maximumWriteLength: 244)))
        #expect(ClusterGATT.validate(serviceFound: false, navigation: nil, status: nil) { _ in 244 } == .failure(.serviceNotFound))
        #expect(ClusterGATT.validate(serviceFound: true, navigation: nil, status: [.write]) { _ in 244 }
            == .failure(.characteristicNotFound(ClusterGATT.navigation)))
        #expect(ClusterGATT.validate(serviceFound: true, navigation: [.read], status: nil) { _ in 244 }
            == .failure(.characteristicNotWritable(ClusterGATT.navigation)))
        #expect(ClusterGATT.validate(serviceFound: true, navigation: [.write], status: nil) { _ in 20 }
            == .failure(.writeLengthTooSmall(required: 48, available: 20)))
    }

    @Test func reconnectBackoffIsBounded() {
        let policy = ReconnectPolicy()
        #expect(policy.delay(beforeAttempt: 1) == .seconds(3))
        #expect(policy.delay(beforeAttempt: 4) == .seconds(12))
        #expect(policy.delay(beforeAttempt: 6) == .seconds(15))
        #expect(policy.delay(beforeAttempt: 20) == .seconds(15))
        #expect(policy.delay(beforeAttempt: 21) == nil)
    }
}
