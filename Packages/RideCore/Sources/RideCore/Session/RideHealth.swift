import Foundation

/// Everything that decides whether the rider can trust what they see, gathered
/// from the existing owners. Pure input: building it has no side effects.
public struct RideHealthInput: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle, preparing, preview, navigating, atStop, recoveryOffered
    }

    public enum Position: Sendable, Equatable {
        case permissionDenied
        case none
        /// Age of the newest genuine measurement and its accuracy.
        case measured(age: Duration, accuracy: Double)
    }

    public enum RouteStatus: Sendable, Equatable {
        case ok
        case calculating
        case failed(String)
    }

    public enum Link: Sendable, Equatable {
        case notPaired, connecting, ready, down
    }

    public enum Voice: Sendable, Equatable {
        case off, ok, held(String)
    }

    public var phase: Phase
    public var position: Position
    public var navigationState: NavigationState
    public var intent: DashboardIntent
    public var route: RouteStatus
    public var link: Link
    public var delivery: DashboardDelivery
    public var voice: Voice

    public init(phase: Phase, position: Position, navigationState: NavigationState, intent: DashboardIntent,
                route: RouteStatus, link: Link, delivery: DashboardDelivery, voice: Voice) {
        self.phase = phase
        self.position = position
        self.navigationState = navigationState
        self.intent = intent
        self.route = route
        self.link = link
        self.delivery = delivery
        self.voice = voice
    }
}

public struct RideHealth: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case ok, info, warning, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Kind: Sendable, Equatable {
        case position, route, confirmation, dashboard, voice
    }

    public enum Action: Sendable, Equatable {
        case openSettings, retryRoute, reconnectBike, confirmLeg, resumeRide, allowSpeaker
    }

    public struct Item: Sendable, Equatable {
        public var kind: Kind
        public var severity: Severity
        public var message: String
        public var action: Action?
    }

    /// The most important item; `.ok` "Guidance is current" when nothing is wrong.
    public var primary: Item
    /// Every non-ok component, most important first.
    public var items: [Item]
    /// Whether any surface may show a direction right now.
    public var directionEligible: Bool

    public var severity: Severity { primary.severity }
}

/// Derives ride health. Priority for the primary message: position, then route,
/// then a required confirmation, then the dashboard, then voice.
public enum RideHealthEvaluator {
    public static let maxMeasurementAge: Duration = .seconds(5)
    public static let maxGuidanceAccuracy = 50.0

    public static func evaluate(_ input: RideHealthInput) -> RideHealth {
        var items: [RideHealth.Item] = []
        let riding = input.phase == .navigating

        let positionOK: Bool
        switch input.position {
        case .permissionDenied:
            positionOK = false
            items.append(.init(kind: .position, severity: .critical,
                               message: "Location access is off - directions stopped.", action: .openSettings))
        case .none:
            positionOK = false
            if riding {
                items.append(.init(kind: .position, severity: .critical,
                                   message: "No GPS position yet - directions paused.", action: nil))
            }
        case .measured(let age, let accuracy):
            if age >= maxMeasurementAge {
                positionOK = false
                if riding {
                    items.append(.init(kind: .position, severity: .critical,
                                       message: "GPS lost \(Int(age.seconds)) s ago - directions paused.", action: nil))
                }
            } else if accuracy > maxGuidanceAccuracy {
                positionOK = false
                if riding {
                    items.append(.init(kind: .position, severity: .warning,
                                       message: "GPS is imprecise (±\(Int(accuracy)) m) - directions paused.", action: nil))
                }
            } else {
                positionOK = true
            }
        }

        switch input.route {
        case .ok:
            break
        case .calculating:
            items.append(.init(kind: .route, severity: .info, message: "Calculating a route…", action: nil))
        case .failed(let reason):
            items.append(.init(kind: .route, severity: .critical, message: reason, action: .retryRoute))
        }
        if riding, input.navigationState == .rerouting {
            items.append(.init(kind: .route, severity: .warning, message: "Off route - finding a new route.", action: nil))
        }
        if riding, case .failed = input.navigationState {
            items.append(.init(kind: .route, severity: .critical, message: "Navigation stopped working.", action: .retryRoute))
        }

        switch input.phase {
        case .atStop:
            items.append(.init(kind: .confirmation, severity: .info,
                               message: "At your stop. Continue when you're ready.", action: .confirmLeg))
        case .recoveryOffered:
            items.append(.init(kind: .confirmation, severity: .info,
                               message: "A ride was interrupted. Resume or discard it.", action: .resumeRide))
        default:
            break
        }

        if riding {
            switch input.link {
            case .ready:
                switch input.delivery {
                case .deliveryUncertain:
                    items.append(.init(kind: .dashboard, severity: .warning,
                                       message: "Dashboard may be out of date - reconnecting.", action: nil))
                case .clearHandedOffWithoutResponse, .clearPending:
                    items.append(.init(kind: .dashboard, severity: .info,
                                       message: "Dashboard clearing (not yet confirmed by the bike).", action: nil))
                default:
                    break
                }
                if case .clear(.unsupportedManeuver) = input.intent, positionOK {
                    items.append(.init(kind: .dashboard, severity: .info,
                                       message: "The dashboard can't draw this turn - follow the phone.", action: nil))
                }
            case .connecting:
                items.append(.init(kind: .dashboard, severity: .warning,
                                   message: "Connecting to the bike - dashboard not updating.", action: nil))
            case .down, .notPaired:
                items.append(.init(kind: .dashboard, severity: .warning,
                                   message: "Bike not connected - follow the phone.", action: .reconnectBike))
            }

            if case .held(let reason) = input.voice {
                items.append(.init(kind: .voice, severity: .info, message: reason, action: .allowSpeaker))
            }
        }

        let order: [RideHealth.Kind] = [.position, .route, .confirmation, .dashboard, .voice]
        items.sort { a, b in
            let ia = order.firstIndex(of: a.kind) ?? 0, ib = order.firstIndex(of: b.kind) ?? 0
            return ia != ib ? ia < ib : a.severity > b.severity
        }

        // A failed reroute keeps the old route; it is usable again only when a fresh
        // position puts the rider back on it (the engine reports active).
        let stateAllows = input.navigationState == .active || input.navigationState == .arrived
        let eligible = riding && positionOK && stateAllows
        let primary = items.first ?? .init(kind: .route, severity: .ok,
                                           message: riding ? "Guidance is current." : "Ready.", action: nil)
        return RideHealth(primary: primary, items: items, directionEligible: eligible)
    }
}
