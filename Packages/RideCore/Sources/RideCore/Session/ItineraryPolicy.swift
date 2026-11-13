import Foundation

/// Pure transitions of a two-leg journey. Each returns the proposed next context;
/// the owner applies it only when the matching route change has been committed.
/// A stop is never skipped silently and its arrival never counts as the end.
public enum ItineraryPolicy {
    public enum Arrival: Sendable, Equatable {
        /// Leg one ended at the stop; the journey waits for an explicit Continue.
        case reachedStop(RideContext)
        /// The final destination: the journey is complete.
        case completed
        /// Not a leg end (e.g. a repeated arrival while already at the stop).
        case ignored
    }

    public enum Refusal: Error, Sendable, Equatable {
        case alreadyHasStop
        case noStop
        case wrongPhase
    }

    public static func arrival(_ context: RideContext) -> Arrival {
        switch context.phase {
        case .toStop:
            var next = context
            next.setPhase(.atStop)
            return .reachedStop(next)
        case .toFinal:
            return .completed
        case .atStop:
            return .ignored
        }
    }

    /// From the stop on to the final destination.
    public static func continueToFinal(_ context: RideContext) -> Result<RideContext, Refusal> {
        guard context.phase == .atStop else { return .failure(.wrongPhase) }
        var next = context
        next.setPhase(.toFinal)
        return .success(next)
    }

    /// Before reaching the stop: go straight to the final destination instead.
    public static func skipStop(_ context: RideContext) -> Result<RideContext, Refusal> {
        guard context.phase == .toStop else { return .failure(.wrongPhase) }
        var next = context
        next.setPhase(.toFinal)
        return .success(next)
    }

    /// Adds the one allowed stop to a journey heading for its final destination.
    public static func addStop(_ stop: RideDestination, to context: RideContext) -> Result<RideContext, Refusal> {
        guard context.itinerary.stop == nil else { return .failure(.alreadyHasStop) }
        guard context.phase == .toFinal else { return .failure(.wrongPhase) }
        var next = context
        next.setStop(stop)
        next.setPhase(.toStop)
        return .success(next)
    }
}
