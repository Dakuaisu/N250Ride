import CoreLocation
import Foundation
import RideCore
import Testing
import UIKit
@testable import N250Ride

/// Spy provider: counts requests and lets the test decide when they complete.
@MainActor
final class SpyProvider: LiveNavigationProvider {
    var onSnapshot: ((NavigationSnapshot) -> Void)?
    var onLongPress: ((Coordinate) -> Void)?
    var onRerouteNeeded: (() -> Void)?
    var routePreferences = RoutePreferences()
    let name = "Spy"
    let routingLabel = "Spy route"
    let termsNotice = "notice"
    var termsAccepted = true
    let sdkVersion: String? = nil
    let mapHostView = UIView()

    var routeRequests = 0
    var rerouteRequests: [RouteGeneration] = []
    var pendingRoute: ((Result<[RouteOption], RouteRequestFailure>) -> Void)?
    var pendingReroute: ((Result<Void, RouteRequestFailure>) -> Void)?
    var selected: [RouteOption.ID] = []
    var started = 0
    let options = [
        RouteOption(id: 0, name: "Outer Ring Road", distanceMetres: 5_400, expectedSeconds: 1_200, hasTolls: false, hasHighways: true),
        RouteOption(id: 2, name: "Old Airport Road", distanceMetres: 5_100, expectedSeconds: 1_380, hasTolls: false, hasHighways: false),
    ]

    func requestTerms(completion: @escaping @MainActor (Bool) -> Void) { completion(true) }
    func requestRoute(to destination: Coordinate, title: String, session: SessionID, generation: RouteGeneration,
                      completion: @escaping @MainActor (Result<[RouteOption], RouteRequestFailure>) -> Void) {
        routeRequests += 1
        pendingRoute = completion
    }
    func selectRoute(_ id: RouteOption.ID) -> Bool {
        selected.append(id)
        return true
    }
    func recenter() {}
    func reroute(session: SessionID, generation: RouteGeneration,
                 completion: @escaping @MainActor (Result<Void, RouteRequestFailure>) -> Void) {
        rerouteRequests.append(generation)
        pendingReroute = completion
    }
    func startGuidance() { started += 1 }
    func stop() {}
}

@MainActor
struct AppModelProviderTests {
    let spy = SpyProvider()
    let model: AppModel
    let destination = Coordinate(latitude: 12.9716, longitude: 77.5946)!

    init() {
        let defaults = UserDefaults(suiteName: "AppModelProviderTests-\(UUID())")!
        model = AppModel(configuration: AppConfiguration(navigationProvider: .apple, googleAPIKey: nil,
                                                         liveNavigationAuthorized: false, provenStatusProfile: nil),
                         defaults: defaults, provider: spy)
        model.locationAuthorization = { .authorizedWhenInUse }
    }

    @Test func repeatedConfirmsAndScreenChangesSendOneRequest() {
        model.propose(destination)
        model.confirmDestination(label: "Office", saveAsFavourite: false)
        model.confirmDestination(label: "Office", saveAsFavourite: false)
        model.propose(destination)
        #expect(spy.routeRequests == 1)
        spy.pendingRoute?(.success(spy.options))
        model.startNavigation()
        model.startNavigation()
        #expect(spy.started == 1)
        #expect(spy.routeRequests == 1)
    }

