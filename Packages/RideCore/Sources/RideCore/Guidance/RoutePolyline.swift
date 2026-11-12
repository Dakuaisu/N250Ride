import Foundation

/// A route line in a local metric frame (equirectangular around its first point),
/// accurate to well under a metre over city-scale routes. Positions along the line
/// are metres from its start.
struct RoutePolyline: Sendable {
    let length: Double
    private let xy: [SIMD2<Double>]
    private let cumulative: [Double]
    private let originLatitude: Double
    private let originLongitude: Double
    private let metresPerDegreeLongitude: Double
    private static let metresPerDegreeLatitude = 110_574.0

    init?(_ points: [Coordinate]) {
        guard let first = points.first else { return nil }
        originLatitude = first.latitude
        originLongitude = first.longitude
        metresPerDegreeLongitude = cos(first.latitude * .pi / 180) * 111_320
        var xy: [SIMD2<Double>] = []
        var cumulative: [Double] = []
        for point in points {
            let p = SIMD2(
                (point.longitude - first.longitude) * metresPerDegreeLongitude,
                (point.latitude - first.latitude) * Self.metresPerDegreeLatitude
            )
            if let last = xy.last {
                let step = Self.length(p - last)
                guard step > 0.01 else { continue }
                cumulative.append(cumulative[cumulative.count - 1] + step)
            } else {
                cumulative.append(0)
            }
            xy.append(p)
        }
        guard xy.count >= 2 else { return nil }
        self.xy = xy
        self.cumulative = cumulative
        length = cumulative[cumulative.count - 1]
    }

    func local(_ c: Coordinate) -> SIMD2<Double> {
        SIMD2((c.longitude - originLongitude) * metresPerDegreeLongitude,
              (c.latitude - originLatitude) * Self.metresPerDegreeLatitude)
    }

    /// Closest point to `c` on the part of the line between `lower` and `upper` metres.
    func project(_ c: Coordinate, within lower: Double, _ upper: Double) -> (along: Double, offset: Double)? {
        let p = local(c)
        var best: (along: Double, offset: Double)?
        for i in 0..<(xy.count - 1) where cumulative[i + 1] >= lower && cumulative[i] <= upper {
            let a = xy[i], ab = xy[i + 1] - a
            let segment = cumulative[i + 1] - cumulative[i]
            let t = min(max(Self.dot(p - a, ab) / (segment * segment), 0), 1)
            let along = cumulative[i] + t * segment
            guard along >= lower, along <= upper else { continue }
            let offset = Self.length(p - (a + ab * t))
            if best == nil || offset < best!.offset { best = (along, offset) }
        }
        return best
    }

    func point(at along: Double) -> SIMD2<Double> {
        let d = min(max(along, 0), length)
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        let span = cumulative[hi] - cumulative[lo]
        let t = span > 0 ? (d - cumulative[lo]) / span : 0
        return xy[lo] + (xy[hi] - xy[lo]) * t
    }

    /// Compass bearing (degrees clockwise from north) from one position to another.
    func bearing(from a: Double, to b: Double) -> Double? {
        let v = point(at: b) - point(at: a)
        guard Self.length(v) > 1 else { return nil }
        let degrees = atan2(v.x, v.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Signed turn from one bearing to another, (-180, 180], positive = right.
    static func turn(from incoming: Double, to outgoing: Double) -> Double {
        var d = (outgoing - incoming).truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    private static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
    private static func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
}
