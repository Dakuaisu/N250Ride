/// Rider choices applied to every route request and reroute.
public struct RoutePreferences: Equatable, Hashable, Codable, Sendable {
    public var avoidTolls: Bool
    public var avoidHighways: Bool

    public init(avoidTolls: Bool = false, avoidHighways: Bool = false) {
        self.avoidTolls = avoidTolls
        self.avoidHighways = avoidHighways
    }
}