    @Test func rerouteRightAfterTheRouteIsDebounced() {
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.success(spy.options))
        model.startNavigation()
        spy.onRerouteNeeded?()
        #expect(spy.rerouteRequests.isEmpty)
    }

    @Test func reroutesAreSerialisedAndUseTheNextGeneration() async throws {
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.success(spy.options))
        model.startNavigation()
        try await Task.sleep(for: .milliseconds(2_100))
        spy.onRerouteNeeded?()
        spy.onRerouteNeeded?()
        #expect(spy.rerouteRequests == [RouteGeneration(1)], "second reroute coalesces while one is in flight")
        spy.pendingReroute?(.success(()))
        #expect(spy.routeRequests == 1)
    }

    @Test func failedRouteIsNotRetriedAutomatically() {
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.failure(.network))
        guard case .failed = model.stage else {
            Issue.record("expected failed stage, got \(model.stage)")
            return
        }
        #expect(spy.routeRequests == 1)
    }

    @Test func simulationModeNeverCallsTheProvider() {
        model.setSimulationMode(true)
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        model.startNavigation()
        #expect(spy.routeRequests == 0)
        #expect(spy.started == 0)
        model.stopNavigation()
    }

    @Test func noticeMustBeAcceptedAndLocationAllowed() {
        spy.termsAccepted = false
        let defaults = UserDefaults(suiteName: "AppModelProviderTests-terms-\(UUID())")!
        let gated = AppModel(configuration: AppConfiguration(navigationProvider: .apple, googleAPIKey: nil,
                                                             liveNavigationAuthorized: false, provenStatusProfile: nil),
                             defaults: defaults, provider: spy)
        gated.locationAuthorization = { .denied }
        gated.propose(destination)
        gated.confirmDestination(label: "", saveAsFavourite: false)
        gated.acceptTerms()
        gated.retry()
        gated.confirmDestination(label: "", saveAsFavourite: false)
        #expect(spy.routeRequests == 0)
    }

    @Test func choosingBetweenRoutesSendsNoNewRequest() {
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.success(spy.options))
        #expect(model.routeOptions == spy.options)
        #expect(model.selectedRouteID == 0)
        model.selectRoute(2)
        model.selectRoute(99)
        #expect(model.selectedRouteID == 2)
        #expect(spy.selected == [2])
        model.startNavigation()
        model.selectRoute(0)
        #expect(spy.selected == [2], "no switching once guidance has started")
        #expect(spy.routeRequests == 1)
    }

    @Test func customStatusValuesValidateRawBytes() {
        model.customRawBytes = "13=2, 17=0x01"
        #expect(model.customRawBytesError == nil)
        model.customRawBytes = "13=300"
        #expect(model.customRawBytesError != nil)
    }

    @Test func routePreferencesReachTheProvider() {
        model.routePreferences.avoidTolls = true
        #expect(spy.routePreferences.avoidTolls)
        #expect(!spy.routePreferences.avoidHighways)
    }

    @Test func homeIsOneTapAndRecentsAreRecorded() {
        model.setShortcut(.home, label: "", coordinate: destination)
        let home = try! #require(model.places.home)
        #expect(home.label == "Home")
        model.navigate(to: home)
        #expect(spy.routeRequests == 1)
        #expect(model.places.recents.first?.label == "Home")
    }

    @Test func sharedLinksProposeTheDestination() {
        model.handleIncoming("Lalbagh https://maps.apple.com/?ll=12.9498,77.5866&q=Lalbagh")
        guard case .confirming(let pending) = model.stage else {
            Issue.record("expected confirmation, got \(model.stage)")
            return
        }
        #expect(pending.label == "Lalbagh" && pending.coordinate.latitude == 12.9498)
        #expect(spy.routeRequests == 0, "a shared link never requests a route by itself")
        model.cancelDestination()
        model.handleIncoming("nothing here")
        #expect(model.linkMessage == "No location found in what was shared.")
        model.handleOpenURL(URL(string: "n250ride://open?ll=12.95,77.58&name=Office%20Gate")!)
        guard case .confirming(let fromURL) = model.stage else {
            Issue.record("expected confirmation from URL")
            return
        }
        #expect(fromURL.label == "Office Gate")
    }

    @Test func openRouteExplainsTheLockAndCanBeClosed() {
        #expect(model.diagnosticsLockReason == nil)
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.success(spy.options))
        #expect(model.diagnosticsLockReason == "A route is open on the Ride tab (Choose a route).")
        #expect(model.clearTestFrame() == "A route is open on the Ride tab (Choose a route).")
        #expect(model.sendConsoleFrame(TbtFrame.stop()) == "A route is open on the Ride tab (Choose a route).")
        model.console.clearDashboard()
        #expect(model.console.entries.first?.text == "Refused: A route is open on the Ride tab (Choose a route).")
        model.endRideForDiagnostics()
        #expect(model.diagnosticsLockReason == nil)
        #expect(model.clearTestFrame() == nil)
    }

    @Test func emptyButtonChannelReadsAreReportedOnce() {
        let control = BluetoothConsole.controlChannel
        model.bike.onConsoleEvent?(.read(characteristic: control, bytes: [], error: nil))
        model.bike.onConsoleEvent?(.read(characteristic: control, bytes: [], error: nil))
        model.bike.onConsoleEvent?(.read(characteristic: control, bytes: nil, error: nil))
        #expect(model.console.entries.map(\.text) == ["First sample: empty (0 bytes). Watching for changes…"])
        model.bike.onConsoleEvent?(.read(characteristic: control, bytes: [0, 1], error: nil))
        model.bike.onConsoleEvent?(.read(characteristic: control, bytes: [0, 2], error: nil))
        #expect(model.console.entries.map(\.text).prefix(2) == ["byte 1: 01→02", "Length changed 0 → 2 bytes: 00 01"])
    }
}
