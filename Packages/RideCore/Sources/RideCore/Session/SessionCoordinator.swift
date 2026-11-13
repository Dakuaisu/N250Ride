import Foundation

public struct SessionConfiguration: Sendable {
    /// Provisional watchdog; re-characterise against real SDK cadence before release.
    public var freshness: Duration
    public var navigationResendInterval: Duration
    public var statusInterval: Duration
    /// nil until a profile is proven on this cluster: no status packets are sent.
    public var statusProfile: GeneralStatusProfile?
    public var roundaboutCalibration: RoundaboutCalibration
    public var timeZone: TimeZone

    public init(
        freshness: Duration = .seconds(5),
        navigationResendInterval: Duration = .milliseconds(800),
        statusInterval: Duration = .seconds(5),
        statusProfile: GeneralStatusProfile? = nil,
        roundaboutCalibration: RoundaboutCalibration = .n250,
        timeZone: TimeZone = .current
    ) {
        self.freshness = freshness
        self.navigationResendInterval = navigationResendInterval
        self.statusInterval = statusInterval
        self.statusProfile = statusProfile
        self.roundaboutCalibration = roundaboutCalibration
        self.timeZone = timeZone
    }
}

public enum ClearReason: Sendable, Equatable {
    case noSession
    case notGuiding(NavigationState)
    case noStep
    case unsupportedManeuver
    case missingProgress
    case stale
    case invalidValues(TbtEncodingError)
}

/// What the dashboard should show right now.
public enum DashboardIntent: Sendable, Equatable {
    case guidance(TbtFields, frame: [UInt8])
    case clear(ClearReason)
}

/// What the write path can honestly say about the latest output. A transport
/// acknowledgement proves the cluster accepted bytes, not that the rider saw them.
public enum DashboardDelivery: Sendable, Equatable {
    case linkDown
    case clearPending
    case clearTransportAcknowledged
    case clearHandedOffWithoutResponse
    case guidanceSubmitted
    /// A write failed or timed out; what the cluster shows is unknown.
    case deliveryUncertain
}

/// What is known about the physical dashboard.
public enum DashboardOutput: Sendable, Equatable {
    /// No link: the cluster keeps whatever it last drew until its own timeout.
    case unknownLinkDown
    case sending
}

public struct PhoneStatus: Sendable, Equatable {
    public var volume: Int
    public var batteryBars: Int
    public var signal: Int
    /// Bench testing only: raw byte overrides applied after encoding.
    public var rawOverrides: [Int: UInt8]

    public init(volume: Int = 5, batteryBars: Int = 3, signal: Int = 4, rawOverrides: [Int: UInt8] = [:]) {
        self.volume = volume
        self.batteryBars = batteryBars
        self.signal = signal
        self.rawOverrides = rawOverrides
    }
}

/// Joins a navigation source, the encoder and the BLE write pump under the safety
/// rules: session/generation isolation, immediate clearing on non-guiding states,
/// a freshness watchdog, and clear-before-fresh ordering on every new link.
///
/// It has no way to request routes, so Bluetooth events cannot cause billable calls.
public final class SessionCoordinator {
    public var onIntentChange: ((DashboardIntent) -> Void)?
    public var onWriteEvent: ((ClusterWriteEvent) -> Void)?
    /// Anything that may move `nextDeadline`: a sync, a write completion, an event.
    public var onActivity: (() -> Void)?
    public var phoneStatus = PhoneStatus()
    /// Status packet profile; nil sends none. Changeable at runtime for bench testing.
    public var statusProfile: GeneralStatusProfile? {
        didSet {
            lastStatusSentAt = nil
            if statusProfile == nil { pump?.discardPendingStatus() }
            sync()
        }
    }
    /// Holds the app's status packets, e.g. during a phone call: each one says "no
    /// call", and the cluster drops its call screen when it reads one.
    public var statusPaused = false {
        didSet {
            guard statusPaused != oldValue else { return }
            lastStatusSentAt = nil
            // A "no call" packet still queued behind another write must not go out during the pause.
            if statusPaused { pump?.discardPendingStatus() }
            sync()
        }
    }

    public private(set) var intent: DashboardIntent = .clear(.noSession)
    public private(set) var output: DashboardOutput = .unknownLinkDown
    public private(set) var rejectedSnapshots = 0
    /// True only after the cluster acknowledged the latest clear on the current link.
    public private(set) var clearAcknowledged = false
    public private(set) var delivery: DashboardDelivery = .linkDown
    private var clearRequests = 0
    private var freshClear: (id: Int, outcome: DashboardDelivery?)?

    private var machine = NavigationStateMachine()
    private let clock: RideClock
    private let configuration: SessionConfiguration
    private var calendar: Calendar
    private var pump: ClusterWritePump?
    private var sentIntent: DashboardIntent?
    private var lastNavigationSentAt: MonotonicInstant?
    private var lastStatusSentAt: MonotonicInstant?
    private var heartbeat = HeartbeatCounter()
    private var diagnosticFrame: (frame: [UInt8], startedAt: MonotonicInstant)?

