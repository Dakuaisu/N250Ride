import AVFoundation
import CoreLocation
import Foundation
import UIKit
import Observation
import RideCore

/// Composition root and persistent session owner. Lives for the whole process so
/// view recreation can never restart navigation or re-request a route.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable {
        /// Synthetic route replay: no Apple or Google route requests.
        case simulation
        /// The build's live provider (Apple Maps now; Google when enabled and authorised).
        case live
    }

    struct PendingDestination: Equatable {
        var coordinate: Coordinate
        var label: String
    }

    enum Tab: Hashable {
        case ride, map, bike, diagnostics
    }

    enum RideStage: Equatable {
        case choosing
        case confirming(PendingDestination)
        case requesting(PendingDestination)
        case preview(PendingDestination)
        case navigating(PendingDestination)
        case failed(PendingDestination, String)
    }

    /// Persisted switch for the synthetic replay (and UI tests via `-simulationMode YES`).
    private(set) var simulationMode: Bool
    private(set) var stage: RideStage = .choosing
    private(set) var intent: DashboardIntent = .clear(.noSession)
    private(set) var navigationState: NavigationState = .idle
    private(set) var recentFrames: [SentFrame] = []
    private(set) var diagnostics = DiagnosticsLog()
    private(set) var termsAccepted: Bool
    private(set) var favourites: FavouritesList
    /// Status packet profile under bench test; nil sends none.
    private(set) var statusProfile: GeneralStatusProfile?
    var selectedTab: Tab = .ride
    private(set) var routeOptions: [RouteOption] = []
    private(set) var selectedRouteID: RouteOption.ID?
    /// Latest accepted guidance, for the on-phone turn card.
    private(set) var guidance: NavigationSnapshot?
    let search = PlaceSearch()
    private(set) var places: SavedPlaces
    /// Shown when a shared or pasted link has no usable location.
    var linkMessage: String?
    var voiceEnabled: Bool {
        didSet { defaults.set(voiceEnabled, forKey: Self.voiceKey) }
    }
    var routePreferences: RoutePreferences {
        didSet {
            defaults.set(try? JSONEncoder().encode(routePreferences), forKey: Self.routePreferencesKey)
            provider?.routePreferences = routePreferences
        }
    }

    /// Bench testing: replace the phone's real values in the status packet.
    var customStatusEnabled = false
    var customVolume = 5
    var customBatteryBars = 3
    var customSignal = 4
    var customRawBytes = ""
    var customRawBytesError: String? {
        GeneralStatusEncoder.parseOverrides(customRawBytes) == nil
            ? "Use offset=value pairs, e.g. 13=2, 17=0x01" : nil
    }

    let bike: BikeConnection
    let console: BluetoothConsole
    let routeGate: RouteRequestGate
    let provider: LiveNavigationProvider?

    @ObservationIgnored private let clock: RideClock
    @ObservationIgnored private let coordinator: SessionCoordinator
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locationManager = CLLocationManager()
    /// Injectable for tests; reads the app's Core Location authorisation.
    @ObservationIgnored var locationAuthorization: () -> CLAuthorizationStatus = { CLLocationManager().authorizationStatus }
    @ObservationIgnored private var fixture: FixtureNavigationSource?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastLinkSummary: DiagnosticsLog.LinkSummary?
    @ObservationIgnored private let voice = VoiceGuide()
    @ObservationIgnored private let liveActivity = RideLiveActivity()

    struct SentFrame: Identifiable {
        let id = UUID()
        let summary: TbtFrameSummary
    }

    private static let favouritesKey = "favourites"
    private static let statusProfileKey = "statusProfile"
    private static let simulationKey = "simulationMode"
    private static let placesKey = "savedPlaces"
    private static let voiceKey = "voiceGuidance"
    private static let routePreferencesKey = "routePreferences"

    init(configuration: AppConfiguration = .load(), defaults: UserDefaults = .standard,
         provider injected: LiveNavigationProvider? = nil) {
        let clock = SystemRideClock()
        let coordinator = SessionCoordinator(clock: clock, configuration: SessionConfiguration(
            statusProfile: configuration.provenStatusProfile))
        self.clock = clock
        self.coordinator = coordinator
        self.defaults = defaults
        bike = BikeConnection(coordinator: coordinator, clock: clock)
        console = BluetoothConsole(bike: bike)
        routeGate = RouteRequestGate(
            policy: configuration.liveRoutePolicy,
            store: UserDefaultsUsageCounterStore(defaults: defaults),
            clock: clock
        )
        favourites = defaults.data(forKey: Self.favouritesKey)
            .flatMap { try? JSONDecoder().decode(FavouritesList.self, from: $0) } ?? FavouritesList()
        let profile = defaults.string(forKey: Self.statusProfileKey).flatMap(GeneralStatusProfile.init(rawValue:))
            ?? configuration.provenStatusProfile
        statusProfile = profile
        coordinator.statusProfile = profile
        places = defaults.data(forKey: Self.placesKey)
            .flatMap { try? JSONDecoder().decode(SavedPlaces.self, from: $0) } ?? SavedPlaces()
        voiceEnabled = defaults.object(forKey: Self.voiceKey) as? Bool ?? true
        routePreferences = defaults.data(forKey: Self.routePreferencesKey)
            .flatMap { try? JSONDecoder().decode(RoutePreferences.self, from: $0) } ?? RoutePreferences()
        UIDevice.current.isBatteryMonitoringEnabled = true

        provider = injected ?? Self.makeProvider(configuration, clock: clock)
        simulationMode = provider == nil || defaults.bool(forKey: Self.simulationKey)
        termsAccepted = provider?.termsAccepted ?? true

        coordinator.onIntentChange = { [weak self] intent in
            guard let self else { return }
            self.intent = intent
            record(.dashboard(.init(intent)))
            if case .guidance(_, let frame) = intent, let summary = TbtFrameSummary(frame: frame) {
                recentFrames.insert(SentFrame(summary: summary), at: 0)
                if recentFrames.count > 20 { recentFrames.removeLast() }
            }
        }
        provider?.onSnapshot = { [weak self] in self?.receive($0) }
        provider?.onLongPress = { [weak self] coordinate in
            guard let self, stage == .choosing else { return }
            propose(coordinate)
        }
        provider?.onRerouteNeeded = { [weak self] in self?.reroute() }
        provider?.routePreferences = routePreferences
        console.host = self
        record(.appLaunched(live: mode == .live))
        if provider?.termsAccepted == true { acceptTerms() }
        startTicker()
    }

    private static func makeProvider(_ configuration: AppConfiguration, clock: RideClock) -> LiveNavigationProvider? {
        switch configuration.navigationProvider {
        case .apple:
            return AppleNavigationProvider(clock: clock)
        case .google:
            #if canImport(GoogleNavigation)
            if case .metered = configuration.liveRoutePolicy, let key = configuration.googleAPIKey,
               GoogleNavigationController.provideKeyOnce(key) {
                return GoogleNavigationController(clock: clock)
            }
            #endif
            return nil
        }
    }

    var mode: Mode { simulationMode ? .simulation : .live }

    /// Only between rides, so a running session never changes source.
    func setSimulationMode(_ on: Bool) {
        guard stage == .choosing, provider != nil || on else { return }
        simulationMode = on
        defaults.set(on, forKey: Self.simulationKey)
    }

    /// Why test frames and the console are refused right now, in the rider's words.
    var diagnosticsLockReason: String? {
        switch stage {
        case .requesting: return "A route is being calculated on the Ride tab."
        case .preview: return "A route is open on the Ride tab (Choose a route)."
        case .navigating: return "A ride is in progress on the Ride tab."
        case .choosing, .confirming, .failed:
            return navigationState == .active || navigationState == .rerouting ? "Navigation is still active." : nil
        }
    }

    var diagnosticsLocked: Bool { diagnosticsLockReason != nil }

    /// Closes an open route or ends the ride so the bench tools can be used.
    func endRideForDiagnostics() {
        stopNavigation()
    }

    // MARK: Destination flow

    /// Long-press, favourite and pasted destinations all enter here and share the
    /// same confirmation and request gate.
    func propose(_ coordinate: Coordinate, label: String = "") {
        guard stage == .choosing || isFailed else { return }
        stage = .confirming(PendingDestination(coordinate: coordinate, label: label))
    }

    func proposePasted(_ text: String) -> DestinationParseError? {
        switch DestinationInputParser.parse(text) {
        case .success(let coordinate):
            propose(coordinate)
            return nil
        case .failure(let error):
            return error
        }
    }

    func cancelDestination() {
        switch stage {
        case .confirming, .failed: stage = .choosing
        default: break
        }
    }

    enum Shortcut: Hashable {
        case home, work
    }

    func confirmDestination(label: String, saveAsFavourite: Bool, shortcut: Shortcut? = nil) {
        guard case .confirming(var pending) = stage else { return }
        pending.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if saveAsFavourite {
            favourites.add(label: pending.label, coordinate: pending.coordinate)
            persistFavourites()
        }
        if let shortcut { setShortcut(shortcut, label: pending.label, coordinate: pending.coordinate) }
        places.recordRecent(label: pending.label, coordinate: pending.coordinate)
        persistPlaces()
        switch mode {
        case .simulation: beginSimulatedRoute(pending)
        case .live: requestLiveRoute(pending)
        }
    }

    /// Retrying is always an explicit rider action; nothing retries automatically.
    func retry() {
        guard case .failed(let pending, _) = stage else { return }
        stage = .confirming(pending)
    }

    /// One tap: Home, Work, a recent or favourite goes straight to route options.
    func navigate(to place: Favourite) {
        guard stage == .choosing || isFailed else { return }
        stage = .confirming(PendingDestination(coordinate: place.coordinate, label: place.label))
        confirmDestination(label: place.label, saveAsFavourite: false)
    }

    func setShortcut(_ shortcut: Shortcut, label: String, coordinate: Coordinate) {
        let name = label.isEmpty ? (shortcut == .home ? "Home" : "Work") : label
        switch shortcut {
        case .home: places.home = Favourite(label: name, coordinate: coordinate)
        case .work: places.work = Favourite(label: name, coordinate: coordinate)
        }
        persistPlaces()
    }

    func clearShortcut(_ shortcut: Shortcut) {
        switch shortcut {
        case .home: places.home = nil
        case .work: places.work = nil
        }
        persistPlaces()
    }

    func clearRecents() {
        places.clearRecents()
        persistPlaces()
    }

    private func persistPlaces() {
        defaults.set(try? JSONEncoder().encode(places), forKey: Self.placesKey)
    }

    // MARK: Shared and pasted links

    /// Text or a link from the Share extension, the clipboard or an n250ride:// URL.
    func handleIncoming(_ text: String) {
        guard stage == .choosing || isFailed else {
            linkMessage = "Finish the current ride before opening a new destination."
            return
        }
        switch MapLinkParser.parse(text) {
        case .place(let coordinate, let name):
            accept(coordinate, name: name)
        case .needsExpansion(let url):
            linkMessage = "Opening shared link…"
            Task {
                let expanded = await LinkExpander.expand(url)
                if let expanded, case .place = MapLinkParser.parse(url: expanded) {
                    handleIncoming(expanded.absoluteString)
                } else {
                    linkMessage = "Couldn't read a location from that link."
                }
            }
        case nil:
            linkMessage = "No location found in what was shared."
        }
    }

    /// n250ride://open?ll=12.97,77.59&name=Office or n250ride://open?link=<url>.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "n250ride" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let link = value("link") {
            handleIncoming(link)
        } else if let ll = value("ll"), let coordinate = MapLinkParser.coordinateText(ll) {
            guard stage == .choosing || isFailed else {
                linkMessage = "Finish the current ride before opening a new destination."
                return
            }
            accept(coordinate, name: value("name"))
        }
    }

    private func accept(_ coordinate: Coordinate, name: String?) {
        linkMessage = nil
        selectedTab = .ride
        propose(coordinate, label: name ?? "")
    }

    func checkShareInbox() {
        if let text = ShareInbox.take() { handleIncoming(text) }
    }

    func startNavigation() {
        guard case .preview(let pending) = stage else { return }
        stage = .navigating(pending)
        voice.reset()
        liveActivity.start(destination: RideView.title(pending))
        switch mode {
        case .simulation: fixture?.start()
        case .live: provider?.startGuidance()
        }
    }

    func stopNavigation() {
        fixture?.stop()
        fixture = nil
        provider?.stop()
        coordinator.endSession()
        updateNavigationState()
        voice.reset()
        liveActivity.end()
        stage = .choosing
        routeOptions = []
        selectedRouteID = nil
        guidance = nil
    }

    func renameFavourite(_ id: UUID, to label: String) {
        favourites.rename(id, to: label)
        persistFavourites()
    }

    func deleteFavourite(_ id: UUID) {
        favourites.delete(id)
        persistFavourites()
    }

    func acceptTerms() {
        provider?.requestTerms { [weak self] accepted in self?.termsAccepted = accepted }
    }

    private var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    private func beginSimulatedRoute(_ pending: PendingDestination) {
        let session = SessionID()
        coordinator.beginSession(session)
        let route = FixtureRoute.demo
        let source = FixtureNavigationSource(route: route, clock: clock)
        source.onSnapshot = { [weak self] in self?.receive($0) }
        fixture = source
        source.preview(session: session, generation: coordinator.generation)
        showOptions([RouteOption(id: 0, name: "Synthetic demo route", distanceMetres: Double(route.totalMetres),
                                 expectedSeconds: Double(route.totalMetres) / route.metresPerSecond,
                                 hasTolls: false, hasHighways: false)], for: pending)
    }

    private func showOptions(_ options: [RouteOption], for pending: PendingDestination) {
        routeOptions = options
        selectedRouteID = options.first?.id
        stage = .preview(pending)
        selectedTab = .ride
    }

    /// Chooses between the candidates of the one request already made.
    func selectRoute(_ id: RouteOption.ID) {
        guard case .preview = stage, routeOptions.contains(where: { $0.id == id }) else { return }
        if mode == .live {
            guard provider?.selectRoute(id) == true else { return }
        }
        selectedRouteID = id
    }

    private func requestLiveRoute(_ pending: PendingDestination) {
        guard let provider, termsAccepted else {
            stage = .failed(pending, "Accept the navigation notice first.")
            return
        }
        switch locationAuthorization() {
        case .denied, .restricted:
            record(.permission(.locationDenied))
            stage = .failed(pending, "Location access is off. Enable it in Settings > N250 Ride > Location.")
            return
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            stage = .failed(pending, "Allow location access when asked, then tap Try again.")
            return
        default:
            break
        }

        let ticket: RouteTicket
        switch routeGate.authorize(destinationCount: 1) {
        case .success(let granted):
            ticket = granted
            record(.routeRequest(.authorized))
        case .failure(let denial):
            record(.routeRequest(.init(denial)))
            if denial != .requestInFlight {
                stage = .failed(pending, Self.message(for: denial))
            }
            return
        }

        let session = SessionID()
        coordinator.beginSession(session)
        stage = .requesting(pending)
        provider.requestRoute(to: pending.coordinate, title: pending.label.isEmpty ? "Destination" : pending.label,
                            session: session, generation: coordinator.generation) { [weak self] result in
            guard let self else { return }
            routeGate.finish(ticket)
            switch result {
            case .success(let options):
                record(.routeRequest(.succeeded))
                showOptions(options, for: pending)
            case .failure(let failure):
                record(.routeRequest(Self.summary(for: failure)))
                coordinator.endSession()
                stage = .failed(pending, failure.message)
            }
        }
    }

    /// Throttled by the guidance engine; serialised and debounced by the route gate.
    /// The coordinator moves to the new generation only once the new route exists, so
    /// the dashboard stays cleared ("rerouting") meanwhile and old callbacks are rejected.
    private func reroute() {
        guard case .navigating = stage, let provider, let session = coordinator.session else { return }
        let ticket: RouteTicket
        switch routeGate.authorize(destinationCount: 1) {
        case .success(let granted): ticket = granted
        case .failure(let denial):
            record(.routeRequest(.init(denial)))
            return
        }
        record(.routeRequest(.authorized))
        provider.reroute(session: session, generation: coordinator.generation.next) { [weak self] result in
            guard let self else { return }
            routeGate.finish(ticket)
            switch result {
            case .success:
                coordinator.replaceRoute()
                record(.routeRequest(.succeeded))
            case .failure(let failure):
                record(.routeRequest(Self.summary(for: failure)))
            }
        }
    }

    private func receive(_ snapshot: NavigationSnapshot) {
        if case .success = coordinator.receive(snapshot) {
            guidance = snapshot
            if case .navigating = stage {
                if voiceEnabled { voice.handle(snapshot) }
                liveActivity.update(snapshot, linkReady: bike.state.isReady)
            }
        }
        updateNavigationState()
    }

    // MARK: Parked diagnostics

    /// Shows one synthetic frame for a few seconds without starting a navigation
    /// session, so the panel never locks itself. Refused while navigating.
    func sendTestFrame(_ maneuver: Maneuver, stepMetres: Int, roundaboutDirection: RoundaboutDirection? = nil) {
        guard let icon = ManeuverMapper.icon(for: maneuver, stepMetres: stepMetres),
              let exit = ManeuverMapper.roundaboutExit(for: maneuver, direction: roundaboutDirection) else { return }
        let eta = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(15 * 60))
        let hour24 = eta.hour ?? 0
        showDiagnostic(TbtFields(
            frameType: .navigation, icon: icon, isAM: hour24 < 12,
            stepMetres: stepMetres, totalMetres: 4_200,
            etaHour: hour24 % 12 == 0 ? 12 : hour24 % 12, etaMinute: eta.minute ?? 0,
            roundaboutExit: exit, text: "TEST"))
    }

    /// A raw navigation frame from the Bluetooth console, held like a test frame.
    func sendConsoleFrame(_ frame: [UInt8]) -> String? {
        if let reason = diagnosticsLockReason { return reason }
        guard stage == .choosing else { return "Close the destination screen first." }
        guard bike.state.isReady else { return "Bike not connected." }
        guard TbtFrame.hasValidChecksum(frame) else { return "Checksum is wrong. Turn on Fix checksum." }
        guard coordinator.showDiagnosticFrame(frame) else { return "Refused: a ride session is active." }
        if let summary = TbtFrameSummary(frame: frame) {
            recentFrames.insert(SentFrame(summary: summary), at: 0)
            if recentFrames.count > 20 { recentFrames.removeLast() }
        }
        return nil
    }

    @discardableResult
    func clearTestFrame() -> String? {
        if let reason = diagnosticsLockReason { return reason }
        coordinator.clearDiagnosticFrame()
        return nil
    }

    /// Bench probe for the unproven roundabout nibble: roundabout icon plus a raw 0-15
    /// value, held for a few seconds. Parked use only.
    func sendRoundaboutProbe(rightGlyph: Bool, nibble: Int) {
        let fields = TbtFields(frameType: .navigation,
                               icon: rightGlyph ? ClusterIcon.roundaboutRight : ClusterIcon.roundaboutLeft,
                               isAM: true, stepMetres: 300, totalMetres: 4_200, etaHour: 9, etaMinute: 30)
        showDiagnostic(fields, roundaboutNibble: nibble)
    }

    private func showDiagnostic(_ fields: TbtFields, roundaboutNibble: Int? = nil) {
        guard !diagnosticsLocked, stage == .choosing, coordinator.session == nil,
              var frame = try? TbtFrame.encode(fields) else { return }
        if let roundaboutNibble {
            guard let probed = TbtFrame.withRoundaboutNibble(frame, roundaboutNibble) else { return }
            frame = probed
        }
        guard coordinator.showDiagnosticFrame(frame), let summary = TbtFrameSummary(frame: frame) else { return }
        recentFrames.insert(SentFrame(summary: summary), at: 0)
        if recentFrames.count > 20 { recentFrames.removeLast() }
    }

    private var customPhoneStatus: PhoneStatus {
        PhoneStatus(volume: customVolume, batteryBars: customBatteryBars, signal: customSignal,
                    rawOverrides: GeneralStatusEncoder.parseOverrides(customRawBytes) ?? [:])
    }

    /// Sends the status packet now (with custom values when enabled).
    func sendStatusNow() {
        coordinator.phoneStatus = customStatusEnabled ? customPhoneStatus : Self.currentPhoneStatus()
        coordinator.sendStatusNow()
    }

    func useSearchSuggestion(_ suggestion: PlaceSearch.Suggestion) {
        search.resolve(suggestion) { [weak self] coordinate, name in
            self?.propose(coordinate, label: name)
            self?.search.clear()
        }
    }

    func setStatusProfile(_ profile: GeneralStatusProfile?) {
        statusProfile = profile
        defaults.set(profile?.rawValue, forKey: Self.statusProfileKey)
        coordinator.statusProfile = profile
    }

    func diagnosticsExport() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        return diagnostics.export(
            appVersion: version,
            sdkVersion: provider.flatMap { p in p.sdkVersion.map { "\(p.name) \($0)" } ?? p.name },
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    func clearDiagnostics() {
        diagnostics.removeAll()
    }

    // MARK: Plumbing

    private func record(_ event: DiagnosticsLog.Event) {
        diagnostics.record(event, at: clock.now)
    }

    private func updateNavigationState() {
        let state = coordinator.navigationState
        if state != navigationState {
            navigationState = state
            record(.navigationState(state))
        }
    }

    private func persistFavourites() {
        defaults.set(try? JSONEncoder().encode(favourites), forKey: Self.favouritesKey)
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                fixture?.tick()
                coordinator.phoneStatus = customStatusEnabled ? customPhoneStatus : Self.currentPhoneStatus()
                coordinator.tick()
                updateNavigationState()
                let link = DiagnosticsLog.LinkSummary(bike.state)
                if link != lastLinkSummary {
                    lastLinkSummary = link
                    record(.link(link))
                }
            }
        }
    }

    /// Real battery bars and media volume for the status packet; defaults when unknown (simulator).
    static func currentPhoneStatus() -> PhoneStatus {
        let level = UIDevice.current.batteryLevel
        let volume = AVAudioSession.sharedInstance().outputVolume
        return PhoneStatus(
            volume: Int((volume * 15).rounded()),
            batteryBars: level < 0 ? 3 : GeneralStatusFields.batteryBars(forLevel: Double(level))
        )
    }

    static func message(for denial: RouteRequestDenial) -> String {
        switch denial {
        case .providerDisabled(let reason): "Live navigation is off: \(reason)."
        case .requestInFlight: "A route request is already in progress."
        case .tooSoon: "Please wait a moment before requesting another route."
        case .invalidDestinationCount: "No destination selected."
        case .dailyLimitReached(let limit): "Daily limit of \(limit) destinations reached. It resets at midnight."
        case .monthlyLimitReached(let limit): "Monthly limit of \(limit) destinations reached."
        }
    }

    static func summary(for failure: RouteRequestFailure) -> DiagnosticsLog.RouteRequestSummary {
        switch failure {
        case .noTwoWheelerRoute, .noRoute: .failedNoRoute
        case .network: .failedNetwork
        case .quotaExceeded: .failedQuota
        case .keyNotAuthorized: .failedKey
        case .cancelled: .cancelled
        case .throttled, .locationUnavailable, .other: .failedOther
        }
    }
}

/// Persists route-request counters locally. They reset on reinstall, so they are
/// a guard rail, not a spend guarantee.
final class UserDefaultsUsageCounterStore: UsageCounterStore {
    private let defaults: UserDefaults
    private let key = "routeUsageCounters"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> UsageCounters? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageCounters.self, from: $0) }
    }

    func save(_ counters: UsageCounters) {
        defaults.set(try? JSONEncoder().encode(counters), forKey: key)
    }
}
