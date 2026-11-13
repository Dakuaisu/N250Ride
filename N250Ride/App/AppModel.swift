import AVFoundation
import CoreLocation
import Foundation
import UIKit
import Observation
import RideCore

/// Composition root and persistent session owner. Lives for the whole process so
/// view recreation can never restart navigation or re-request a route.
///
/// Route changes follow one transaction: authorise one gate ticket, *prepare* a
/// route without touching the active one, then *commit* it on the main actor before
/// any of its snapshots can arrive. Preparation failures change nothing that is active.
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
        var provenance: DestinationProvenance = .manual
        /// The one optional stop on the way, chosen at confirmation.
        var stop: RideDestination?
        /// The inbox item this destination came from, consumed once its ride starts.
        var inboxItem: UUID?
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
        /// Leg one ended at the stop; nothing is guided until the rider continues.
        case atStop(PendingDestination)
        case failed(PendingDestination, String)
    }

    /// A rider-visible route calculation during a ride (reroute or replacement).
    enum RouteOperationStatus: Equatable {
        case idle
        case preparing(RouteReason)
        case failed(RouteReason, String)
    }

    enum StartStatus: Equatable {
        case idle
        case checking
        case blocked(String)
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
    /// The journey being ridden: itinerary, leg and preferences.
    private(set) var ride: RideContext?
    private(set) var routeOperation: RouteOperationStatus = .idle
    private(set) var startStatus: StartStatus = .idle
    private(set) var previewExpired = false
    private(set) var health = RideHealthEvaluator.evaluate(AppModel.idleHealthInput)
    private(set) var recoveryOffer: RecoveryOffer?
    let search = PlaceSearch()
    private(set) var places: SavedPlaces
    /// Shown when a shared or pasted link has no usable location.
    var linkMessage: String?
    var voiceEnabled: Bool {
        didSet {
            defaults.set(voiceEnabled, forKey: Self.voiceKey)
            voice.setEnabled(voiceEnabled)
            updateHealth()
        }
    }
    var voiceStyle: VoiceStyle {
        didSet {
            defaults.set(voiceStyle.rawValue, forKey: Self.voiceStyleKey)
            voice.style = voiceStyle
        }
    }
    /// Applies to the next calculation of any kind, including reroutes of the current ride.
    var routePreferences: RoutePreferences {
        didSet { defaults.set(try? JSONEncoder().encode(routePreferences), forKey: Self.routePreferencesKey) }
    }
    /// Fewer Live Activity updates and no map animations. Never changes GPS quality,
    /// freshness, rerouting or dashboard deadlines.
    var energySaving: Bool {
        didSet {
            defaults.set(energySaving, forKey: Self.energyKey)
            applyEnergyMode()
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
    let checklist: ManualChecklist
    let routeGate: RouteRequestGate
    let provider: LiveNavigationProvider?
    let voice: VoiceGuide
    let recovery: RecoveryStore
    let inbox: IncomingInbox
    let history: RideHistoryStore
    let setup: BikeSetupModel

    @ObservationIgnored private let clock: RideClock
    @ObservationIgnored private let timers: RideTimers
    @ObservationIgnored private let coordinator: SessionCoordinator
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locationManager = CLLocationManager()
    /// Injectable for tests; reads the app's Core Location authorisation.
    @ObservationIgnored var locationAuthorization: () -> CLAuthorizationStatus = { CLLocationManager().authorizationStatus }
    /// Injectable for tests; follows a short link's redirects.
    @ObservationIgnored var expandLink: (URL) async -> URL? = { await LinkExpander.expand($0) }
    @ObservationIgnored private var fixture: FixtureNavigationSource?
    @ObservationIgnored private var lastLinkSummary: DiagnosticsLog.LinkSummary?
    @ObservationIgnored private let liveActivity: RideLiveActivity
    @ObservationIgnored private let calls: CallStateSource
    @ObservationIgnored private var callInProgress = false
    @ObservationIgnored private var consoleHoldsStatus = false
    /// The call stays on the dashboard at least this long after it starts ringing.
    static let callHoldMinimum: Duration = .seconds(15)
    @ObservationIgnored private var callHoldUntil: MonotonicInstant?
    @ObservationIgnored private var callHoldTimer: TimerToken?
    @ObservationIgnored private var wake: TimerToken?
    @ObservationIgnored private var wakeAt: MonotonicInstant?
    @ObservationIgnored private var rideStartedAt: Date?
    @ObservationIgnored private var arrivalFinalized = false
    /// A journey was started (or restored at its stop) and hasn't been finished yet, even
    /// while the screen shows the next leg's calculation or preview.
    @ObservationIgnored private var journeyStarted = false

    /// The one calculation in flight. Its gate ticket is released exactly once,
    /// whichever comes first: the answer, the 30-second deadline, Cancel or Stop.
    private struct Operation {
        let id: UUID
        let ticket: RouteTicket
        let reason: RouteReason
        let context: RideContext
        let session: SessionID
        let generation: RouteGeneration
        let pending: PendingDestination
        let deadline: TimerToken
    }

    /// A calculated route awaiting Start (initial, recovery or next leg). No authority until committed.
    private struct Proposal {
        let handle: PreparedRouteHandle
        let reason: RouteReason
        let context: RideContext
        let session: SessionID
        let expiry: TimerToken
    }

    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var proposal: Proposal?

    /// Counted for the energy measurements in Diagnostics.
    private(set) var counters = EnergyCounters()

    struct EnergyCounters: Equatable {
        var wakes = 0
        var snapshots = 0
        var startedAt = Date()
    }

    struct SentFrame: Identifiable {
        let id = UUID()
        let summary: TbtFrameSummary
    }

    static let operationDeadline: Duration = .seconds(30)
    static let previewLifetime: Duration = .seconds(120)
    /// Smallest gap between wakes, so an overdue deadline can never spin.
    static let minimumWake: Duration = .milliseconds(20)
    static let fixtureTick: Duration = .milliseconds(200)

    private static let favouritesKey = "favourites"
    private static let statusProfileKey = "statusProfile"
    private static let simulationKey = "simulationMode"
    private static let placesKey = "savedPlaces"
    private static let voiceKey = "voiceGuidance"
    private static let voiceStyleKey = "voiceStyle"
    private static let routePreferencesKey = "routePreferences"
    private static let energyKey = "energySaving"

    init(configuration: AppConfiguration = .load(), defaults: UserDefaults = .standard,
         provider injected: LiveNavigationProvider? = nil, dependencies: AppDependencies? = nil) {
        let deps = dependencies ?? .live()
        let clock = deps.clock
        let coordinator = SessionCoordinator(clock: clock, configuration: SessionConfiguration(
            statusProfile: configuration.provenStatusProfile))
        self.clock = clock
        timers = deps.timers
        self.coordinator = coordinator
        self.defaults = defaults
        calls = deps.calls
        liveActivity = RideLiveActivity(enabled: deps.liveActivities, sink: deps.activitySink, timers: deps.timers,
                                        now: { clock.wallNow })
        bike = BikeConnection(coordinator: coordinator, clock: clock, defaults: defaults)
        console = BluetoothConsole(bike: bike)
        checklist = ManualChecklist(defaults: defaults)
        routeGate = RouteRequestGate(
            policy: configuration.liveRoutePolicy,
            store: UserDefaultsUsageCounterStore(defaults: defaults),
            clock: clock
        )
        let now = clock.wallNow
        recovery = RecoveryStore(directory: deps.storage, defaults: defaults)
        inbox = IncomingInbox(directory: deps.storage, now: now)
        history = RideHistoryStore(directory: deps.storage, now: now, defaults: defaults)
        let info = Bundle.main.infoDictionary ?? [:]
        setup = BikeSetupModel(directory: deps.storage,
                               appVersion: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
        favourites = defaults.data(forKey: Self.favouritesKey)
            .flatMap { try? JSONDecoder().decode(FavouritesList.self, from: $0) } ?? FavouritesList()
        let profile = defaults.string(forKey: Self.statusProfileKey).flatMap(GeneralStatusProfile.init(rawValue:))
            ?? configuration.provenStatusProfile
        statusProfile = profile
        coordinator.statusProfile = profile
        places = defaults.data(forKey: Self.placesKey)
            .flatMap { try? JSONDecoder().decode(SavedPlaces.self, from: $0) } ?? SavedPlaces()
        voiceEnabled = defaults.object(forKey: Self.voiceKey) as? Bool ?? true
        let style = defaults.string(forKey: Self.voiceStyleKey).flatMap(VoiceStyle.init(rawValue:)) ?? .detailed
        voiceStyle = style
        voice = VoiceGuide(speech: deps.speech, audio: deps.audio, clock: clock, style: style)
        routePreferences = defaults.data(forKey: Self.routePreferencesKey)
            .flatMap { try? JSONDecoder().decode(RoutePreferences.self, from: $0) } ?? RoutePreferences()
        energySaving = defaults.bool(forKey: Self.energyKey)
        UIDevice.current.isBatteryMonitoringEnabled = true

        provider = injected ?? Self.makeProvider(configuration, clock: clock, timers: deps.timers)
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
        coordinator.onActivity = { [weak self] in self?.scheduleWake() }
        provider?.onSnapshot = { [weak self] in self?.receive($0) }
        provider?.onLongPress = { [weak self] coordinate in
            guard let self, stage == .choosing else { return }
            propose(coordinate, provenance: .mapSelection)
        }
        provider?.onRerouteNeeded = { [weak self] in self?.requestReroute(.offRoute) }
        provider?.onFix = { [weak self] fix in
            guard let self else { return }
            history.add(fix.fix, now: clock.wallNow)
            updateHealth()
            scheduleWake()
        }
        console.host = self
        setup.host = self
        bike.onStateChange = { [weak self] _ in self?.linkChanged() }
        calls.onChange = { [weak self] active in self?.callChanged(active) }
        voice.setEnabled(voiceEnabled)
        callChanged(calls.callInProgress)
        applyEnergyMode()
        liveActivity.endOrphans()
        recoveryOffer = recovery.offer(now: now).flatMap { history.isFinished($0.rideID) ? nil : $0 }
        record(.appLaunched(live: mode == .live))
        if provider?.termsAccepted == true { acceptTerms() }
        updateHealth()
        scheduleWake()
    }

    private static func makeProvider(_ configuration: AppConfiguration, clock: RideClock,
                                     timers: RideTimers) -> LiveNavigationProvider? {
        switch configuration.navigationProvider {
        case .apple:
            return AppleNavigationProvider(clock: clock, timers: timers)
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
        case .atStop: return "A ride is paused at its stop on the Ride tab."
        case .choosing, .confirming, .failed:
            return navigationState == .active || navigationState == .rerouting ? "Navigation is still active." : nil
        }
    }

    var diagnosticsLocked: Bool { diagnosticsLockReason != nil }

    var dashboardDelivery: DashboardDelivery { coordinator.delivery }

    /// Closes an open route or ends the ride so the bench tools can be used.
    func endRideForDiagnostics() {
        stopNavigation()
    }

    // MARK: Destination flow

    /// Long-press, favourite and pasted destinations all enter here and share the
    /// same confirmation and request gate.
    func propose(_ coordinate: Coordinate, label: String = "", provenance: DestinationProvenance = .manual,
                 inboxItem: UUID? = nil) {
        guard stage == .choosing || isFailed else { return }
        stage = .confirming(PendingDestination(coordinate: coordinate, label: label, provenance: provenance,
                                               inboxItem: inboxItem))
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
        case .confirming(let pending), .failed(let pending, _):
            if let item = pending.inboxItem { inbox.setStatus(item, .pending) }
            stage = .choosing
        default:
            break
        }
    }

    enum Shortcut: Hashable {
        case home, work
    }

    func confirmDestination(label: String, saveAsFavourite: Bool, shortcut: Shortcut? = nil, stop: Favourite? = nil) {
        guard case .confirming(var pending) = stage else { return }
        pending.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        pending.stop = stop.map { RideDestination(coordinate: $0.coordinate, label: $0.label, provenance: .saved) }
        if saveAsFavourite {
            favourites.add(label: pending.label, coordinate: pending.coordinate)
            persistFavourites()
        }
        if let shortcut { setShortcut(shortcut, label: pending.label, coordinate: pending.coordinate) }
        places.recordRecent(label: pending.label, coordinate: pending.coordinate)
        persistPlaces()
        if let item = pending.inboxItem, !inbox.setStatus(item, .accepted) {
            // Acceptance must be stored before anything is requested for a saved destination.
            stage = .failed(pending, "Couldn't save this destination's status on the phone, so no route was requested.")
            return
        }
        let final = RideDestination(coordinate: pending.coordinate, label: pending.label, provenance: pending.provenance)
        guard let context = RideContext(itinerary: Itinerary(final: final, stop: pending.stop),
                                        preferences: routePreferences) else { return }
        switch mode {
        case .simulation: beginSimulatedRoute(pending, context: context)
        case .live: requestRoute(.initial, context: context, pending: pending)
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
        stage = .confirming(PendingDestination(coordinate: place.coordinate, label: place.label, provenance: .saved))
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

    func renameFavourite(_ id: UUID, to label: String) {
        favourites.rename(id, to: label)
        persistFavourites()
    }

    func deleteFavourite(_ id: UUID) {
        favourites.delete(id)
        persistFavourites()
    }

    func clearRecents() {
        places.clearRecents()
        persistPlaces()
    }

    /// Places that can be picked as the stop on the way.
    var stopCandidates: [Favourite] {
        var seen = Set<Coordinate>()
        return ([places.home, places.work].compactMap { $0 } + favourites.items + places.recents)
            .filter { seen.insert($0.coordinate).inserted }
    }

    private func persistPlaces() {
        defaults.set(try? JSONEncoder().encode(places), forKey: Self.placesKey)
    }

    // MARK: Shared and pasted links

    /// Text or a link from the Share extension, the clipboard or an n250ride:// URL.
    /// It is saved to the inbox first; it opens straight away only between rides.
    func handleIncoming(_ text: String) {
        _ = receiveIncoming(text)
    }

    @discardableResult
    private func receiveIncoming(_ text: String) -> Bool {
        let added: IncomingInbox.AddResult
        switch MapLinkParser.parse(text) {
        case .place(let coordinate, let name):
            added = inbox.add(coordinate: coordinate, label: name ?? "", link: nil, now: clock.wallNow)
        case .needsExpansion(let url):
            added = inbox.add(coordinate: nil, label: "", link: url.absoluteString, now: clock.wallNow)
        case nil:
            linkMessage = "No location found in what was shared."
            return false
        }
        switch added {
        case .added(let id), .duplicate(let id):
            if stage == .choosing || isFailed {
                openInboxItem(id)
            } else {
                linkMessage = "Destination saved. Open it from the Ride screen when you're ready."
            }
            return true
        case .full:
            linkMessage = "Ten destinations are already waiting. Remove one first."
        case .tooLarge:
            linkMessage = "That link is too long to keep."
        case .storageFailed:
            linkMessage = "Couldn't save that destination on this phone."
        }
        return false
    }

    /// Opens a waiting destination in the confirmation screen, resolving a short link first.
    func openInboxItem(_ id: UUID) {
        guard stage == .choosing || isFailed, let item = inbox.item(id) else { return }
        if let coordinate = item.coordinate {
            linkMessage = nil
            selectedTab = .ride
            inbox.setStatus(id, .reserved)
            propose(coordinate, label: item.label, provenance: .shared, inboxItem: id)
            return
        }
        guard let link = item.link.flatMap(URL.init(string:)) else {
            inbox.setStatus(id, .failed("No location in this link."))
            return
        }
        linkMessage = "Opening shared link…"
        Task { [weak self] in
            let expanded = await self?.expandLink(link)
            guard let self, inbox.item(id) != nil else { return }
            if let expanded, case .place(let coordinate, let name) = MapLinkParser.parse(url: expanded) {
                // Reopen only once the resolved place is stored; otherwise the link would be expanded again.
                guard inbox.resolve(id, coordinate: coordinate, label: name) else {
                    linkMessage = "Found the place, but couldn't save it on this phone. Try again later."
                    return
                }
                openInboxItem(id)
            } else {
                inbox.setStatus(id, .failed("Couldn't read a location from that link."))
                linkMessage = "Couldn't read a location from that link."
            }
        }
    }

    func discardInboxItem(_ id: UUID) {
        inbox.discard(id)
    }

    /// n250ride://open?ll=12.97,77.59&name=Office or n250ride://open?link=<url>.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "n250ride" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let link = value("link") {
            handleIncoming(link)
        } else if let ll = value("ll"), let coordinate = MapLinkParser.coordinateText(ll) {
            let result = inbox.add(coordinate: coordinate, label: value("name") ?? "", link: nil, now: clock.wallNow)
            switch result {
            case .added(let id), .duplicate(let id):
                if stage == .choosing || isFailed {
                    openInboxItem(id)
                } else {
                    linkMessage = "Destination saved. Open it from the Ride screen when you're ready."
                }
            default:
                linkMessage = "Couldn't save that destination on this phone."
            }
        }
    }

    /// Copies the Share extension's hand-off into the inbox, then clears it.
    func checkShareInbox() {
        guard let text = ShareInbox.peek() else { return }
        if receiveIncoming(text) || MapLinkParser.parse(text) == nil { ShareInbox.clear() }
    }

    // MARK: Ride lifecycle

    func acceptTerms() {
        provider?.requestTerms { [weak self] accepted in self?.termsAccepted = accepted }
    }

    private var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    var isRiding: Bool {
        if case .navigating = stage { return true }
        return false
    }

    private func beginSimulatedRoute(_ pending: PendingDestination, context: RideContext) {
        let session = SessionID()
        coordinator.beginSession(session)
        ride = context
        arrivalFinalized = false
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

    /// Chooses between the candidates of the one request already made. No request.
    func selectRoute(_ id: RouteOption.ID) {
        guard case .preview = stage, routeOptions.contains(where: { $0.id == id }) else { return }
        if mode == .live {
            guard let proposal, provider?.previewPrepared(proposal.handle, option: id) == true else { return }
        }
        selectedRouteID = id
    }

    /// Authorises and prepares one route. Nothing active changes until commit.
    private func requestRoute(_ reason: RouteReason, context proposed: RideContext, pending: PendingDestination,
                              fix: FixRequirement? = nil) {
        // The rider's current avoid-tolls/highways choice applies to every calculation;
        // it becomes the ride's own only when this route is committed.
        var context = proposed
        context.preferences = routePreferences
        // The synthetic replay never contacts a route provider.
        guard let provider, mode == .live else { return }
        let opensPreview = reason == .initial || reason == .recovery || reason == .nextLeg
        if opensPreview {
            guard termsAccepted else {
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
        } else if reason.keepsSession || reason == .replacement {
            guard provider.supportsTransactionalReplacement || reason.keepsSession else {
                routeOperation = .failed(reason, "This navigation provider can't change the route during a ride.")
                return
            }
        }
        if operation != nil {
            // One calculation at a time: a second tap or an automatic trigger joins it.
            return
        }

        let ticket: RouteTicket
        switch routeGate.authorize(destinationCount: 1) {
        case .success(let granted):
            ticket = granted
            record(.routeRequest(.authorized))
        case .failure(let denial):
            record(.routeRequest(.init(denial)))
            guard denial != .requestInFlight else { return }
            if opensPreview {
                stage = .failed(pending, Self.message(for: denial))
            } else if reason != .offRoute {
                routeOperation = .failed(reason, Self.message(for: denial))
            }
            return
        }

        let id = UUID()
        let keeps = reason.keepsSession
        let session = keeps ? (coordinator.session ?? SessionID()) : SessionID()
        let generation = keeps ? coordinator.generation.next : RouteGeneration(0)
        let deadline = timers.schedule(after: Self.operationDeadline) { [weak self] in self?.operationTimedOut(id) }
        operation = Operation(id: id, ticket: ticket, reason: reason, context: context, session: session,
                              generation: generation, pending: pending, deadline: deadline)
        if opensPreview {
            stage = .requesting(pending)
        } else {
            routeOperation = .preparing(reason)
        }
        updateHealth()
        let target = context.activeTarget
        let request = NavigationRouteRequest(
            operationID: id, session: session, generation: generation, target: target.coordinate,
            title: target.label.isEmpty ? "Destination" : target.label, preferences: context.preferences,
            reason: reason, alternatives: opensPreview,
            fix: fix ?? (reason == .initial ? .initial : .current))
        provider.prepareRoute(request) { [weak self] result in self?.prepared(id, result) }
    }

    /// Cancels and releases the calculation in flight, if any, and clears its status.
    private func retireOperation() {
        if let op = operation {
            provider?.cancelPreparation(op.id)
            finishOperation(op)
            record(.routeRequest(.cancelled))
        }
        routeOperation = .idle
    }

    private func finishOperation(_ op: Operation) {
        op.deadline.cancel()
        routeGate.finish(op.ticket)
        operation = nil
    }

    private func operationTimedOut(_ id: UUID) {
        guard operation?.id == id else { return }
        provider?.cancelPreparation(id)
        prepared(id, .failure(.timedOut))
    }

    /// The answer to the calculation `id`. Answers for anything else are ignored.
    private func prepared(_ id: UUID, _ result: Result<PreparedRoute, RouteRequestFailure>) {
        guard let op = operation, op.id == id else { return }
        finishOperation(op)
        switch result {
        case .failure(let failure):
            record(.routeRequest(Self.summary(for: failure)))
            switch op.reason {
            case .initial, .recovery:
                stage = .failed(op.pending, failure.message)
            case .nextLeg:
                stage = .atStop(op.pending)
                routeOperation = .failed(.nextLeg, failure.message)
            case .manual, .offRoute, .replacement:
                routeOperation = .failed(op.reason, failure.message)
            }
        case .success(let route):
            record(.routeRequest(.succeeded))
            switch op.reason {
            case .initial, .recovery, .nextLeg:
                let expiry = timers.schedule(after: Self.previewLifetime) { [weak self] in
                    guard let self, self.proposal?.handle == route.handle else { return }
                    self.previewExpired = true
                    if self.startStatus == .checking {
                        // A Start still waiting for a position may no longer commit this route.
                        self.provider?.cancelStartCheck(route.handle)
                        self.startStatus = .blocked("This route is more than two minutes old. Recalculate before starting.")
                    }
                }
                proposal = Proposal(handle: route.handle, reason: op.reason, context: op.context, session: op.session,
                                    expiry: expiry)
                previewExpired = false
                startStatus = .idle
                routeOperation = .idle
                showOptions(route.options, for: op.pending)
            case .manual, .offRoute:
                guard isRiding, provider?.commitPreparedRoute(route.handle, option: route.options[0].id) == true,
                      coordinator.session == op.session else {
                    routeOperation = .failed(op.reason, "The new route couldn't be used.")
                    break
                }
                coordinator.replaceRoute()
                ride = op.context
                recovery.commit(op.context, startedAt: rideStartedAt ?? clock.wallNow, now: clock.wallNow)
                history.breakSegment()
                routeOperation = .idle
            case .replacement:
                guard isRiding, provider?.commitPreparedRoute(route.handle, option: route.options[0].id) == true else {
                    routeOperation = .failed(.replacement, "The new route couldn't be used.")
                    break
                }
                commitReplacement(op)
            }
        }
        updateHealth()
    }

    /// Start: check the rider is still where the route begins, then commit.
    func startNavigation() {
        guard case .preview(let pending) = stage else { return }
        if mode == .simulation {
            stage = .navigating(pending)
            arrivalFinalized = false
            voice.reset()
            liveActivity.start(destination: RideView.title(pending))
            fixture?.start()
            scheduleWake()
            return
        }
        guard let proposal, let provider else { return }
        guard !previewExpired else {
            startStatus = .blocked("This route is more than two minutes old. Recalculate before starting.")
            return
        }
        startStatus = .checking
        provider.checkStart(proposal.handle) { [weak self] check in
            guard let self, self.proposal?.handle == proposal.handle, case .preview = self.stage,
                  !self.previewExpired else { return }
            switch check {
            case .ready:
                commitStart(proposal, pending: pending)
            case .noCurrentFix:
                startStatus = .blocked("No current GPS fix. Move to open sky and tap Start again.")
            case .movedFromOrigin(let metres):
                startStatus = .blocked("You've moved \(metres) m from where this route starts. Recalculate before starting.")
            }
        }
    }

    private func commitStart(_ proposal: Proposal, pending: PendingDestination) {
        guard self.proposal?.handle == proposal.handle, !previewExpired else { return }
        let now = clock.wallNow
        recovery.recordPendingStart(proposal.context, reason: proposal.reason.rawValue, now: now)
        guard let selected = selectedRouteID,
              provider?.commitPreparedRoute(proposal.handle, option: selected) == true else {
            recovery.clearPendingStart()
            startStatus = .blocked("This route can't be started. Recalculate.")
            return
        }
        // No snapshot can have arrived yet: the provider emits only on later fixes.
        coordinator.beginSession(proposal.session)
        proposal.expiry.cancel()
        self.proposal = nil
        let resumed = proposal.reason == .recovery || proposal.reason == .nextLeg
        ride = proposal.context
        stage = .navigating(pending)
        startStatus = .idle
        arrivalFinalized = false
        recoveryOffer = nil
        voice.reset()
        liveActivity.start(destination: RideView.title(pending))
        // Everything the ride records is set up before guidance starts: the first fix
        // can arrive synchronously inside startGuidance() and may already be an arrival.
        if !resumed || rideStartedAt == nil { rideStartedAt = now }
        journeyStarted = true
        recovery.commit(proposal.context, startedAt: rideStartedAt ?? now, now: now)
        switch proposal.reason {
        case .nextLeg: history.continueRide(proposal.context.id)
        case .recovery: history.resume(proposal.context.id, now: now)
        default: history.begin(proposal.context.id, startedAt: rideStartedAt ?? now, now: now)
        }
        if let item = pending.inboxItem { inbox.consume(item) }
        provider?.startGuidance()
        updateHealth()
        scheduleWake()
    }

    /// The route changed mid-ride (skip stop, add stop, new destination): new session, generation zero.
    private func commitReplacement(_ op: Operation) {
        let newJourney = op.context.id != ride?.id
        coordinator.beginSession(op.session)
        let now = clock.wallNow
        if newJourney {
            history.finish(.endedByRider, now: now)
            if let old = ride { recovery.finish(old.id, now: now) }
            rideStartedAt = now
            history.begin(op.context.id, startedAt: now, now: now)
        } else {
            history.breakSegment()
        }
        ride = op.context
        stage = .navigating(op.pending)
        arrivalFinalized = false
        voice.reset()
        if newJourney { liveActivity.start(destination: RideView.title(op.pending)) }
        recovery.commit(op.context, startedAt: rideStartedAt ?? now, now: now)
        if let item = op.pending.inboxItem { inbox.consume(item) }
        routeOperation = .idle
    }

    /// Calculates the current preview again (it expired or the rider moved).
    func recalculatePreview() {
        guard case .preview(let pending) = stage, let old = proposal else { return }
        provider?.discardPrepared(old.handle)
        old.expiry.cancel()
        proposal = nil
        startStatus = .idle
        requestRoute(old.reason, context: old.context, pending: pending)
    }

    /// Cancel on the preview: back to where the rider came from, nothing requested.
    func cancelPreview() {
        guard case .preview(let pending) = stage else { return }
        if mode == .simulation { return stopNavigation() }
        guard let old = proposal else { return stopNavigation() }
        provider?.discardPrepared(old.handle)
        old.expiry.cancel()
        proposal = nil
        startStatus = .idle
        routeOptions = []
        selectedRouteID = nil
        switch old.reason {
        case .nextLeg:
            stage = .atStop(pending)
        default:
            if let item = pending.inboxItem { inbox.setStatus(item, .pending) }
            if old.reason == .initial { ride = nil }
            stage = .choosing
        }
        updateHealth()
    }

    /// Recalculate from where the rider is now. Automatic triggers and repeated taps
    /// share the one in-flight calculation; the gate's cooldown still applies.
    func requestReroute(_ reason: RouteReason = .manual) {
        guard case .navigating(let pending) = stage, let ride, coordinator.session != nil, !arrivalFinalized else { return }
        if operation != nil { return }
        if reason == .offRoute, case .failed = routeOperation {
            // A failed automatic reroute is retried only by the rider.
            return
        }
        requestRoute(reason, context: ride, pending: pending)
    }

    func cancelRouteOperation() {
        guard let op = operation else { return }
        provider?.cancelPreparation(op.id)
        finishOperation(op)
        record(.routeRequest(.cancelled))
        switch op.reason {
        case .initial, .recovery:
            stage = .choosing
        case .nextLeg:
            stage = .atStop(op.pending)
        default:
            break
        }
        routeOperation = .idle
        updateHealth()
    }

    func dismissRouteError() {
        if case .failed = routeOperation { routeOperation = .idle }
        updateHealth()
    }

    func stopNavigation() {
        if let op = operation {
            provider?.cancelPreparation(op.id)
            finishOperation(op)
        }
        if let proposal {
            provider?.discardPrepared(proposal.handle)
            proposal.expiry.cancel()
            self.proposal = nil
        }
        let wasRiding: Bool = switch stage {
        case .navigating, .atStop: true
        default: false
        }
        if case .preview(let pending) = stage, let item = pending.inboxItem { inbox.setStatus(item, .pending) }
        fixture?.stop()
        fixture = nil
        provider?.stop()
        coordinator.endSession()
        updateNavigationState()
        voice.reset()
        liveActivity.end()
        if wasRiding || journeyStarted, let ride, mode == .live {
            if !arrivalFinalized { history.finish(.endedByRider, now: clock.wallNow) }
            recovery.finish(ride.id, now: clock.wallNow)
        }
        ride = nil
        rideStartedAt = nil
        journeyStarted = false
        stage = .choosing
        routeOptions = []
        selectedRouteID = nil
        guidance = nil
        routeOperation = .idle
        startStatus = .idle
        previewExpired = false
        updateHealth()
        scheduleWake()
    }

    // MARK: Stops

    /// Before the stop: go straight to the final destination (new route, explicit).
    func skipStop() {
        guard case .navigating = stage, let ride, case .success(let next) = ItineraryPolicy.skipStop(ride) else { return }
        if mode == .simulation { return restartSimulation(next) }
        requestRoute(.replacement, context: next, pending: Self.pending(for: next))
    }

    /// At the stop: calculate the leg to the final destination; Start begins it.
    func continueToFinal() {
        guard case .atStop = stage, let ride, case .success(let next) = ItineraryPolicy.continueToFinal(ride) else { return }
        routeOperation = .idle
        if mode == .simulation {
            fixture = nil
            stage = .choosing
            beginSimulatedRoute(Self.pending(for: next), context: next)
            return
        }
        requestRoute(.nextLeg, context: next, pending: Self.pending(for: next), fix: .current)
    }

    /// The synthetic replay has no routes to prepare: the next leg starts at once.
    private func restartSimulation(_ next: RideContext) {
        fixture?.stop()
        coordinator.endSession()
        stage = .choosing
        beginSimulatedRoute(Self.pending(for: next), context: next)
        startNavigation()
    }

    /// Adds one stop on the way while riding (from the inbox or saved places).
    func addStop(_ stop: RideDestination, inboxItem: UUID? = nil) {
        guard case .navigating = stage, let ride else { return }
        guard !arrivalFinalized else {
            routeOperation = .failed(.replacement, "You've arrived. End this ride, then start a new one from there.")
            return
        }
        switch ItineraryPolicy.addStop(stop, to: ride) {
        case .success(let next):
            if mode == .simulation { return restartSimulation(next) }
            var pending = Self.pending(for: next)
            pending.inboxItem = inboxItem
            if let inboxItem, !inbox.setStatus(inboxItem, .accepted) {
                routeOperation = .failed(.replacement, "Couldn't save the destination's status, so no route was requested.")
                return
            }
            requestRoute(.replacement, context: next, pending: pending)
        case .failure(.alreadyHasStop):
            routeOperation = .failed(.replacement, "This ride already has a stop. Skip it first.")
        case .failure:
            routeOperation = .failed(.replacement, "A stop can't be added right now.")
        }
    }

    /// Replaces the final destination mid-ride. The old route stays until the new one is ready.
    func replaceDestination(with itemID: UUID) {
        guard case .navigating = stage, let item = inbox.item(itemID), let coordinate = item.coordinate,
              let context = RideContext(itinerary: Itinerary(final: RideDestination(
                coordinate: coordinate, label: item.label, provenance: .shared)), preferences: routePreferences)
        else { return }
        if mode == .simulation {
            inbox.consume(itemID)
            return restartSimulation(context)
        }
        var pending = Self.pending(for: context)
        pending.inboxItem = itemID
        guard inbox.setStatus(itemID, .accepted) else {
            routeOperation = .failed(.replacement, "Couldn't save the destination's status, so no route was requested.")
            return
        }
        requestRoute(.replacement, context: context, pending: pending)
    }

    static func pending(for context: RideContext) -> PendingDestination {
        let target = context.activeTarget
        return PendingDestination(coordinate: target.coordinate, label: target.label, provenance: target.provenance,
                                  stop: context.itinerary.stop)
    }

    private func handleArrival() {
        guard !arrivalFinalized, let ride else { return }
        switch ItineraryPolicy.arrival(ride) {
        case .reachedStop(let next):
            // End leg one completely: no calculation, no session, cleared dashboard,
            // nothing spoken for it. A reroute still running for leg one is retired
            // here so its gate ticket can't hold up Continue.
            retireOperation()
            fixture?.stop()
            fixture = nil
            provider?.stop()
            coordinator.endSession()
            voice.reset()
            self.ride = next
            history.breakSegment()
            history.checkpoint(now: clock.wallNow)
            recovery.commit(next, startedAt: rideStartedAt ?? clock.wallNow, now: clock.wallNow)
            guidance = nil
            stage = .atStop(Self.pending(for: next))
        case .completed:
            arrivalFinalized = true
            // Arrived: any recalculation still running is obsolete and must not commit afterwards.
            retireOperation()
            if mode == .live {
                history.finish(.completed, now: clock.wallNow)
                recovery.finish(ride.id, now: clock.wallNow)
            }
        case .ignored:
            break
        }
    }

    // MARK: Recovery

    /// Resume after an interruption: a fresh position measured after this tap, a new
    /// authorised route, a preview, then Start. Nothing old is restored as active.
    func resumeRecovery(usePending: Bool = true) {
        guard stage == .choosing, let offer = recoveryOffer else { return }
        let context: RideContext
        switch offer {
        case .resume(let intent):
            context = intent.context
            rideStartedAt = intent.startedAt
        case .unfinishedStart(let pending, let previous):
            if !usePending, let previous {
                context = previous.context
                rideStartedAt = previous.startedAt
            } else {
                context = pending.context
            }
        }
        recovery.clearPendingStart()
        if context.phase == .atStop {
            ride = context
            // Leg two continues the recording only if leg one was being recorded under current consent.
            history.resume(context.id, now: clock.wallNow)
            journeyStarted = true
            recoveryOffer = nil
            stage = .atStop(Self.pending(for: context))
            updateHealth()
            return
        }
        guard mode == .live else { return }
        requestRoute(.recovery, context: context, pending: Self.pending(for: context),
                     fix: FixRequirement(maxAge: 5, maxAccuracy: 50, measuredAfter: clock.wallNow))
    }

    func discardRecovery() {
        recovery.discard()
        recoveryOffer = nil
        updateHealth()
    }

    // MARK: Snapshots

    private func receive(_ snapshot: NavigationSnapshot) {
        counters.snapshots += 1
        if case .success = coordinator.receive(snapshot) {
            guidance = snapshot
            updateNavigationState()
            if snapshot.state == .arrived, isRiding { handleArrival() }
            updateHealth()
            if isRiding {
                voice.handle(snapshot, eligible: health.directionEligible)
                liveActivity.update(snapshot, health: health, linkReady: bike.state.isReady, staleDate: staleDate)
            }
        }
        updateNavigationState()
    }

    func repeatInstruction() {
        voice.repeatCurrent(eligible: health.directionEligible)
    }

    // MARK: Health

    private static let idleHealthInput = RideHealthInput(
        phase: .idle, position: .none, navigationState: .idle, intent: .clear(.noSession), route: .ok,
        link: .notPaired, delivery: .linkDown, voice: .off)

    /// When the newest genuine position stops being evidence, on the wall clock.
    private var staleDate: Date? {
        guard let measured = guidance?.measurementAt else { return nil }
        let remaining = (measured + RideHealthEvaluator.maxMeasurementAge).duration(since: clock.now)
        return clock.wallNow.addingTimeInterval(max(remaining.seconds, 0))
    }

    private func updateHealth() {
        let phase: RideHealthInput.Phase = switch stage {
        case .choosing: recoveryOffer == nil ? .idle : .recoveryOffered
        case .confirming, .failed: .idle
        case .requesting: .preparing
        case .preview: .preview
        case .navigating: .navigating
        case .atStop: .atStop
        }
        let position: RideHealthInput.Position
        switch locationAuthorization() {
        case .denied, .restricted:
            position = .permissionDenied
        default:
            if mode == .simulation {
                position = guidance?.measurementAt.map { .measured(age: clock.now.duration(since: $0), accuracy: 5) } ?? .none
            } else if let fix = provider?.lastFix {
                position = .measured(age: clock.now.duration(since: fix.measuredAt), accuracy: fix.sample.horizontalAccuracy)
            } else {
                position = .none
            }
        }
        let route: RideHealthInput.RouteStatus = switch routeOperation {
        case .idle: .ok
        case .preparing: .calculating
        case .failed(_, let message): .failed(message)
        }
        let link: RideHealthInput.Link = switch bike.state {
        case .ready: .ready
        case .connecting, .discovering, .reconnecting, .scanning: .connecting
        default: bike.rememberedBikeID == nil ? .notPaired : .down
        }
        let voiceState: RideHealthInput.Voice = !voiceEnabled ? .off : (voice.holdReason.map { .held($0) } ?? .ok)
        let next = RideHealthEvaluator.evaluate(RideHealthInput(
            phase: phase, position: position, navigationState: navigationState, intent: intent, route: route,
            link: link, delivery: coordinator.delivery, voice: voiceState))
        if next != health { health = next }
        voice.setEligible(isRiding && health.directionEligible)
    }

    // MARK: Scheduling

    /// One wake at the earliest deadline anyone has; none when nothing is due.
    private func scheduleWake() {
        var deadlines: [MonotonicInstant] = []
        if let due = coordinator.nextDeadline { deadlines.append(due) }
        if fixture != nil, isRiding { deadlines.append(clock.now + Self.fixtureTick) }
        if isRiding, let measured = guidance?.measurementAt {
            let expiry = measured + RideHealthEvaluator.maxMeasurementAge
            if expiry > clock.now { deadlines.append(expiry) }
        }
        guard let earliest = deadlines.min() else {
            wake?.cancel()
            wake = nil
            wakeAt = nil
            return
        }
        let at = max(earliest, clock.now + Self.minimumWake)
        if let wakeAt, wake != nil, wakeAt <= at { return }
        wake?.cancel()
        wakeAt = at
        wake = timers.schedule(after: at.duration(since: clock.now)) { [weak self] in self?.wakeUp() }
    }

    /// Processes everything due, in order: freshness and output first, then resends
    /// and status, then presentation. Reschedules itself only for future work.
    private func wakeUp() {
        wake = nil
        wakeAt = nil
        counters.wakes += 1
        fixture?.tick()
        coordinator.phoneStatus = customStatusEnabled ? customPhoneStatus : Self.currentPhoneStatus()
        coordinator.tick()
        updateNavigationState()
        updateHealth()
        if isRiding, let guidance {
            liveActivity.update(guidance, health: health, linkReady: bike.state.isReady, staleDate: staleDate)
        }
        scheduleWake()
    }

    /// After a suspension: run every overdue deadline now, before new output.
    func foregroundSafetyCheck() {
        wake?.cancel()
        wake = nil
        wakeAt = nil
        wakeUp()
    }

    private func linkChanged() {
        let link = DiagnosticsLog.LinkSummary(bike.state)
        if link != lastLinkSummary {
            lastLinkSummary = link
            record(.link(link))
        }
        updateHealth()
        scheduleWake()
    }

    var activityUpdates: Int { liveActivity.updates }

    func resetCounters() {
        counters = EnergyCounters()
    }

    private func applyEnergyMode() {
        liveActivity.minimumInterval = energySaving ? 10 : 2
        provider?.setFollowAnimations(!energySaving)
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

    /// Bench: a new clear whose own Bluetooth answer can be checked.
    func requestFreshClear() -> Int? {
        guard diagnosticsLockReason == nil, bike.state.isReady else { return nil }
        return coordinator.requestFreshClear()
    }

    func clearRequestOutcome(_ id: Int) -> DashboardDelivery? {
        coordinator.clearRequestOutcome(id)
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
            self?.propose(coordinate, label: name, provenance: .searchResult)
            self?.search.clear()
        }
    }

    /// The Bluetooth console is sending its own status packets; the app's pause meanwhile.
    func holdStatusForConsole(_ hold: Bool) {
        guard hold != consoleHoldsStatus else { return }
        consoleHoldsStatus = hold
        updateStatusPause()
        if statusProfile != nil {
            console.note(hold ? "App's status packets paused for this test." : "App's status packets resumed.")
        }
    }

    /// A call never stops navigation: guidance, dashboard arrows and voice carry on.
    /// Only the app's phone-status packets (which say "no call") pause, for the whole
    /// call and at least 15 s from the first ring, so the dashboard keeps showing it.
    private func callChanged(_ active: Bool) {
        voice.callChanged(active)
        updateHealth()
        guard active != callInProgress else { return }
        callInProgress = active
        if active {
            callHoldUntil = clock.now + Self.callHoldMinimum
            callHoldTimer?.cancel()
            callHoldTimer = timers.schedule(after: Self.callHoldMinimum) { [weak self] in
                guard let self else { return }
                callHoldUntil = nil
                callHoldTimer = nil
                updateStatusPause()
                if !callInProgress, statusProfile != nil { console.note("Call over: status packets resumed.") }
            }
        }
        updateStatusPause()
        guard statusProfile != nil else { return }
        if active {
            console.note("Phone call: status packets paused so the dashboard keeps the call.")
        } else {
            console.note(callHoldUntil == nil ? "Call over: status packets resumed."
                                              : "Call over: status packets resume 15 s after it started ringing.")
        }
    }

    /// Status packets pause while a call (and its 15 s minimum) or the console holds them.
    private func updateStatusPause() {
        let callHold = callInProgress || callHoldUntil.map { clock.now < $0 } ?? false
        coordinator.statusPaused = callHold || consoleHoldsStatus
    }

    var statusPaused: Bool { coordinator.statusPaused }

    func allowPhoneSpeaker() {
        voice.allowSpeaker()
        updateHealth()
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
        case .throttled, .locationUnavailable, .timedOut, .other: .failedOther
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