    public init(clock: RideClock, configuration: SessionConfiguration = SessionConfiguration()) {
        self.clock = clock
        self.configuration = configuration
        self.statusProfile = configuration.statusProfile
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = configuration.timeZone
        self.calendar = calendar
    }

    public var navigationState: NavigationState { machine.state }
    public var session: SessionID? { machine.session }
    public var generation: RouteGeneration { machine.generation }

    // MARK: Navigation side

    public func beginSession(_ session: SessionID) {
        machine.begin(session)
        sync()
    }

    /// Explicit replacement route; callbacks from older generations are ignored afterwards.
    @discardableResult
    public func replaceRoute() -> RouteGeneration {
        let generation = machine.advanceGeneration()
        sync()
        return generation
    }

    /// Authoritative stop: clears immediately and ends the session.
    public func endSession() {
        machine.end()
        sync()
    }

    @discardableResult
    public func receive(_ snapshot: NavigationSnapshot) -> Result<NavigationSnapshot, SnapshotRejection> {
        let result = machine.accept(snapshot)
        if case .failure = result {
            rejectedSnapshots += 1
        }
        sync()
        return result
    }

    // MARK: Parked diagnostics

    /// Sends a status packet on the next tick instead of waiting for the interval.
    public func sendStatusNow() {
        lastStatusSentAt = nil
        sync()
    }

    /// Holds a raw, checksummed frame on the dashboard for the freshness window,
    /// resent at the normal cadence, then clears. Refused while a navigation session
    /// exists; starting one cancels the probe.
    @discardableResult
    public func showDiagnosticFrame(_ frame: [UInt8]) -> Bool {
        guard machine.session == nil, TbtFrame.hasValidChecksum(frame) else { return false }
        diagnosticFrame = (frame, clock.now)
        lastNavigationSentAt = nil
        sync()
        return true
    }

    public func clearDiagnosticFrame() {
        diagnosticFrame = nil
        sync()
    }

    public var isShowingDiagnosticFrame: Bool { diagnosticFrame != nil }

    /// Parked bench only: submits a brand-new clear even when the dashboard is
    /// already believed clear, so its own acknowledgement can be observed. Returns
    /// a number identifying it; `clearRequestOutcome` reports only on that request.
    @discardableResult
    public func requestFreshClear() -> Int? {
        guard machine.session == nil, let pump else { return nil }
        diagnosticFrame = nil
        clearRequests += 1
        freshClear = (clearRequests, nil)
        submitClear(on: pump)
        sentIntent = .clear(.noSession)
        lastNavigationSentAt = nil
        sync()
        return clearRequests
    }

    /// What is known about one fresh clear: nil while unanswered.
    public func clearRequestOutcome(_ id: Int) -> DashboardDelivery? {
        guard let freshClear, freshClear.id == id else { return .deliveryUncertain }
        return freshClear.outcome
    }

    // MARK: Link side

    public func linkReady(_ pump: ClusterWritePump) {
        self.pump?.reset()
        self.pump = pump
        clearAcknowledged = false
        pump.onEvent = { [weak self] event in
            self?.record(event)
            self?.onWriteEvent?(event)
        }
        pump.onProgress = { [weak self] in self?.onActivity?() }
        output = .sending
        // Whatever the cluster shows is from an older link: clear before anything fresh.
        submitClear(on: pump)
        sentIntent = .clear(.noSession)
        heartbeat = HeartbeatCounter()
        lastStatusSentAt = nil
        sync()
    }

    public func linkLost() {
        pump?.reset()
        pump = nil
        if var fresh = freshClear, fresh.outcome == nil {
            fresh.outcome = .linkDown
            freshClear = fresh
        }
        sentIntent = nil
        lastNavigationSentAt = nil
        lastStatusSentAt = nil
        clearAcknowledged = false
        delivery = .linkDown
        output = .unknownLinkDown
    }

    private func record(_ event: ClusterWriteEvent) {
        switch event {
        case .clearAcknowledged:
            clearAcknowledged = true
            delivery = .clearTransportAcknowledged
        case .clearHandedOff:
            delivery = .clearHandedOffWithoutResponse
        case .failed, .timedOut, .rejectedTooLarge, .unhealthy:
            delivery = .deliveryUncertain
        }
        if var fresh = freshClear, fresh.outcome == nil {
            switch event {
            case .clearAcknowledged, .clearHandedOff, .timedOut, .rejectedTooLarge, .unhealthy:
                fresh.outcome = delivery
                freshClear = fresh
            case .failed:
                break
            }
        }
    }

    private func submitClear(on pump: ClusterWritePump) {
        clearAcknowledged = false
        delivery = .clearPending
        pump.submitClear()
    }

