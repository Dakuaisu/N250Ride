import MapKit
import OSLog
import RideCore
import UIKit

/// Apple MapKit guidance: one car route per explicit request or throttled reroute,
/// followed by RideCore's `GuidanceEngine` on live locations. Apple has no
/// motorcycle profile, so routes are car-profile and labelled as such. Routes are
/// held in memory for the session only (Apple Maps terms, Att. 6 §2.5).
///
/// A calculation is *prepared* without touching the active route; only
/// `commitPreparedRoute` replaces it.
@MainActor
final class AppleNavigationProvider: NSObject, LiveNavigationProvider {
    var onSnapshot: ((NavigationSnapshot) -> Void)?
    var onLongPress: ((Coordinate) -> Void)?
    var onRerouteNeeded: (() -> Void)?
    var onFix: ((AdmittedFix) -> Void)?

    let name = "Apple Maps"
    let routingLabel = "Apple Maps car route - Apple has no motorcycle routing"
    let termsNotice = """
        YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK. LOCATION DATA MAY NOT BE ACCURATE.

        Routes come from Apple Maps for cars; there is no motorcycle profile, so a route may use roads or turns \
        that are not ideal on a bike. Never handle the phone while riding.
        """
    let sdkVersion: String? = nil
    let supportsTransactionalReplacement = true
    var mapHostView: UIView { mapView }
    private(set) var termsAccepted: Bool
    private(set) var lastFix: AdmittedFix?

    private struct Prepared {
        let request: NavigationRouteRequest
        let candidates: [PlannedCandidate]
        let origin: Coordinate
    }

    private struct Active {
        let engine: GuidanceEngine
        let candidate: PlannedCandidate
    }

    private struct FixWaiter {
        let id: UUID
        let owner: LocationOwner
        let requirement: FixRequirement
        let completion: (LocationSample?) -> Void
        let timeout: TimerToken
    }

    private enum LocationOwner: Hashable {
        case acquisition(UUID), guidance, map
    }

    private let mapView = MKMapView()
    private let location: LocationClient
    private let directions: DirectionsClient
    private let clock: RideClock
    private let timers: RideTimers
    private let defaults: UserDefaults
    private var admission = LocationAdmission()
    private var lastSample: LocationSample?
    private var active: Active?
    private var prepared: [PreparedRouteHandle: Prepared] = [:]
    private var previewing: (handle: PreparedRouteHandle, option: RouteOption.ID)?
    private var pendingOperation: UUID?
    private var waiters: [FixWaiter] = []
    private var owners: Set<LocationOwner> = []
    private var overlays: [MKPolyline] = []
    private var guiding = false
    private var followAnimations = true
    private(set) var locationCallbacks = 0

    static let fixTimeout: Duration = .seconds(15)
    private static let termsKey = "appleRouteGuidanceNoticeAccepted"
    /// Counts and error codes only; never coordinates or place names.
    nonisolated private static let log = Logger(subsystem: "com.n250ride", category: "routing")

    init(clock: RideClock, timers: RideTimers, defaults: UserDefaults = .standard,
         location: LocationClient? = nil, directions: DirectionsClient? = nil) {
        self.clock = clock
        self.timers = timers
        self.defaults = defaults
        self.location = location ?? CoreLocationClient()
        self.directions = directions ?? MapKitDirectionsClient()
        termsAccepted = defaults.bool(forKey: Self.termsKey)
        super.init()
        mapView.delegate = self
        mapView.showsUserLocation = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
        self.location.onSamples = { [weak self] in self?.received($0) }
        self.location.onAuthorizationDenied = { [weak self] in self?.permissionDenied() }
    }

    func requestTerms(completion: @escaping @MainActor (Bool) -> Void) {
        termsAccepted = true
        defaults.set(true, forKey: Self.termsKey)
        completion(true)
    }

    // MARK: Prepare / commit

