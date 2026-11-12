import Foundation

/// A destination extracted from a shared map link or text.
public enum MapLinkResult: Sendable, Equatable {
    case place(Coordinate, name: String?)
    /// A shortened link (e.g. maps.app.goo.gl) that must be expanded by following
    /// its redirect before it can be parsed.
    case needsExpansion(URL)
}

/// Reads destinations from what other apps share: Apple Maps and Google Maps links,
/// `geo:` URIs, WhatsApp location messages, plain `lat,lng` and full plus codes.
/// Nothing is looked up online except expanding short links (done by the caller).
public enum MapLinkParser {
    static let shortLinkHosts: Set<String> = ["maps.app.goo.gl", "goo.gl", "g.co", "maps.apple"]

    public static func parse(_ text: String) -> MapLinkResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for url in urls(in: trimmed) {
            if let result = parse(url: url) { return result }
        }
        if case .success(let coordinate) = DestinationInputParser.parse(trimmed) {
            return .place(coordinate, name: nil)
        }
        if let match = trimmed.firstMatch(of: /(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})/),
           let coordinate = coordinate(String(match.1), String(match.2)) {
            return .place(coordinate, name: nil)
        }
        for token in trimmed.split(whereSeparator: \.isWhitespace) where token.contains("+") {
            if OpenLocationCode.isFull(String(token)),
               case .success(let coordinate) = DestinationInputParser.parse(String(token)) {
                return .place(coordinate, name: nil)
            }
        }
        return nil
    }

    public static func parse(url: URL) -> MapLinkResult? {
        if url.scheme?.lowercased() == "geo" { return geo(url) }
        guard let host = url.host?.lowercased() else { return nil }
        if shortLinkHosts.contains(host) || (host == "goo.gl" && url.path.hasPrefix("/maps")) {
            return .needsExpansion(url)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name.lowercased(), $0) }
        }, uniquingKeysWith: { first, _ in first })

        if host.hasSuffix("maps.apple.com") || host == "maps.apple" {
            let name = query["q"].flatMap { coordinateText($0) == nil ? $0 : nil }
            for key in ["ll", "daddr", "coordinate", "sll", "q"] {
                if let value = query[key], let coordinate = coordinateText(value) {
                    return .place(coordinate, name: name)
                }
            }
            return nil
        }

        if host.contains("google.") {
            if let match = url.absoluteString.firstMatch(of: /!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/),
               let coordinate = coordinate(String(match.1), String(match.2)) {
                return .place(coordinate, name: googlePlaceName(url))
            }
            for key in ["destination", "daddr", "q", "query", "ll", "center"] {
                if let value = query[key], let coordinate = coordinateText(value) {
                    return .place(coordinate, name: googlePlaceName(url))
                }
            }
            if let match = url.absoluteString.firstMatch(of: /@(-?\d+\.\d+),(-?\d+\.\d+)/),
               let coordinate = coordinate(String(match.1), String(match.2)) {
                return .place(coordinate, name: googlePlaceName(url))
            }
        }
        return nil
    }

    /// `geo:12.97,77.59` or `geo:0,0?q=12.97,77.59(Office)`.
    private static func geo(_ url: URL) -> MapLinkResult? {
        let body = String(url.absoluteString.dropFirst("geo:".count))
        let parts = body.split(separator: "?", maxSplits: 1).map(String.init)
        let q = parts.count > 1
            ? URLComponents(string: "x:?" + parts[1])?.queryItems?.first { $0.name == "q" }?.value : nil
        let name = q.flatMap { $0.firstMatch(of: /\(([^)]+)\)/).map { String($0.1) } }
        let point = parts.first?.split(separator: ";").first.map(String.init) ?? ""
        if let coordinate = coordinateText(point), coordinate.latitude != 0 || coordinate.longitude != 0 {
            return .place(coordinate, name: name)
        }
        if let q, let coordinate = coordinateText(q) { return .place(coordinate, name: name) }
        return nil
    }

    private static func googlePlaceName(_ url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "place"), index + 1 < parts.count else { return nil }
        let raw = parts[index + 1].replacingOccurrences(of: "+", with: " ")
        let name = raw.removingPercentEncoding ?? raw
        return name.isEmpty || coordinateText(name) != nil ? nil : name
    }

    /// "12.97,77.59" possibly followed by "(Label)" or other text.
    public static func coordinateText(_ value: String) -> Coordinate? {
        guard let match = value.firstMatch(of: /^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)/) else { return nil }
        return coordinate(String(match.1), String(match.2))
    }

    private static func coordinate(_ lat: String, _ lng: String) -> Coordinate? {
        guard let latitude = Double(lat), let longitude = Double(lng) else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    private static func urls(in text: String) -> [URL] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            var candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            if candidate.hasPrefix("(") { candidate.removeFirst() }
            if candidate.hasSuffix(")"), !candidate.contains("(") { candidate.removeLast() }
            guard candidate.hasPrefix("http") || candidate.lowercased().hasPrefix("geo:") else { return nil }
            return URL(string: candidate)
        }
    }
}