    /// The earliest moment `tick()` has work to do, or nil when nothing is due
    /// until some external event. Used to schedule wakes instead of polling.
    public var nextDeadline: MonotonicInstant? {
        var deadlines: [MonotonicInstant] = []
        if let snapshot = machine.latest, case .guidance = intent {
            deadlines.append((snapshot.measurementAt ?? snapshot.observedAt) + configuration.freshness)
        }
        if let held = diagnosticFrame {
            deadlines.append(held.startedAt + configuration.freshness)
        }
        if pump != nil {
            if diagnosticFrame != nil || (sentIntent.map { if case .guidance = $0 { true } else { false } } ?? false) {
                deadlines.append((lastNavigationSentAt ?? clock.now) + configuration.navigationResendInterval)
            }
            if statusProfile != nil, !statusPaused {
                deadlines.append((lastStatusSentAt ?? clock.now) + configuration.statusInterval)
            }
            if let write = pump?.nextDeadline { deadlines.append(write) }
        }
        return deadlines.min()
    }

    /// Drives the watchdog, resend cadence, status heartbeat and write timeouts.
    public func tick() {
        pump?.tick()
        sync()
    }

    // MARK: Evaluation

    func evaluate() -> DashboardIntent {
        guard machine.session != nil else { return .clear(.noSession) }
        guard let snapshot = machine.latest else { return .clear(.notGuiding(machine.state)) }
        guard snapshot.state.allowsGuidance else { return .clear(.notGuiding(snapshot.state)) }
        guard clock.now < (snapshot.measurementAt ?? snapshot.observedAt) + configuration.freshness else {
            return .clear(.stale)
        }

        let fields: TbtFields
        if snapshot.state == .arrived {
            let eta = etaClock(clock.wallNow)
            fields = TbtFields(frameType: .navigation, icon: ClusterIcon.destinationReached, isAM: eta.isAM,
                               stepMetres: 0, totalMetres: 0, etaHour: eta.hour, etaMinute: eta.minute)
        } else {
            guard let step = snapshot.step else { return .clear(.noStep) }
            guard let icon = ManeuverMapper.icon(for: step.maneuver, stepMetres: step.distanceMetres) else {
                return .clear(.unsupportedManeuver)
            }
            guard let exit = ManeuverMapper.roundaboutExit(
                for: step.maneuver, direction: step.roundaboutDirection,
                calibration: configuration.roundaboutCalibration) else {
                return .clear(.unsupportedManeuver)
            }
            guard let total = snapshot.remainingMetres, let arrival = etaDate(snapshot) else {
                return .clear(.missingProgress)
            }
            let eta = etaClock(arrival)
            fields = TbtFields(
                frameType: .navigation, icon: icon, isAM: eta.isAM,
                stepMetres: step.distanceMetres, totalMetres: total,
                etaHour: eta.hour, etaMinute: eta.minute,
                roundaboutExit: exit,
                text: step.roadText
            )
        }
        do {
            return .guidance(fields, frame: try TbtFrame.encode(fields))
        } catch {
            return .clear(.invalidValues(error))
        }
    }

    private func etaDate(_ snapshot: NavigationSnapshot) -> Date? {
        if let eta = snapshot.destinationETA { return eta }
        return snapshot.remainingSeconds.map { clock.wallNow + TimeInterval($0) }
    }

    private func etaClock(_ date: Date) -> (hour: Int, minute: Int, isAM: Bool) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = c.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return (hour12, c.minute ?? 0, hour24 < 12)
    }

    private func sync() {
        defer { onActivity?() }
        let next = evaluate()
        if next != intent {
            intent = next
            onIntentChange?(next)
        }
        let now = clock.now
        if let held = diagnosticFrame,
           machine.session != nil || now.duration(since: held.startedAt) > configuration.freshness {
            diagnosticFrame = nil
        }
        guard let pump else { return }

        if let held = diagnosticFrame {
            if lastNavigationSentAt.map({ now.duration(since: $0) >= configuration.navigationResendInterval }) ?? true {
                pump.submitNavigation(held.frame)
                lastNavigationSentAt = now
                sentIntent = nil
            }
        } else {
            sendIntent(on: pump, now: now)
        }

        if let profile = statusProfile, !statusPaused,
           lastStatusSentAt.map({ now.duration(since: $0) >= configuration.statusInterval }) ?? true {
            let fields = GeneralStatusFields(volume: phoneStatus.volume, batteryBars: phoneStatus.batteryBars,
                                             signal: phoneStatus.signal, heartbeat: heartbeat.next())
            let packet = GeneralStatusEncoder.encode(profile, fields)
            pump.submitStatus(phoneStatus.rawOverrides.isEmpty ? packet
                : GeneralStatusEncoder.applying(phoneStatus.rawOverrides, to: packet, profile: profile))
            lastStatusSentAt = now
        }
    }

    private func sendIntent(on pump: ClusterWritePump, now: MonotonicInstant) {
        switch intent {
        case .guidance(_, let frame):
            let due = lastNavigationSentAt.map { now.duration(since: $0) >= configuration.navigationResendInterval } ?? true
            if sentIntent != intent || due {
                pump.submitNavigation(frame)
                lastNavigationSentAt = now
                sentIntent = intent
                delivery = .guidanceSubmitted
            }
        case .clear:
            // One clear per transition; quiet valid states are not re-cleared.
            let alreadyCleared = if case .clear = sentIntent { true } else { false }
            if !alreadyCleared {
                submitClear(on: pump)
                sentIntent = intent
                lastNavigationSentAt = nil
            }
        }
    }
}
