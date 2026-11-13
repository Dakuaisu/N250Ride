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
    var onFix: ((AdmittedFix) -> Void)?
    var routePreferences = RoutePreferences()
    let name = "Spy"
    let routingLabel = "Spy route"
    let termsNotice = "notice"
    var termsAccepted = true
    let sdkVersion: String? = nil
    let mapHostView = UIView()
    var supportsTransactionalReplacement = true
    var lastFix: AdmittedFix?

    /// New-destination calculations (initial, recovery, next leg, replacement).
    var routeRequests = 0
    /// Generations of reroutes on the current session.
    var rerouteRequests: [RouteGeneration] = []
    var requests: [NavigationRouteRequest] = []
    var pendingRoute: ((Result<[RouteOption], RouteRequestFailure>) -> Void)?
    var pendingReroute: ((Result<Void, RouteRequestFailure>) -> Void)?
    var cancelled: [UUID] = []
    var discarded: [PreparedRouteHandle] = []
    var committed: [PreparedRouteHandle] = []
    var selected: [RouteOption.ID] = []
    var started = 0
    var stops = 0
    var startCheck = StartCheck.ready
    var commitSucceeds = true
    let origin = Coordinate(latitude: 12.97, longitude: 77.59)!
    let options = [
        RouteOption(id: 0, name: "Outer Ring Road", distanceMetres: 5_400, expectedSeconds: 1_200, hasTolls: false, hasHighways: true),
        RouteOption(id: 2, name: "Old Airport Road", distanceMetres: 5_100, expectedSeconds: 1_380, hasTolls: false, hasHighways: false),
    ]

    func requestTerms(completion: @escaping @MainActor (Bool) -> Void) { completion(true) }

    func prepareRoute(_ request: NavigationRouteRequest,
                      completion: @escaping @MainActor (Result<PreparedRoute, RouteRequestFailure>) -> Void) {
        requests.append(request)
        let handle = PreparedRouteHandle(id: UUID())
        let origin = origin
        if request.reason.keepsSession {
            rerouteRequests.append(request.generation)
            let first = options[0]
            pendingReroute = { result in
                completion(result.map { PreparedRoute(handle: handle, options: [first], origin: origin) })
            }
        } else {
            routeRequests += 1
            pendingRoute = { result in
                completion(result.map { PreparedRoute(handle: handle, options: $0, origin: origin) })
            }
        }
    }

    func previewPrepared(_ handle: PreparedRouteHandle, option: RouteOption.ID) -> Bool {
        selected.append(option)
        return true
    }

    func checkStart(_ handle: PreparedRouteHandle, completion: @escaping @MainActor (StartCheck) -> Void) {
        completion(startCheck)
    }

    func commitPreparedRoute(_ handle: PreparedRouteHandle, option: RouteOption.ID) -> Bool {
        guard commitSucceeds else { return false }
        committed.append(handle)
        return true
    }

    func cancelPreparation(_ operationID: UUID) { cancelled.append(operationID) }
    func discardPrepared(_ handle: PreparedRouteHandle) { discarded.append(handle) }
    func recenter() {}
    func setMapVisible(_ visible: Bool) {}
    func setFollowAnimations(_ enabled: Bool) {}
    func startGuidance() { started += 1 }
    func stop() { stops += 1 }
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
                         defaults: defaults, provider: spy, dependencies: .test())
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

    @Test func lateRouteAnswerCannotReviveAStoppedRide() async throws {
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        let abandoned = try #require(spy.pendingRoute)
        model.endRideForDiagnostics()
        abandoned(.success(spy.options))
        #expect(model.stage == .choosing)
        #expect(model.routeOptions.isEmpty)

        try await Task.sleep(for: .milliseconds(2_100))
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        #expect(spy.routeRequests == 2, "the abandoned request no longer holds the gate")
        abandoned(.failure(.network))
        guard case .requesting = model.stage else {
            Issue.record("a stale failure ended the new request: \(model.stage)")
            return
        }
        spy.pendingRoute?(.success(spy.options))
        guard case .preview = model.stage else {
            Issue.record("expected preview, got \(model.stage)")
            return
        }
    }

    @Test func lateRerouteAnswerCannotChangeTheNextRide() async throws {
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.success(spy.options))
        model.startNavigation()
        try await Task.sleep(for: .milliseconds(2_100))
        spy.onRerouteNeeded?()
        let abandoned = try #require(spy.pendingReroute)
        model.stopNavigation()

        try await Task.sleep(for: .milliseconds(2_100))
        model.propose(destination)
        model.confirmDestination(label: "", saveAsFavourite: false)
        spy.pendingRoute?(.success(spy.options))
        model.startNavigation()
        abandoned(.success(()))
        try await Task.sleep(for: .milliseconds(2_100))
        spy.onRerouteNeeded?()
        #expect(spy.rerouteRequests == [RouteGeneration(1), RouteGeneration(1)],
                "the old reroute did not advance the new ride's route generation")
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
                             defaults: defaults, provider: spy, dependencies: .test())
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

    @Test func callPresetsPauseTheAppsStatusPacketsUntilCallEnded() throws {
        model.setStatusProfile(.legacy55)
        let presets = BluetoothConsole.presets(statusProfile: .legacy55)
        let incoming = try #require(presets.first { $0.name.hasPrefix("Incoming call") })
        let ended = try #require(presets.first { $0.name.hasPrefix("Call ended") })
        model.console.run(incoming)
        #expect(model.console.target == ClusterGATT.generalStatus)
        model.console.run(ended)
        let notes = model.console.entries.map(\.text).filter { $0.hasPrefix("App's status packets") }
        #expect(notes == ["App's status packets resumed.", "App's status packets paused for this test."])
    }

    @Test func firmwareUpdateChannelsAreBlocked() {
        for id in ["F000FFC1-0451-4000-B000-000000000000", "f000ffc2-0451-4000-b000-000000000000",
                   "F000FFC5-0451-4000-B000-000000000000", "F000FFD1-0451-4000-B000-000000000000"] {
            #expect(BikeConnection.isBlocked(id), "\(id)")
        }
        #expect(!BikeConnection.isBlocked(BluetoothConsole.controlChannel))
        #expect(!BikeConnection.isBlocked("F000FFE1-0451-4000-B000-000000000000"))
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
