import Foundation

/// Privacy-restricted event log for the shareable diagnostics export.
///
/// Events are typed and carry only categories, counts and states: there is no
/// free-text field, so coordinates, road names, keys and bike identifiers cannot
/// be recorded even by mistake.
public struct DiagnosticsLog: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case appLaunched(live: Bool)
        case navigationState(NavigationState)
        case dashboard(DashboardSummary)
        case link(LinkSummary)
        case write(WriteSummary)
        case routeRequest(RouteRequestSummary)
        case permission(PermissionSummary)
    }

    public enum DashboardSummary: String, Sendable, Equatable {
        case guidance, clearedNoSession, clearedNotGuiding, clearedNoStep, clearedUnsupported
        case clearedMissingProgress, clearedStale, clearedInvalid

        public init(_ intent: DashboardIntent) {
            switch intent {
            case .guidance: self = .guidance
            case .clear(.noSession): self = .clearedNoSession
            case .clear(.notGuiding): self = .clearedNotGuiding
            case .clear(.noStep): self = .clearedNoStep
            case .clear(.unsupportedManeuver): self = .clearedUnsupported
            case .clear(.missingProgress): self = .clearedMissingProgress
            case .clear(.stale): self = .clearedStale
            case .clear(.invalidValues): self = .clearedInvalid
            }
        }
    }

    public enum LinkSummary: String, Sendable, Equatable {
        case unavailable, idle, scanning, connecting, discovering, ready, reconnecting
        case failedServiceNotFound, failedCharacteristic, failedWriteLength, failedTimeout, gaveUp

        public init(_ state: BikeLinkState) {
            switch state {
            case .unavailable: self = .unavailable
            case .idle: self = .idle
            case .scanning: self = .scanning
            case .connecting: self = .connecting
            case .discovering: self = .discovering
            case .ready: self = .ready
            case .reconnecting: self = .reconnecting
            case .failed(.serviceNotFound): self = .failedServiceNotFound
            case .failed(.characteristicNotFound), .failed(.characteristicNotWritable): self = .failedCharacteristic
            case .failed(.writeLengthTooSmall): self = .failedWriteLength
            case .failed(.connectTimeout): self = .failedTimeout
            case .failed(.gaveUp): self = .gaveUp
            }
        }
    }

    public enum WriteSummary: String, Sendable, Equatable {
        case rejectedTooLarge, failed, timedOut, clearAcknowledged, clearHandedOff, unhealthy

        public init(_ event: ClusterWriteEvent) {
            switch event {
            case .rejectedTooLarge: self = .rejectedTooLarge
            case .failed: self = .failed
            case .timedOut: self = .timedOut
            case .clearAcknowledged: self = .clearAcknowledged
            case .clearHandedOff: self = .clearHandedOff
            case .unhealthy: self = .unhealthy
            }
        }
    }

    public enum RouteRequestSummary: String, Sendable, Equatable {
        case authorized, deniedDisabled, deniedInFlight, deniedTooSoon, deniedLimit, deniedInvalid
        case succeeded, failedNoRoute, failedNetwork, failedQuota, failedKey, failedOther, cancelled

        public init(_ denial: RouteRequestDenial) {
            switch denial {
            case .providerDisabled: self = .deniedDisabled
            case .requestInFlight: self = .deniedInFlight
            case .tooSoon: self = .deniedTooSoon
            case .dailyLimitReached, .monthlyLimitReached: self = .deniedLimit
            case .invalidDestinationCount: self = .deniedInvalid
            }
        }
    }

    public enum PermissionSummary: String, Sendable, Equatable {
        case bluetoothDenied, locationDenied, locationWhenInUse, locationAlways
    }

    public struct Entry: Sendable, Equatable {
        public var offset: Duration
        public var event: Event
    }

    public private(set) var entries: [Entry] = []
    public let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public mutating func record(_ event: Event, at instant: MonotonicInstant) {
        if let last = entries.last, last.event == event { return }
        entries.append(Entry(offset: instant.offset, event: event))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// Plain-text export: versions, per-category counts and the event timeline.
    public func export(appVersion: String, sdkVersion: String?, osVersion: String) -> String {
        var lines = [
            "N250 Ride diagnostics",
            "app \(appVersion)",
            "os \(osVersion)",
            "navigation sdk \(sdkVersion ?? "not initialised")",
            "events \(entries.count) (capacity \(capacity))",
            "",
        ]
        var counts: [String: Int] = [:]
        for entry in entries { counts[Self.category(entry.event), default: 0] += 1 }
        lines += counts.keys.sorted().map { "count \($0) \(counts[$0]!)" }
        lines.append("")
        lines += entries.map { entry in
            let ms = entry.offset.components.seconds * 1000 + entry.offset.components.attoseconds / 1_000_000_000_000_000
            return "+\(ms)ms \(Self.describe(entry.event))"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func category(_ event: Event) -> String {
        switch event {
        case .appLaunched: "app"
        case .navigationState: "navigation"
        case .dashboard: "dashboard"
        case .link: "link"
        case .write: "write"
        case .routeRequest: "route"
        case .permission: "permission"
        }
    }

    static func describe(_ event: Event) -> String {
        switch event {
        case .appLaunched(let live): "app launched mode=\(live ? "live" : "simulation")"
        case .navigationState(let state): "navigation \(describe(state))"
        case .dashboard(let s): "dashboard \(s.rawValue)"
        case .link(let s): "link \(s.rawValue)"
        case .write(let s): "write \(s.rawValue)"
        case .routeRequest(let s): "route \(s.rawValue)"
        case .permission(let s): "permission \(s.rawValue)"
        }
    }

    static func describe(_ state: NavigationState) -> String {
        switch state {
        case .idle: "idle"
        case .preview: "preview"
        case .active: "active"
        case .rerouting: "rerouting"
        case .noLocation: "noLocation"
        case .arrived: "arrived"
        case .stopped: "stopped"
        case .failed(.locationPermissionDenied): "failed.locationDenied"
        case .failed(.travelModeUnsupported): "failed.travelModeUnsupported"
        case .failed(.routeUnavailable): "failed.routeUnavailable"
        case .failed(.providerDisabled): "failed.providerDisabled"
        }
    }
}