    func prepareRoute(_ request: NavigationRouteRequest,
                      completion: @escaping @MainActor (Result<PreparedRoute, RouteRequestFailure>) -> Void) {
        if let pendingOperation { cancelPreparation(pendingOperation) }
        let operation = request.operationID
        pendingOperation = operation
        acquire(.acquisition(operation))
        awaitFix(request.fix, owner: .acquisition(operation)) { [weak self] sample in
            guard let self, self.pendingOperation == operation else { return }
            guard let sample else {
                self.finishOperation(operation)
                completion(.failure(.locationUnavailable))
                return
            }
            let query = DirectionsQuery(origin: sample.coordinate, destination: request.target,
                                        avoidTolls: request.preferences.avoidTolls,
                                        avoidHighways: request.preferences.avoidHighways,
                                        alternatives: request.alternatives)
            Self.log.info("directions request started reason=\(request.reason.rawValue, privacy: .public)")
            self.directions.calculate(query) { [weak self] result in
                guard let self, self.pendingOperation == operation else { return }
                self.finishOperation(operation)
                switch result {
                case .success(let candidates):
                    let usable = candidates.filter {
                        GuidanceEngine(route: $0.route, session: request.session, generation: request.generation) != nil
                    }
                    guard !usable.isEmpty else {
                        completion(.failure(.other("empty route")))
                        return
                    }
                    let handle = PreparedRouteHandle(id: UUID())
                    self.prepared[handle] = Prepared(request: request, candidates: usable, origin: sample.coordinate)
                    if !self.guiding, let first = usable.first {
                        self.previewing = (handle, first.option.id)
                        self.drawRoutes()
                        self.showWholeRoute()
                    }
                    completion(.success(PreparedRoute(handle: handle, options: usable.map(\.option),
                                                      origin: sample.coordinate)))
                case .failure(let failure):
                    completion(.failure(failure))
                }
            }
        }
    }

    func previewPrepared(_ handle: PreparedRouteHandle, option: RouteOption.ID) -> Bool {
        guard !guiding, let p = prepared[handle], p.candidates.contains(where: { $0.option.id == option }) else {
            return false
        }
        previewing = (handle, option)
        drawRoutes()
        return true
    }

    func checkStart(_ handle: PreparedRouteHandle, completion: @escaping @MainActor (StartCheck) -> Void) {
        guard let p = prepared[handle] else {
            completion(.noCurrentFix)
            return
        }
        let owner = LocationOwner.acquisition(handle.id)
        dropWaiters(of: owner)
        acquire(owner)
        awaitFix(.current, owner: owner) { [weak self] sample in
            self?.release(owner)
            guard let sample else { return completion(.noCurrentFix) }
            let moved = sample.coordinate.distance(to: p.origin)
            completion(moved <= StartCheck.maxDisplacementMetres ? .ready : .movedFromOrigin(metres: Int(moved.rounded())))
        }
    }

    func commitPreparedRoute(_ handle: PreparedRouteHandle, option: RouteOption.ID) -> Bool {
        guard let p = prepared[handle], let candidate = p.candidates.first(where: { $0.option.id == option }),
              let engine = GuidanceEngine(route: candidate.route, session: p.request.session,
                                          generation: p.request.generation) else { return false }
        active = Active(engine: engine, candidate: candidate)
        prepared = [:]
        previewing = nil
        drawRoutes()
        return true
    }

    func cancelPreparation(_ operationID: UUID) {
        guard pendingOperation == operationID else { return }
        directions.cancel()
        dropWaiters(of: .acquisition(operationID))
        finishOperation(operationID)
    }

    func cancelStartCheck(_ handle: PreparedRouteHandle) {
        dropWaiters(of: .acquisition(handle.id))
        release(.acquisition(handle.id))
    }

    func discardPrepared(_ handle: PreparedRouteHandle) {
        cancelStartCheck(handle)
        prepared[handle] = nil
        if previewing?.handle == handle {
            previewing = nil
            drawRoutes()
        }
    }

    private func finishOperation(_ operation: UUID) {
        if pendingOperation == operation { pendingOperation = nil }
        release(.acquisition(operation))
    }

    // MARK: Guidance

    func startGuidance() {
        guiding = true
        drawRoutes()
        acquire(.guidance)
        mapView.setUserTrackingMode(.followWithHeading, animated: followAnimations)
        // Last, because handling this fix may end guidance at once (already at the destination).
        if let lastFix, clock.now < lastFix.expiresAt { handle(lastFix) }
    }

    func stop() {
        if let pendingOperation { cancelPreparation(pendingOperation) }
        let pending = waiters
        waiters = []
        pending.forEach { $0.timeout.cancel() }
        guiding = false
        owners = owners.filter { $0 == .map }
        updateLocationRunning()
        if let active {
            onSnapshot?(NavigationSnapshot(session: active.engine.session, generation: active.engine.generation,
                                           observedAt: clock.now, state: .stopped))
        }
        active = nil
        prepared = [:]
        previewing = nil
        drawRoutes()
        mapView.setUserTrackingMode(.none, animated: false)
    }

    func recenter() {
        if guiding || overlays.isEmpty {
            mapView.setUserTrackingMode(guiding ? .followWithHeading : .follow, animated: followAnimations)
        } else {
            showWholeRoute()
        }
    }

    func setMapVisible(_ visible: Bool) {
        mapView.showsUserLocation = visible
        if visible { acquire(.map) } else { release(.map) }
    }

    func setFollowAnimations(_ enabled: Bool) {
        followAnimations = enabled
    }

