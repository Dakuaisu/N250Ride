public enum ClusterChannel: Sendable, Equatable {
    case navigation
    case status
}

/// The CoreBluetooth side of a write, abstracted so the pump runs against fakes.
public protocol ClusterWriteTransport: AnyObject {
    func maximumWriteLength(for mode: WriteMode) -> Int
    var canSendWriteWithoutResponse: Bool { get }
    func write(_ bytes: [UInt8], to channel: ClusterChannel, mode: WriteMode)
}

public enum ClusterWriteEvent: Sendable, Equatable {
    case rejectedTooLarge(ClusterChannel, size: Int, maximum: Int)
    case failed(ClusterChannel)
    case timedOut(ClusterChannel)
    /// The cluster acknowledged a clear frame (response writes only).
    case clearAcknowledged
    /// A clear frame was handed to the stack without acknowledgement.
    case clearHandedOff
    /// Too many consecutive failures; the link owner should reconnect.
    case unhealthy(consecutiveFailures: Int)
}

/// Serializes writes to the cluster with latest-value semantics.
///
/// - At most one acknowledged write is outstanding; the next waits for completion.
/// - Without-response writes honour the transport's readiness flag.
/// - Navigation keeps only the newest pending frame; a clear supersedes it and is
///   always sent before any newer frame. Status keeps only the newest packet.
/// - Nothing is fragmented: a payload above the write limit is rejected.
/// - `reset()` on link loss purges everything; a clear is never reported delivered
///   unless the cluster acknowledged it on the current link.
public final class ClusterWritePump {
    public var onEvent: ((ClusterWriteEvent) -> Void)?

    private let transport: ClusterWriteTransport
    private let clock: RideClock
    private let navigationMode: WriteMode
    private let statusMode: WriteMode?
    private let writeTimeout: Duration
    private let unhealthyThreshold: Int

    private var pendingClear = false
    private var pendingNavigation: [UInt8]?
    private var pendingStatus: [UInt8]?
    private var inFlight: (channel: ClusterChannel, isClear: Bool, startedAt: MonotonicInstant)?
    private var lastServed: ClusterChannel?
    private var consecutiveFailures = 0

    public init(
        transport: ClusterWriteTransport,
        clock: RideClock,
        link: ClusterLinkInfo,
        writeTimeout: Duration = .seconds(3),
        unhealthyThreshold: Int = 3
    ) {
        self.transport = transport
        self.clock = clock
        self.navigationMode = link.navigationWriteMode
        self.statusMode = link.statusWriteMode
        self.writeTimeout = writeTimeout
        self.unhealthyThreshold = unhealthyThreshold
    }

    public var isIdle: Bool {
        inFlight == nil && !pendingClear && pendingNavigation == nil && pendingStatus == nil
    }

    public var hasWriteInFlight: Bool { inFlight != nil }

    public func submitNavigation(_ frame: [UInt8]) {
        pendingNavigation = frame
        pump()
    }

    public func submitClear() {
        pendingNavigation = nil
        pendingClear = true
        pump()
    }

    /// Ignored when the cluster exposes no writable status characteristic.
    public func submitStatus(_ packet: [UInt8]) {
        guard statusMode != nil else { return }
        pendingStatus = packet
        pump()
    }

    /// Completion of an acknowledged write on the current link.
    public func didCompleteWrite(on channel: ClusterChannel, success: Bool) {
        guard let current = inFlight, current.channel == channel else { return }
        inFlight = nil
        if success {
            consecutiveFailures = 0
            if current.isClear { onEvent?(.clearAcknowledged) }
        } else {
            recordFailure(.failed(channel))
        }
        pump()
    }

    /// CoreBluetooth signalled readiness for more without-response writes.
    public func transportReadyForWriteWithoutResponse() {
        pump()
    }

    /// Times out a stuck acknowledged write; call periodically.
    public func tick() {
        guard let current = inFlight, clock.now.duration(since: current.startedAt) >= writeTimeout else { return }
        inFlight = nil
        recordFailure(.timedOut(current.channel))
        pump()
    }

    /// Link lost: drop all queued and in-flight work. Late completions are ignored.
    public func reset() {
        pendingClear = false
        pendingNavigation = nil
        pendingStatus = nil
        inFlight = nil
        lastServed = nil
        consecutiveFailures = 0
    }

    private func recordFailure(_ event: ClusterWriteEvent) {
        consecutiveFailures += 1
        onEvent?(event)
        if consecutiveFailures == unhealthyThreshold {
            onEvent?(.unhealthy(consecutiveFailures: consecutiveFailures))
        }
    }

    private func pump() {
        while inFlight == nil, let next = nextWrite() {
            let mode = next.channel == .navigation ? navigationMode : (statusMode ?? .withResponse)
            if mode == .withoutResponse, !transport.canSendWriteWithoutResponse { return }
            take(next)
            let maximum = transport.maximumWriteLength(for: mode)
            guard next.bytes.count <= maximum else {
                onEvent?(.rejectedTooLarge(next.channel, size: next.bytes.count, maximum: maximum))
                continue
            }
            lastServed = next.channel
            transport.write(next.bytes, to: next.channel, mode: mode)
            if mode == .withResponse {
                inFlight = (next.channel, next.isClear, clock.now)
            } else if next.isClear {
                onEvent?(.clearHandedOff)
            }
        }
    }

    private struct Write {
        var channel: ClusterChannel
        var bytes: [UInt8]
        var isClear: Bool
    }

    private func nextWrite() -> Write? {
        if pendingClear {
            return Write(channel: .navigation, bytes: TbtFrame.stop(), isClear: true)
        }
        let status = pendingStatus.map { Write(channel: .status, bytes: $0, isClear: false) }
        let navigation = pendingNavigation.map { Write(channel: .navigation, bytes: $0, isClear: false) }
        // Alternate when both are waiting so a steady navigation stream cannot starve status.
        if let status, navigation == nil || lastServed == .navigation { return status }
        return navigation
    }

    private func take(_ write: Write) {
        switch write.channel {
        case .navigation where write.isClear: pendingClear = false
        case .navigation: pendingNavigation = nil
        case .status: pendingStatus = nil
        }
    }
}
