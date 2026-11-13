import Foundation

/// Decides who owns an acknowledged-write completion on the cluster link.
///
/// Bluetooth reports only the characteristic and an error, never which request it
/// answers. Answers on one characteristic arrive in request order, so console
/// (raw) writes are kept as a FIFO per characteristic, and a raw write is refused
/// while the app's own write on the same channel is outstanding, so the two never
/// share one queue of answers. Completions for characteristics the app writes to
/// itself go to the pump; anything else that nobody asked for is dropped.
public struct WriteCompletionRouter: Sendable, Equatable {
    public enum Owner: Sendable, Equatable {
        case raw(id: Int)
        case pump(ClusterChannel)
        case none
    }

    public enum Refusal: Error, Sendable, Equatable {
        /// The app's own write on this channel hasn't been answered yet.
        case channelBusy
    }

    private var raw: [String: [Int]] = [:]
    private var nextID = 0

    public init() {}

    /// The pump's channel for a characteristic, nil if the app never writes to it.
    public static func channel(_ characteristic: String) -> ClusterChannel? {
        switch characteristic.uppercased() {
        case ClusterGATT.navigation: .navigation
        case ClusterGATT.generalStatus: .status
        default: nil
        }
    }

    /// Registers an acknowledged raw write and returns its id.
    public mutating func beginRaw(_ characteristic: String, pumpBusyOn busy: ClusterChannel?) -> Result<Int, Refusal> {
        let key = characteristic.uppercased()
        if let channel = Self.channel(key), channel == busy { return .failure(.channelBusy) }
        nextID += 1
        raw[key, default: []].append(nextID)
        return .success(nextID)
    }

    public func hasRawPending(on characteristic: String) -> Bool {
        !(raw[characteristic.uppercased()] ?? []).isEmpty
    }

    public mutating func complete(_ characteristic: String) -> Owner {
        let key = characteristic.uppercased()
        if var queue = raw[key], !queue.isEmpty {
            let id = queue.removeFirst()
            raw[key] = queue.isEmpty ? nil : queue
            return .raw(id: id)
        }
        return Self.channel(key).map { .pump($0) } ?? .none
    }

    /// The link went away: nothing outstanding belongs to anyone any more.
    public mutating func reset() {
        raw = [:]
    }
}