    // MARK: Location

    private func received(_ samples: [LocationSample]) {
        locationCallbacks += 1
        for sample in samples {
            guard case .success(let fix) = admission.admit(sample, receiptWall: clock.wallNow,
                                                           receiptMonotonic: clock.now) else { continue }
            lastSample = sample
            lastFix = fix
            serveWaiters(with: sample)
            handle(fix)
        }
    }

    private func handle(_ fix: AdmittedFix) {
        guard guiding, let active else { return }
        onFix?(fix)
        let update = active.engine.update(fix.fix)
        onSnapshot?(update.snapshot)
        if update.requestReroute { onRerouteNeeded?() }
    }

    /// Calls back with a sample meeting `requirement`, or nil after 15 s. Each wait
    /// has its own timeout, so an old timeout can never drain a newer wait.
    private func awaitFix(_ requirement: FixRequirement, owner: LocationOwner,
                          _ completion: @escaping (LocationSample?) -> Void) {
        if let lastSample, requirement.accepts(lastSample, now: clock.wallNow) {
            completion(lastSample)
            return
        }
        let id = UUID()
        let timeout = timers.schedule(after: Self.fixTimeout) { [weak self] in
            guard let self, let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = self.waiters.remove(at: index)
            self.updateLocationRunning()
            waiter.completion(nil)
        }
        waiters.append(FixWaiter(id: id, owner: owner, requirement: requirement, completion: completion, timeout: timeout))
        updateLocationRunning()
    }

    /// A cancelled acquisition: its waits end now (without answering) and stop holding GPS.
    private func dropWaiters(of owner: LocationOwner) {
        let dropped = waiters.filter { $0.owner == owner }
        guard !dropped.isEmpty else { return }
        waiters.removeAll { $0.owner == owner }
        dropped.forEach { $0.timeout.cancel() }
        updateLocationRunning()
    }

    var hasPendingFixWait: Bool { !waiters.isEmpty }

    private func serveWaiters(with sample: LocationSample) {
        let now = clock.wallNow
        let ready = waiters.filter { $0.requirement.accepts(sample, now: now) }
        guard !ready.isEmpty else { return }
        waiters.removeAll { waiter in ready.contains { $0.id == waiter.id } }
        for waiter in ready {
            waiter.timeout.cancel()
            waiter.completion(sample)
        }
        updateLocationRunning()
    }

    private func acquire(_ owner: LocationOwner) {
        owners.insert(owner)
        updateLocationRunning()
    }

    private func release(_ owner: LocationOwner) {
        owners.remove(owner)
        updateLocationRunning()
    }

    /// Location runs only while something owns it: an acquisition, guidance or the visible map.
    private func updateLocationRunning() {
        if owners.isEmpty && waiters.isEmpty {
            location.stop()
        } else {
            location.start(background: guiding)
        }
    }

    private func permissionDenied() {
        guard guiding, let active else { return }
        onSnapshot?(NavigationSnapshot(session: active.engine.session, generation: active.engine.generation,
                                       observedAt: clock.now, state: .failed(.locationPermissionDenied)))
    }

    // MARK: Map

    /// Alternatives in grey under the selected route in blue; while guiding only the
    /// active route is drawn. The overlay title carries the style to the renderer.
    private func drawRoutes() {
        mapView.removeOverlays(overlays)
        overlays = []
        var shown: [(candidate: PlannedCandidate, selected: Bool)] = []
        if guiding, let active {
            shown = [(active.candidate, true)]
        } else if let previewing, let p = prepared[previewing.handle] {
            shown = p.candidates.map { ($0, $0.option.id == previewing.option) }
        }
        for entry in shown.filter({ !$0.selected }) + shown.filter(\.selected) {
            let coordinates = entry.candidate.line.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
            overlay.title = entry.selected ? Self.selectedTitle : Self.alternativeTitle
            overlays.append(overlay)
        }
        mapView.addOverlays(overlays, level: .aboveRoads)
    }

    private func showWholeRoute() {
        guard let first = overlays.first else { return }
        let rect = overlays.dropFirst().reduce(first.boundingMapRect) { $0.union($1.boundingMapRect) }
        mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 120, right: 40), animated: true)
    }

    nonisolated static let selectedTitle = "selected"
    nonisolated static let alternativeTitle = "alternative"

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
        if let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude) {
            onLongPress?(coordinate)
        }
    }
}

extension AppleNavigationProvider: MKMapViewDelegate {
    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        let selected = overlay.title == Self.selectedTitle
        renderer.strokeColor = selected ? .systemBlue : .systemGray
        renderer.alpha = selected ? 1 : 0.7
        renderer.lineWidth = selected ? 7 : 5
        return renderer
    }
}
