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
    public var phoneStatus = PhoneStatus()
    /// Status packet profile; nil sends none. Changeable at runtime for bench testing.
    public var statusProfile: GeneralStatusProfile? {
        didSet {
            lastStatusSentAt = nil
            sync()
        }
    }

    public private(set) var intent: DashboardIntent = .clear(.noSession)
    public private(set) var output: DashboardOutput = .unknownLinkDown
    public private(set) var rejectedSnapshots = 0
    /// True only after the cluster acknowledged a clear on the current link.
    public private(set) var clearAcknowledged = false

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

    // MARK: Link side

    public func linkReady(_ pump: ClusterWritePump) {
        self.pump?.reset()
        self.pump = pump
        clearAcknowledged = false
        pump.onEvent = { [weak self] event in
            if event == .clearAcknowledged { self?.clearAcknowledged = true }
            self?.onWriteEvent?(event)
        }
        output = .sending
        // Whatever the cluster shows is from an older link: clear before anything fresh.
        pump.submitClear()
        sentIntent = .clear(.noSession)
        heartbeat = HeartbeatCounter()
        lastStatusSentAt = nil
        sync()
    }

    public func linkLost() {
        pump?.reset()
        pump = nil
        sentIntent = nil
        lastNavigationSentAt = nil
        lastStatusSentAt = nil
        clearAcknowledged = false
        output = .unknownLinkDown
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
        guard clock.now.duration(since: snapshot.observedAt) <= configuration.freshness else {
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

        if let profile = statusProfile,
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
            }
        case .clear:
            // One clear per transition; quiet valid states are not re-cleared.
            let alreadyCleared = if case .clear = sentIntent { true } else { false }
            if !alreadyCleared {
                pump.submitClear()
                sentIntent = intent
                lastNavigationSentAt = nil
            }
        }
    }
}
