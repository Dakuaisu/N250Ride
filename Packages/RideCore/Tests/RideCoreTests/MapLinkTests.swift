import Foundation
import Testing
@testable import RideCore

@Suite("Map link parser")
struct MapLinkTests {
    func place(_ text: String) -> (Double, Double, String?)? {
        guard case .place(let c, let name) = MapLinkParser.parse(text) else { return nil }
        return (c.latitude, c.longitude, name)
    }

    @Test func appleMapsLinks() throws {
        let a = try #require(place("https://maps.apple.com/?ll=12.973240,77.591600&q=Cubbon%20Park"))
        #expect(a.0 == 12.97324 && a.1 == 77.5916 && a.2 == "Cubbon Park")
        let b = try #require(place("http://maps.apple.com/?daddr=13.01097,77.55526"))
        #expect(b.0 == 13.01097 && b.2 == nil)
        let c = try #require(place("Orion Mall\nhttps://maps.apple.com/place?coordinate=13.010970,77.555260&name=Orion"))
        #expect(c.0 == 13.01097)
    }

    @Test func googleMapsLinks() throws {
        let a = try #require(place("https://www.google.com/maps/place/Lalbagh+Botanical+Garden/@12.9507,77.5848,17z/data=!4m6!3m5!1s0x0:0x0!8m2!3d12.9498!4d77.5866"))
        #expect(a.0 == 12.9498 && a.1 == 77.5866, "the place pin wins over the camera position")
        #expect(a.2 == "Lalbagh Botanical Garden")
        let b = try #require(place("https://maps.google.com/?q=12.9716,77.5946"))
        #expect(b.0 == 12.9716 && b.1 == 77.5946)
        let c = try #require(place("https://www.google.com/maps/dir/?api=1&destination=12.9352,77.6245"))
        #expect(c.0 == 12.9352)
        let d = try #require(place("https://www.google.com/maps/@12.9716,77.5946,15z"))
        #expect(d.1 == 77.5946)
    }

    @Test func whatsAppLocationMessage() throws {
        let p = try #require(place("📍 Location: https://maps.google.com/maps?q=12.935200%2C77.624500&z=17&hl=en"))
        #expect(p.0 == 12.9352 && p.1 == 77.6245)
    }

    @Test func geoUris() throws {
        let a = try #require(place("geo:12.97,77.59"))
        #expect(a.0 == 12.97)
        let b = try #require(place("geo:0,0?q=12.95,77.58(Office)"))
        #expect(b.0 == 12.95 && b.2 == "Office")
        #expect(place("geo:0,0") == nil)
    }

    @Test func plainTextAndPlusCodes() throws {
        #expect(place("12.9716, 77.5946")?.0 == 12.9716)
        #expect(place("Meet at 12.97160, 77.59460 near the gate")?.1 == 77.5946)
        #expect(try #require(place("Pin: 7J4VWHC2+VG see you")).0 > 12)
    }

    @Test func shortLinksNeedExpansion() {
        #expect(MapLinkParser.parse("https://maps.app.goo.gl/AbCdEf123") == .needsExpansion(URL(string: "https://maps.app.goo.gl/AbCdEf123")!))
        #expect(MapLinkParser.parse("check https://goo.gl/maps/xyz") == .needsExpansion(URL(string: "https://goo.gl/maps/xyz")!))
    }

    @Test func rejectsNonLocations() {
        #expect(MapLinkParser.parse("") == nil)
        #expect(MapLinkParser.parse("hello there") == nil)
        #expect(MapLinkParser.parse("https://example.com/page?id=12") == nil)
        #expect(MapLinkParser.parse("https://maps.google.com/?q=95.0,77.0") == nil)
    }
}
