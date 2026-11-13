import Foundation

/// A rider's logical journey. Survives an intermediate stop and an explicit resume;
/// each running leg still gets its own `SessionID`.
public struct RideID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }

    public var description: String { raw.uuidString }
}

/// Where a destination came from. Kept through confirmation so storage decisions
/// can depend on it.
public enum DestinationProvenance: String, Sendable, Codable, CaseIterable {
    case manual, saved, shared, mapSelection, searchResult, unknown
}

public struct RideDestination: Sendable, Hashable, Codable {
    public static let maxLabelLength = 60

    public let id: UUID
    public let coordinate: Coordinate
    public let label: String
    public let provenance: DestinationProvenance

    public init(id: UUID = UUID(), coordinate: Coordinate, label: String, provenance: DestinationProvenance) {
        self.id = id
        self.coordinate = coordinate
        self.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLabelLength))
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey { case id, coordinate, label, provenance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let label = try c.decode(String.self, forKey: .label)
        guard label.count <= Self.maxLabelLength else {
            throw DecodingError.dataCorruptedError(forKey: .label, in: c, debugDescription: "label too long")
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), coordinate: try c.decode(Coordinate.self, forKey: .coordinate),
                  label: label, provenance: try c.decode(DestinationProvenance.self, forKey: .provenance))
    }
}

/// A final destination and at most one stop on the way.
public struct Itinerary: Sendable, Hashable, Codable {
    public var stop: RideDestination?
    public var final: RideDestination

    public init(final: RideDestination, stop: RideDestination? = nil) {
        self.final = final
        self.stop = stop
    }
}

public enum LegPhase: String, Sendable, Hashable, Codable {
    case toStop, atStop, toFinal
}

/// The durable intent of one journey: which itinerary, which leg, which preferences.
public struct RideContext: Sendable, Hashable, Codable {
    public let id: RideID
    public private(set) var itinerary: Itinerary
    public private(set) var phase: LegPhase
    public var preferences: RoutePreferences

    public init?(id: RideID = RideID(), itinerary: Itinerary, phase: LegPhase? = nil,
                 preferences: RoutePreferences = RoutePreferences()) {
        let phase = phase ?? (itinerary.stop == nil ? .toFinal : .toStop)
        guard Self.isValid(phase, itinerary) else { return nil }
        self.id = id
        self.itinerary = itinerary
        self.phase = phase
        self.preferences = preferences
    }

    static func isValid(_ phase: LegPhase, _ itinerary: Itinerary) -> Bool {
        phase == .toFinal || itinerary.stop != nil
    }

    /// The destination of the leg being ridden or about to be ridden.
    public var activeTarget: RideDestination {
        switch phase {
        case .toStop: itinerary.stop ?? itinerary.final
        case .atStop, .toFinal: itinerary.final
        }
    }

    public var isFinalLeg: Bool { phase == .toFinal }

    mutating func setPhase(_ phase: LegPhase) {
        self.phase = phase
    }

    mutating func setStop(_ stop: RideDestination?) {
        itinerary.stop = stop
    }

    private enum CodingKeys: String, CodingKey { case id, itinerary, phase, preferences }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let itinerary = try c.decode(Itinerary.self, forKey: .itinerary)
        let phase = try c.decode(LegPhase.self, forKey: .phase)
        guard let context = RideContext(id: try c.decode(RideID.self, forKey: .id), itinerary: itinerary, phase: phase,
                                        preferences: try c.decode(RoutePreferences.self, forKey: .preferences)) else {
            throw DecodingError.dataCorruptedError(forKey: .phase, in: c, debugDescription: "phase needs a stop")
        }
        self = context
    }
}
