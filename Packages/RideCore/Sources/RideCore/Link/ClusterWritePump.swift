public enum ClusterChannel: Sendable, Hashable {
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
/// - A clear that fails is sent again unless newer guidance replaced it; repeated
///   failures end in `.unhealthy`, and the owner reconnects.
/// - After an acknowledged write times out, which answer belongs to which write is
///   no longer knowable: the pump stalls (sends nothing more, credits no answer)
///   and the owner retires the link. The new link clears before anything else.
/// - `clearAcknowledged` is reported only for the latest clear: an answer for a
///   clear that a newer clear already superseded proves nothing.
public final class ClusterWritePump {
    public var onEvent: ((ClusterWriteEvent) -> Void)?
    /// Called whenever a write completed or more writes became possible, so the
    /// owner can reschedule its next deadline.
    public var onProgress: (() -> Void)?
    /// True while another owner (the bench console) is waiting for an answer on that
    /// channel: the pump writes nothing there until it is released, so answers never interleave.
    public var isChannelHeld: ((ClusterChannel) -> Bool)?

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
    /// Set by a write timeout; the link must be replaced.
    public private(set) var stalled = false

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

    /// When the outstanding acknowledged write times out, if one is outstanding.
    public var nextDeadline: MonotonicInstant? {
        inFlight.map { $0.startedAt + writeTimeout }
    }

    public var hasWriteInFlight: Bool { inFlight != nil }

    /// The channel whose acknowledged write is outstanding, if any.
    public var inFlightChannel: ClusterChannel? { inFlight?.channel }

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
        guard !stalled, let current = inFlight, current.channel == channel else { return }
        inFlight = nil
        if success {
            consecutiveFailures = 0
            if current.isClear, !pendingClear { onEvent?(.clearAcknowledged) }
        } else {
            retryIfClear(current.isClear)
            recordFailure(.failed(channel))
        }
        pump()
        onProgress?()
    }

    /// CoreBluetooth signalled readiness for more without-response writes.
    public func transportReadyForWriteWithoutResponse() {
        pump()
        onProgress?()
    }

    /// Another owner's write on a channel was answered: queued work may go now.
    public func channelReleased() {
        pump()
        onProgress?()
    }

    /// Times out a stuck acknowledged write; call periodically.
    public func tick() {
        guard !stalled, let current = inFlight,
              clock.now.duration(since: current.startedAt) >= writeTimeout else { return }
        inFlight = nil
        stalled = true
        retryIfClear(current.isClear)
        recordFailure(.timedOut(current.channel))
    }

    /// Link lost: drop all queued and in-flight work. Late completions are ignored.
    public func reset() {
        pendingClear = false
        pendingNavigation = nil
        pendingStatus = nil
        inFlight = nil
        lastServed = nil
        consecutiveFailures = 0
        stalled = true
    }

    private func retryIfClear(_ isClear: Bool) {
        if isClear, pendingNavigation == nil { pendingClear = true }
    }

    private func recordFailure(_ event: ClusterWriteEvent) {
        consecutiveFailures += 1
        onEvent?(event)
        if consecutiveFailures == unhealthyThreshold {
            onEvent?(.unhealthy(consecutiveFailures: consecutiveFailures))
        }
    }

    private func pump() {
        while !stalled, inFlight == nil, let next = nextWrite() {
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
        let navigationHeld = isChannelHeld?(.navigation) ?? false
        let statusHeld = isChannelHeld?(.status) ?? false
        if pendingClear {
            if !navigationHeld { return Write(channel: .navigation, bytes: TbtFrame.stop(), isClear: true) }
            // Nothing newer may overtake a waiting clear on navigation; status can still go.
            return statusHeld ? nil : pendingStatus.map { Write(channel: .status, bytes: $0, isClear: false) }
        }
        let status = statusHeld ? nil : pendingStatus.map { Write(channel: .status, bytes: $0, isClear: false) }
        let navigation = navigationHeld ? nil : pendingNavigation.map { Write(channel: .navigation, bytes: $0, isClear: false) }
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
