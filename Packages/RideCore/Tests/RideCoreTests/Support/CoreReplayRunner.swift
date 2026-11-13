import Foundation
@testable import RideCore

/// A versioned, bounded script of ride events on virtual time. Equal-time events
/// run in ordinal order; deadlines are resolved only by explicit `tick` events.
struct ReplayTrace: Decodable {
    static let schemaVersion = 1
    static let maxEvents = 2_000
    static let maxDurationMilliseconds = 6 * 60 * 60 * 1_000

    struct Event: Decodable {
        enum Kind: String, Decodable {
            /// Sensor fix at metres (x east, y north) of the test origin; `age` ms old on receipt.
            case location
            /// Presentation refresh: re-stamps the last snapshot, measures nothing.
            case refresh
            case tick
            case linkReady
            case linkLost
            case ack
            case nack
            case stop
        }

        let offset: Int
        let ordinal: Int
        let kind: Kind
        var x: Double?
        var y: Double?
        var age: Int?
        var accuracy: Double?
    }

    let schemaVersion: Int
    let events: [Event]

    enum Invalid: Error {
        case schema, tooLarge, negativeTime, regressingTime, duplicateOrdinal
    }

    static func load(_ json: String) throws -> ReplayTrace {
        let trace = try JSONDecoder().decode(ReplayTrace.self, from: Data(json.utf8))
        guard trace.schemaVersion == schemaVersion else { throw Invalid.schema }
        guard trace.events.count <= maxEvents,
              trace.events.allSatisfy({ $0.offset <= maxDurationMilliseconds }) else { throw Invalid.tooLarge }
        guard trace.events.allSatisfy({ $0.offset >= 0 }) else { throw Invalid.negativeTime }
        for (a, b) in zip(trace.events, trace.events.dropFirst()) {
            guard b.offset >= a.offset else { throw Invalid.regressingTime }
            guard b.offset > a.offset || b.ordinal > a.ordinal else { throw Invalid.duplicateOrdinal }
        }
        return trace
    }
}

/// Drives the real engine, admission, coordinator and write pump against a fake
/// transport, and records the safety-relevant effects in order.
final class CoreReplayRunner {
    private let clock = ManualClock(wallNow: Date(timeIntervalSince1970: 1_800_000_000))
    private let transport = FakeTransport()
    private let coordinator: SessionCoordinator
    private let engine: GuidanceEngine
    private var admission = LocationAdmission()
    private var pump: ClusterWritePump?
    private(set) var log: [String] = []

    init() {
        coordinator = SessionCoordinator(clock: clock, configuration: SessionConfiguration(timeZone: TimeZone(identifier: "UTC")!))
        let session = SessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        coordinator.beginSession(session)
        engine = GuidanceEngine(route: cityRoute, session: session, generation: coordinator.generation)!
        coordinator.onWriteEvent = { [weak self] in self?.log.append("event \($0)") }
    }

    func run(_ trace: ReplayTrace) -> [String] {
        var now = 0
        for event in trace.events {
            if event.offset > now {
                clock.advance(by: .milliseconds(event.offset - now))
                now = event.offset
            }
            apply(event)
            log.append("t=\(now) \(event.kind.rawValue): \(describe(coordinator.intent)) delivery=\(coordinator.delivery) writes=\(transport.writes.count)")
        }
        return log
    }

    private func apply(_ event: ReplayTrace.Event) {
        switch event.kind {
        case .location:
            let sample = LocationSample(coordinate: at(event.x ?? 0, event.y ?? 0),
                                        horizontalAccuracy: event.accuracy ?? 5,
                                        timestamp: clock.wallNow.addingTimeInterval(-Double(event.age ?? 0) / 1_000))
            switch admission.admit(sample, receiptWall: clock.wallNow, receiptMonotonic: clock.now) {
            case .success(let fix):
                coordinator.receive(engine.update(fix.fix).snapshot)
            case .failure(let reason):
                log.append("rejected \(reason)")
            }
        case .refresh:
            if let snapshot = engine.refresh(at: clock.now) { coordinator.receive(snapshot) }
        case .tick:
            coordinator.tick()
        case .linkReady:
            let pump = ClusterWritePump(transport: transport, clock: clock, link: responseLink)
            self.pump = pump
            coordinator.linkReady(pump)
        case .linkLost:
            coordinator.linkLost()
            pump = nil
        case .ack:
            pump?.didCompleteWrite(on: .navigation, success: true)
        case .nack:
            pump?.didCompleteWrite(on: .navigation, success: false)
        case .stop:
            coordinator.endSession()
        }
    }

    private func describe(_ intent: DashboardIntent) -> String {
        switch intent {
        case .guidance(let fields, _): "guidance icon=\(fields.icon) step=\(fields.stepMetres)"
        case .clear(let reason): "clear \(reason)"
        }
    }
}
