import Foundation
import Testing
@testable import RideCore

@Suite("Saved places")
struct SavedPlacesTests {
    let office = Coordinate(latitude: 12.9716, longitude: 77.5946)!
    let mall = Coordinate(latitude: 13.0110, longitude: 77.5553)!

    @Test func recentsAreMostRecentFirstAndDeduplicated() {
        var places = SavedPlaces()
        places.recordRecent(label: "Office", coordinate: office)
        places.recordRecent(label: "Orion Mall", coordinate: mall)
        places.recordRecent(label: "Office gate", coordinate: Coordinate(latitude: 12.9719, longitude: 77.5946)!)
        #expect(places.recents.map(\.label) == ["Office gate", "Orion Mall"])
    }

    @Test func recentsAreCapped() {
        var places = SavedPlaces()
        for i in 0..<12 {
            places.recordRecent(label: "P\(i)", coordinate: Coordinate(latitude: 12.9 + Double(i) * 0.01, longitude: 77.5)!)
        }
        #expect(places.recents.count == SavedPlaces.maxRecents)
        #expect(places.recents.first?.label == "P11")
    }

    @Test func homeWorkAndPersistence() throws {
        var places = SavedPlaces()
        places.home = Favourite(label: "Home", coordinate: office)
        places.work = Favourite(label: "Work", coordinate: mall)
        places.recordRecent(label: "", coordinate: mall)
        #expect(places.recents.first?.label == "13.01100, 77.55530")
        let decoded = try JSONDecoder().decode(SavedPlaces.self, from: JSONEncoder().encode(places))
        #expect(decoded == places)
        places.clearRecents()
        #expect(places.recents.isEmpty && places.home != nil)
    }
}
