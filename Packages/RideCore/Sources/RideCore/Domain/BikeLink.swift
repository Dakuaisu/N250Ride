/// Bluetooth link state. Independent of navigation: losing the bike never stops,
/// restarts or re-requests a route.
public enum BikeLinkState: Sendable, Equatable {
    case unavailable(BluetoothUnavailableReason)
    case idle
    case scanning
    case connecting
    case discovering
    case ready(ClusterLinkInfo)
    case reconnecting(attempt: Int)
    case failed(BikeLinkFailure)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum BluetoothUnavailableReason: Sendable, Equatable {
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
}

public enum BikeLinkFailure: Error, Sendable, Equatable {
    case serviceNotFound
    case characteristicNotFound(String)
    case characteristicNotWritable(String)
    /// The cluster's maximum write is smaller than a whole frame; frames are never fragmented.
    case writeLengthTooSmall(required: Int, available: Int)
    case connectTimeout
    case gaveUp(attempts: Int)
}

public enum WriteMode: Sendable, Equatable {
    case withResponse
    case withoutResponse
}

/// What discovery proved about the connected cluster.
public struct ClusterLinkInfo: Sendable, Equatable {
    public var navigationWriteMode: WriteMode
    public var statusWriteMode: WriteMode?
    public var maximumWriteLength: Int

    public init(navigationWriteMode: WriteMode, statusWriteMode: WriteMode?, maximumWriteLength: Int) {
        self.navigationWriteMode = navigationWriteMode
        self.statusWriteMode = statusWriteMode
        self.maximumWriteLength = maximumWriteLength
    }
}

/// Characteristic properties as reported by discovery, transport-agnostic.
public struct CharacteristicProperties: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let read = CharacteristicProperties(rawValue: 1 << 0)
    public static let write = CharacteristicProperties(rawValue: 1 << 1)
    public static let writeWithoutResponse = CharacteristicProperties(rawValue: 1 << 2)
    public static let notify = CharacteristicProperties(rawValue: 1 << 3)

    /// Prefer acknowledged writes; fall back to without-response only if that is all
    /// the characteristic offers.
    public var preferredWriteMode: WriteMode? {
        if contains(.write) { return .withResponse }
        if contains(.writeWithoutResponse) { return .withoutResponse }
        return nil
    }
}

public enum ClusterGATT {
    public static let service = "0010676E-6972-6565-6E69-676E4543544F"
    public static let navigation = "0110676E-6972-6565-6E69-676E4543544F"
    public static let generalStatus = "0210676E-6972-6565-6E69-676E4543544F"

    /// Validates discovered characteristics. Navigation is required; status is
    /// optional because its profile is unproven on the N250.
    public static func validate(
        serviceFound: Bool,
        navigation: CharacteristicProperties?,
        status: CharacteristicProperties?,
        maximumWriteLength: (WriteMode) -> Int
    ) -> Result<ClusterLinkInfo, BikeLinkFailure> {
        guard serviceFound else { return .failure(.serviceNotFound) }
        guard let navigation else { return .failure(.characteristicNotFound(ClusterGATT.navigation)) }
        guard let navMode = navigation.preferredWriteMode else {
            return .failure(.characteristicNotWritable(ClusterGATT.navigation))
        }
        let available = maximumWriteLength(navMode)
        guard available >= TbtFrame.length else {
            return .failure(.writeLengthTooSmall(required: TbtFrame.length, available: available))
        }
        return .success(ClusterLinkInfo(
            navigationWriteMode: navMode,
            statusWriteMode: status?.preferredWriteMode,
            maximumWriteLength: available
        ))
    }
}

/// Bounded reconnect backoff (upstream: 3 s steps capped at 15 s, 20 attempts).
public struct ReconnectPolicy: Sendable, Equatable {
    public var step: Duration
    public var cap: Duration
    public var maxAttempts: Int

    public init(step: Duration = .seconds(3), cap: Duration = .seconds(15), maxAttempts: Int = 20) {
        self.step = step
        self.cap = cap
        self.maxAttempts = maxAttempts
    }

    /// Delay before `attempt` (1-based), or nil once the policy gives up.
    public func delay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return min(step * attempt, cap)
    }
}
