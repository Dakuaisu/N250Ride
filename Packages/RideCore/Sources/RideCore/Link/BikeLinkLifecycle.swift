import Foundation

/// Which connection attempt owns the link. Every attempt (connect, reconnect,
/// switch to another bike) gets a new epoch; timers and callbacks carry the epoch
/// they were started under, and anything from an older epoch or another
/// peripheral has no effect.
public struct BikeLinkLifecycle: Sendable, Equatable {
    public private(set) var target: UUID?
    public private(set) var epoch = 0
    /// The epoch whose link passed GATT validation, if any.
    public private(set) var validatedEpoch: Int?

    public init() {}

    /// Starts an attempt on `peripheral`. Returns the previous target when the rider
    /// switched bikes, so its connection can be cancelled first.
    @discardableResult
    public mutating func begin(_ peripheral: UUID) -> (epoch: Int, replaced: UUID?) {
        let replaced = target.flatMap { $0 == peripheral ? nil : $0 }
        target = peripheral
        epoch += 1
        validatedEpoch = nil
        return (epoch, replaced)
    }

    /// The link is torn down; whatever was in flight belongs to the past.
    public mutating func retire() {
        epoch += 1
        validatedEpoch = nil
    }

    public mutating func forget() {
        retire()
        target = nil
    }

    public func owns(_ peripheral: UUID, epoch: Int) -> Bool {
        peripheral == target && epoch == self.epoch
    }

    public func isCurrent(_ peripheral: UUID) -> Bool { peripheral == target }

    /// Records a validated link; refused for a stale epoch.
    public mutating func validated(_ peripheral: UUID, epoch: Int) -> Bool {
        guard owns(peripheral, epoch: epoch) else { return false }
        validatedEpoch = epoch
        return true
    }
}
