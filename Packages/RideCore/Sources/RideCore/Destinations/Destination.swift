import Foundation

public struct Coordinate: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey { case latitude, longitude }

    /// Decoding goes through the same range checks as the initializer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try c.decode(Double.self, forKey: .latitude)
        let longitude = try c.decode(Double.self, forKey: .longitude)
        guard let valid = Coordinate(latitude: latitude, longitude: longitude) else {
            throw DecodingError.dataCorruptedError(forKey: .latitude, in: c, debugDescription: "coordinate out of range")
        }
        self = valid
    }

    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = p2 - p1, dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

public enum DestinationParseError: Error, Sendable, Equatable {
    case empty
    case malformed
    case latitudeOutOfRange
    case longitudeOutOfRange
    /// Short plus codes need a reference location / geocoding, which the app does not use.
    case shortPlusCode
    case invalidPlusCode
}

/// Parses pasted destinations on-device: `lat,lng` or a full plus code.
public enum DestinationInputParser {
    public static func parse(_ input: String) -> Result<Coordinate, DestinationParseError> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if text.contains("+") { return parsePlusCode(text) }
        return parseLatLng(text)
    }

    private static func parseLatLng(_ text: String) -> Result<Coordinate, DestinationParseError> {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let lat = decimal(parts[0]), let lng = decimal(parts[1]) else { return .failure(.malformed) }
        guard (-90...90).contains(lat) else { return .failure(.latitudeOutOfRange) }
        guard (-180...180).contains(lng) else { return .failure(.longitudeOutOfRange) }
        return Coordinate(latitude: lat, longitude: lng).map { .success($0) } ?? .failure(.malformed)
    }

    /// Plain decimal degrees only: no exponents, hex, `inf` or `nan` that Double(_:) would accept.
    private static func decimal(_ s: String) -> Double? {
        guard s.wholeMatch(of: /[+-]?(\d+(\.\d*)?|\.\d+)/) != nil else { return nil }
        return Double(s)
    }

    private static func parsePlusCode(_ text: String) -> Result<Coordinate, DestinationParseError> {
        guard OpenLocationCode.isValid(text) else { return .failure(.invalidPlusCode) }
        guard OpenLocationCode.isFull(text) else { return .failure(.shortPlusCode) }
        guard let area = OpenLocationCode.decode(text),
              let centre = Coordinate(latitude: min(area.centerLatitude, 90), longitude: area.centerLongitude)
        else { return .failure(.invalidPlusCode) }
        return .success(centre)
    }
}

/// Port of the Open Location Code reference decoder (google/open-location-code,
/// Apache-2.0, Java implementation): validity rules and integer decoding.
public enum OpenLocationCode {
    public struct CodeArea: Sendable, Equatable {
        public var latitudeLo: Double
        public var longitudeLo: Double
        public var latitudeHi: Double
        public var longitudeHi: Double
        public var length: Int

        public var centerLatitude: Double { (latitudeLo + latitudeHi) / 2 }
        public var centerLongitude: Double { (longitudeLo + longitudeHi) / 2 }
    }

    private static let alphabet = Array("23456789CFGHJMPQRVWX")
    private static let separator: Character = "+"
    private static let padding: Character = "0"
    private static let separatorPosition = 8
    private static let pairCodeLength = 10
    private static let maxDigitCount = 15
    private static let base: Int64 = 20
    private static let gridColumns: Int64 = 4
    private static let gridRows: Int64 = 5
    private static let latIntegerMultiplier: Int64 = 8000 * 3125
    private static let lngIntegerMultiplier: Int64 = 8000 * 1024

    private static func digit(_ c: Character) -> Int? {
        alphabet.firstIndex(of: c)
    }

    public static func isValid(_ input: String) -> Bool {
        let code = Array(input.uppercased())
        guard code.count >= 2,
              let sep = code.firstIndex(of: separator),
              sep == code.lastIndex(of: separator),
              sep % 2 == 0, sep <= separatorPosition else { return false }

        if sep == separatorPosition {
            guard let first = digit(code[0]), first <= 8,
                  let second = digit(code[1]), second <= 17 else { return false }
        }

        var paddingStarted = false
        for i in 0..<sep {
            let c = code[i]
            guard digit(c) != nil || c == padding else { return false }
            if paddingStarted {
                guard c == padding else { return false }
            } else if c == padding {
                paddingStarted = true
                guard sep == separatorPosition, [2, 4, 6].contains(i) else { return false }
            }
        }

        if code.count > sep + 1 {
            guard !paddingStarted, code.count != sep + 2 else { return false }
            for c in code[(sep + 1)...] where digit(c) == nil { return false }
        }
        return true
    }

    public static func isFull(_ code: String) -> Bool {
        isValid(code) && code.firstIndex(of: separator).map { code.distance(from: code.startIndex, to: $0) } == separatorPosition
    }

    public static func isShort(_ code: String) -> Bool {
        isValid(code) && !isFull(code)
    }

    public static func decode(_ code: String) -> CodeArea? {
        guard isFull(code) else { return nil }
        let clean = code.uppercased().filter { $0 != separator && $0 != padding }.map { digit($0) ?? 0 }

        var latVal = -90 * latIntegerMultiplier
        var lngVal = -180 * lngIntegerMultiplier
        var latPlace = latIntegerMultiplier * base * base
        var lngPlace = lngIntegerMultiplier * base * base
        for i in stride(from: 0, to: min(clean.count, pairCodeLength), by: 2) {
            latPlace /= base
            lngPlace /= base
            latVal += Int64(clean[i]) * latPlace
            lngVal += Int64(clean[i + 1]) * lngPlace
        }
        if clean.count > pairCodeLength {
            for i in pairCodeLength..<min(clean.count, maxDigitCount) {
                latPlace /= gridRows
                lngPlace /= gridColumns
                let d = Int64(clean[i])
                latVal += (d / gridColumns) * latPlace
                lngVal += (d % gridColumns) * lngPlace
            }
        }
        return CodeArea(
            latitudeLo: Double(latVal) / Double(latIntegerMultiplier),
            longitudeLo: Double(lngVal) / Double(lngIntegerMultiplier),
            latitudeHi: Double(latVal + latPlace) / Double(latIntegerMultiplier),
            longitudeHi: Double(lngVal + lngPlace) / Double(lngIntegerMultiplier),
            length: min(clean.count, maxDigitCount)
        )
    }
}

/// A destination the rider saved locally. Never synced anywhere.
public struct Favourite: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var label: String
    public var coordinate: Coordinate

    public init(id: UUID = UUID(), label: String, coordinate: Coordinate) {
        self.id = id
        self.label = label
        self.coordinate = coordinate
    }
}

public struct FavouritesList: Sendable, Equatable, Codable {
    public private(set) var items: [Favourite] = []

    public init(items: [Favourite] = []) {
        self.items = items
    }

    public static let maxLabelLength = 60

    @discardableResult
    public mutating func add(label: String, coordinate: Coordinate) -> Favourite {
        let favourite = Favourite(label: Self.normalised(label, fallback: coordinate), coordinate: coordinate)
        items.append(favourite)
        return favourite
    }

    public mutating func rename(_ id: UUID, to label: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].label = Self.normalised(label, fallback: items[index].coordinate)
    }

    public mutating func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    static func normalised(_ label: String, fallback: Coordinate) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(format: "%.5f, %.5f", fallback.latitude, fallback.longitude)
        }
        return String(trimmed.prefix(maxLabelLength))
    }
}
