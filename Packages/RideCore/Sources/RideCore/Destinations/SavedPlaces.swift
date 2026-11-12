import Foundation

/// Home and Work shortcuts plus recent destinations. Stored on the phone only.
public struct SavedPlaces: Sendable, Equatable, Codable {
    public var home: Favourite?
    public var work: Favourite?
    public private(set) var recents: [Favourite] = []

    public static let maxRecents = 8
    /// Destinations closer than this count as the same place for recents.
    public static let samePlaceMetres = 75.0

    public init(home: Favourite? = nil, work: Favourite? = nil, recents: [Favourite] = []) {
        self.home = home
        self.work = work
        self.recents = recents
    }

    /// Most recent first; an earlier visit to the same spot moves to the top.
    public mutating func recordRecent(label: String, coordinate: Coordinate) {
        recents.removeAll { Self.distance($0.coordinate, coordinate) < Self.samePlaceMetres }
        recents.insert(Favourite(label: FavouritesList.normalised(label, fallback: coordinate), coordinate: coordinate),
                       at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }

    public mutating func clearRecents() {
        recents = []
    }

    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = (b.latitude - a.latitude) * 110_574
        let dLng = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }
}
