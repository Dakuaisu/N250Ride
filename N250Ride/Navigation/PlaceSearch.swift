import CoreLocation
import MapKit
import Observation
import RideCore

/// Place search by name (landmarks, businesses, addresses) through Apple Maps.
/// Suggestions update while typing; choosing one resolves it to a coordinate.
/// Apple's terms require a result to be shown on an Apple map, which the
/// destination confirmation does.
@MainActor
@Observable
final class PlaceSearch: NSObject {
    struct Suggestion: Identifiable, Equatable {
        let id: Int
        let title: String
        let subtitle: String
    }

    var query = "" {
        didSet { updateQuery() }
    }
    private(set) var suggestions: [Suggestion] = []
    private(set) var isResolving = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let locationManager = CLLocationManager()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func clear() {
        query = ""
        suggestions = []
        completions = []
        errorMessage = nil
    }

    /// Resolves a suggestion to a named coordinate.
    func resolve(_ suggestion: Suggestion, completion: @escaping @MainActor (Coordinate, String) -> Void) {
        guard completions.indices.contains(suggestion.id) else { return }
        isResolving = true
        errorMessage = nil
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completions[suggestion.id]))
        search.start { response, _ in
            let item = response?.mapItems.first
            let name = item?.name ?? suggestion.title
            let point = item.map(Self.coordinate)
            MainActor.assumeIsolated {
                self.isResolving = false
                guard let point, let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude) else {
                    self.errorMessage = "Couldn't find that place. Try another result."
                    return
                }
                completion(coordinate, name)
            }
        }
    }

    nonisolated private static func coordinate(_ item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26, *) { return item.location.coordinate }
        return item.placemark.coordinate
    }

    private func updateQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        guard trimmed.count >= 2 else {
            completer.cancel()
            suggestions = []
            completions = []
            return
        }
        if let here = locationManager.location?.coordinate {
            completer.region = MKCoordinateRegion(center: here, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        completer.queryFragment = trimmed
    }

    private func publishResults() {
        completions = Array(completer.results.prefix(8))
        suggestions = completions.enumerated().map {
            Suggestion(id: $0.offset, title: $0.element.title, subtitle: $0.element.subtitle)
        }
    }
}

extension PlaceSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { publishResults() }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            suggestions = []
            completions = []
            errorMessage = "Search unavailable. Check your connection."
        }
    }
}
