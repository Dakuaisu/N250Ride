import CoreBluetooth
import Foundation
import Observation
import RideCore

struct DiscoveredBike: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

struct GattCharacteristicInfo: Identifiable, Equatable {
    let id: String
    let serviceID: String
    let properties: CharacteristicProperties

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.serviceID == b.serviceID && a.properties == b.properties }
}

struct GattServiceInfo: Identifiable, Equatable {
    let id: String
    var characteristics: [GattCharacteristicInfo]
}

/// Results of console operations, reported back to the Bluetooth console.
enum ConsoleLinkEvent {
    /// The bike acknowledged (or rejected) an acknowledged write.
    case wrote(characteristic: String, error: String?)
    /// Handed to Bluetooth without any acknowledgement from the bike.
    case submitted(characteristic: String)
    case read(characteristic: String, bytes: [UInt8]?, error: String?)
    case explored([GattServiceInfo])
}

/// Owns the CoreBluetooth link to the cluster: bounded discovery, explicit bike
/// selection by peripheral identifier (never by name alone), characteristic
/// validation, state restoration and bounded reconnection. Every delegate callback
/// arrives on the main queue and is handled on the main actor.
@MainActor
@Observable
final class BikeConnection: NSObject {
    private(set) var state: BikeLinkState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    @ObservationIgnored var onStateChange: ((BikeLinkState) -> Void)?
    private(set) var discovered: [DiscoveredBike] = []
    private(set) var rememberedBikeID: UUID?
    /// Filled by `exploreGatt()` for the Bluetooth console.
    private(set) var gattServices: [GattServiceInfo] = []
    @ObservationIgnored var onConsoleEvent: ((ConsoleLinkEvent) -> Void)?
    @ObservationIgnored private var exploring = false
    @ObservationIgnored private var router = WriteCompletionRouter()

    @ObservationIgnored private let coordinator: SessionCoordinator
    @ObservationIgnored private let clock: RideClock
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let policy = ReconnectPolicy()
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var transport: CoreBluetoothClusterTransport?
    @ObservationIgnored private var pump: ClusterWritePump?
    @ObservationIgnored private var wantConnection = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var scanTimeout: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTimeout: Task<Void, Never>?
    @ObservationIgnored private var lifecycle = BikeLinkLifecycle()

    static let restoreIdentifier = "com.n250ride.cluster-central"
    private static let rememberedKey = "rememberedBikeID"
    private static let scanDuration: Duration = .seconds(10)
    private static let connectTimeout: Duration = .seconds(15)
    private static let discoveryLimit: Duration = .seconds(15)

    private let serviceUUID = CBUUID(string: ClusterGATT.service)
    private let navigationUUID = CBUUID(string: ClusterGATT.navigation)
    private let statusUUID = CBUUID(string: ClusterGATT.generalStatus)
    /// Button channel (read-only on Pulsar clusters); discovered up front for the console.
    private let controlUUID = CBUUID(string: "0A10676E-6972-6565-6E69-676E4543544F")

    init(coordinator: SessionCoordinator, clock: RideClock, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.clock = clock
        self.defaults = defaults
        rememberedBikeID = defaults.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
        super.init()
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        #if os(iOS)
        options[CBCentralManagerOptionRestoreIdentifierKey] = Self.restoreIdentifier
        #endif
        central = CBCentralManager(delegate: self, queue: .main, options: options)
        coordinator.onWriteEvent = { [weak self] event in
            switch event {
            case .unhealthy, .timedOut:
                // A timed-out acknowledged write leaves the link's ordering unknown:
                // retire it and start clean (the new link clears before anything else).
                self?.dropLinkForReconnect()
            default:
                break
            }
        }
    }

    // MARK: User actions

    /// Foreground-only bounded scan. The custom service may not be advertised, so
    /// the scan is unfiltered; nothing connects until the rider picks a bike.
    func scan() {
        guard central.state == .poweredOn else { return }
        discovered = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            .map { DiscoveredBike(id: $0.identifier, name: $0.name ?? "Connected device", rssi: 0) }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.scanDuration)
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        scanTimeout?.cancel()
        if central.isScanning { central.stopScan() }
        if state == .scanning { state = .idle }
    }

    func select(_ bike: DiscoveredBike) {
        rememberedBikeID = bike.id
        defaults.set(bike.id.uuidString, forKey: Self.rememberedKey)
        stopScan()
        connectRemembered()
    }

    func connectRemembered() {
        guard let id = rememberedBikeID, central.state == .poweredOn,
              let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        wantConnection = true
        attempt = 0
        connect(target)
    }

    func disconnect() {
        wantConnection = false
        retryTask?.cancel()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        tearDownLink()
        state = .idle
    }

    var linkEpoch: Int { lifecycle.epoch }

    /// Clears the remembered bike; the rider must scan and pick again.
    func forgetBike() {
        disconnect()
        rememberedBikeID = nil
        defaults.removeObject(forKey: Self.rememberedKey)
    }

    // MARK: Link lifecycle

    // MARK: Bluetooth console (parked bike only; the console enforces when)

    /// Texas Instruments firmware-update families seen on Pulsar clusters: OAD image
    /// transfer and control (F000FFC_) and OAD reset (F000FFD_). Never written to,
    /// because a bad write could brick the dashboard.
    static func isBlocked(_ characteristic: String) -> Bool {
        let id = characteristic.uppercased()
        return id.hasPrefix("F000FFC") || id.hasPrefix("F000FFD")
    }

    /// Also refuses any characteristic inside a firmware-update service, whatever its own UUID.
    static func isBlocked(_ characteristic: String, service: String) -> Bool {
        isBlocked(characteristic) || isBlocked(service)
    }

    func exploreGatt() {
        guard state.isReady, let peripheral else { return }
        exploring = true
        peripheral.discoverServices(nil)
    }

    /// Writes raw bytes; returns a reason when refused. Navigation frames go through
    /// the session (so they are held and cleared like test frames), and the status
    /// channel only while the app is not sending its own status packets.
    func rawWrite(_ bytes: [UInt8], to uuid: String, withResponse: Bool) -> String? {
        guard state.isReady, let peripheral else { return "Bike not connected." }
        guard !Self.isBlocked(uuid) else { return "Blocked: firmware-update service." }
        guard uuid.uppercased() != ClusterGATT.navigation else { return "Use the navigation frame sender for this channel." }
        if uuid.uppercased() == ClusterGATT.generalStatus, coordinator.statusProfile != nil, !coordinator.statusPaused {
            return "Set Status packet to Off in Diagnostics first, so the app's own packets don't interfere."
        }
        guard let characteristic = characteristic(uuid) else { return "Channel not found. Explore services first." }
        if let service = characteristic.service, Self.isBlocked(uuid, service: service.uuid.uuidString) {
            return "Blocked: firmware-update service."
        }
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        let canWrite = withResponse ? characteristic.properties.contains(.write)
                                    : characteristic.properties.contains(.writeWithoutResponse)
        guard canWrite else { return "This channel doesn't accept \(withResponse ? "acknowledged" : "unacknowledged") writes." }
        let maximum = peripheral.maximumWriteValueLength(for: type)
        guard bytes.count <= maximum else { return "Too long: \(bytes.count) bytes, the bike accepts at most \(maximum)." }
        if withResponse {
            guard case .success(let id) = router.beginRaw(characteristic.uuid.uuidString,
                                                         pumpBusyOn: pump?.inFlightChannel) else {
                return "The app's own write on this channel is still waiting for the bike. Try again in a moment."
            }
            watchRawWrite(id, on: peripheral.identifier)
        } else {
            guard peripheral.canSendWriteWithoutResponse else {
                return "Bluetooth is busy sending. Try again in a moment."
            }
        }
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
        if !withResponse { onConsoleEvent?(.submitted(characteristic: uuid)) }
        return nil
    }

    /// A raw write the bike never answers leaves the link's answer order unknown and
    /// holds its channel: after the same 3 s as the app's own writes, the link is retired.
    private func watchRawWrite(_ id: Int, on target: UUID) {
        let epoch = lifecycle.epoch
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.lifecycle.owns(target, epoch: epoch), self.router.isPending(id) else { return }
            self.onConsoleEvent?(.wrote(characteristic: "-", error: "No answer from the bike in 3 s; reconnecting."))
            self.dropLinkForReconnect()
        }
    }

    func rawRead(_ uuid: String) -> String? {
        guard state.isReady, let peripheral else { return "Bike not connected." }
        guard let characteristic = characteristic(uuid) else { return "Channel not found. Explore services first." }
        guard characteristic.properties.contains(.read) else { return "This channel can't be read." }
        peripheral.readValue(for: characteristic)
        return nil
    }

    private func characteristic(_ uuid: String) -> CBCharacteristic? {
        let wanted = CBUUID(string: uuid)
        return peripheral?.services?.lazy.compactMap { $0.characteristics?.first { $0.uuid == wanted } }.first
    }

    private func recordGatt() {
        let services = peripheral?.services ?? []
        gattServices = services.map { service in
            GattServiceInfo(id: service.uuid.uuidString, characteristics: (service.characteristics ?? []).map {
                GattCharacteristicInfo(id: $0.uuid.uuidString, serviceID: service.uuid.uuidString,
                                       properties: Self.properties($0.properties))
            })
        }
        if exploring, !services.isEmpty, services.allSatisfy({ $0.characteristics != nil }) {
            exploring = false
            onConsoleEvent?(.explored(gattServices))
        }
    }

    private func connect(_ target: CBPeripheral) {
        let (epoch, replaced) = lifecycle.begin(target.identifier)
        if let replaced, let old = peripheral, old.identifier == replaced {
            // Switching bikes: the old link is cancelled and torn down before the new one starts.
            old.delegate = nil
            central.cancelPeripheralConnection(old)
            tearDownLink(retire: false)
        }
        peripheral = target
        target.delegate = self
        state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
        central.connect(target, options: nil)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, self.lifecycle.owns(target.identifier, epoch: epoch),
                  target.state != .connected else { return }
            self.central.cancelPeripheralConnection(target)
            self.scheduleRetry(after: .connectTimeout)
        }
    }

    private func startDiscoveryTimeout(for target: CBPeripheral) {
        let epoch = lifecycle.epoch
        discoveryTimeout?.cancel()
        discoveryTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.discoveryLimit)
            guard !Task.isCancelled, let self, self.lifecycle.owns(target.identifier, epoch: epoch),
                  self.state == .discovering else { return }
            self.central.cancelPeripheralConnection(target)
            self.scheduleRetry(after: .connectTimeout)
        }
    }

    private func scheduleRetry(after failure: BikeLinkFailure) {
        tearDownLink()
        guard wantConnection, let target = peripheral else {
            state = .failed(failure)
            return
        }
        attempt += 1
        guard let delay = policy.delay(beforeAttempt: attempt) else {
            wantConnection = false
            state = .failed(.gaveUp(attempts: attempt - 1))
            return
        }
        state = .reconnecting(attempt: attempt)
        retryTask?.cancel()
        let epoch = lifecycle.epoch
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.wantConnection,
                  self.lifecycle.owns(target.identifier, epoch: epoch) else { return }
            self.connect(target)
        }
    }

    private func dropLinkForReconnect() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    private func tearDownLink(retire: Bool = true) {
        discoveryTimeout?.cancel()
        if retire { lifecycle.retire() }
        exploring = false
        router.reset()
        gattServices = []
        coordinator.linkLost()
        pump = nil
        transport = nil
    }

    private func linkValidated(_ info: ClusterLinkInfo, navigation: CBCharacteristic, status: CBCharacteristic?) {
        guard let peripheral, lifecycle.validated(peripheral.identifier, epoch: lifecycle.epoch) else { return }
        retryTask?.cancel()
        discoveryTimeout?.cancel()
        attempt = 0
        let transport = CoreBluetoothClusterTransport(peripheral: peripheral, navigation: navigation, status: status)
        let pump = ClusterWritePump(transport: transport, clock: clock, link: info)
        pump.isChannelHeld = { [weak self] channel in self?.router.holds(channel) ?? false }
        self.transport = transport
        self.pump = pump
        state = .ready(info)
        coordinator.linkReady(pump)
    }

    private func handleStateChange() {
        switch central.state {
        case .poweredOn:
            if case .unavailable = state { state = .idle }
            if wantConnection || peripheral == nil { connectRemembered() }
        case .poweredOff:
            tearDownLink()
            state = .unavailable(.poweredOff)
        case .unauthorized:
            state = .unavailable(.unauthorized)
        case .unsupported:
            state = .unavailable(.unsupported)
        case .resetting:
            tearDownLink()
            state = .unavailable(.resetting)
        default:
            break
        }
    }
}

extension BikeConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { handleStateChange() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        let id = restored?.identifier
        MainActor.assumeIsolated {
            guard let id, id == rememberedBikeID,
                  let target = self.central.retrievePeripherals(withIdentifiers: [id]).first else { return }
            wantConnection = true
            peripheral = target
            target.delegate = self
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            guard let name, !name.isEmpty else { return }
            if let index = discovered.firstIndex(where: { $0.id == id }) {
                discovered[index].rssi = rssi
            } else {
                discovered.append(DiscoveredBike(id: id, name: name, rssi: rssi))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard let current = self.peripheral, current.identifier == id, lifecycle.isCurrent(id) else { return }
            state = .discovering
            startDiscoveryTimeout(for: current)
            current.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id, lifecycle.isCurrent(id) else { return }
            scheduleRetry(after: .connectTimeout)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id else { return }
            if wantConnection {
                scheduleRetry(after: .connectTimeout)
            } else {
                tearDownLink()
                state = .idle
            }
        }
    }
}

extension BikeConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id, lifecycle.isCurrent(id) else { return }
            // Once the link is up, discovery only serves the console's service list.
            if state.isReady {
                for service in self.peripheral?.services ?? [] {
                    self.peripheral?.discoverCharacteristics(nil, for: service)
                }
                recordGatt()
                return
            }
            guard let service = self.peripheral?.services?.first(where: { $0.uuid == serviceUUID }) else {
                wantConnection = false
                if let current = self.peripheral { central.cancelPeripheralConnection(current) }
                tearDownLink()
                state = .failed(.serviceNotFound)
                return
            }
            self.peripheral?.discoverCharacteristics([navigationUUID, statusUUID, controlUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id, lifecycle.isCurrent(id) else { return }
            if state.isReady {
                recordGatt()
                return
            }
            guard let current = self.peripheral,
                  let clusterService = current.services?.first(where: { $0.uuid == serviceUUID }) else { return }
            let characteristics = clusterService.characteristics ?? []
            let navigation = characteristics.first { $0.uuid == navigationUUID }
            let status = characteristics.first { $0.uuid == statusUUID }
            let result = ClusterGATT.validate(
                serviceFound: true,
                navigation: navigation.map { Self.properties($0.properties) },
                status: status.map { Self.properties($0.properties) },
                maximumWriteLength: { mode in
                    current.maximumWriteValueLength(for: mode == .withResponse ? .withResponse : .withoutResponse)
                }
            )
            switch result {
            case .success(let info):
                if let navigation { linkValidated(info, navigation: navigation, status: status) }
            case .failure(let failure):
                wantConnection = false
                central.cancelPeripheralConnection(current)
                tearDownLink()
                state = .failed(failure)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        let id = peripheral.identifier
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            // Only the current bike's answers count; anything else belongs to a link that's gone.
            guard self.peripheral?.identifier == id, lifecycle.isCurrent(id) else { return }
            switch router.complete(uuid) {
            case .raw:
                onConsoleEvent?(.wrote(characteristic: uuid, error: message))
                pump?.channelReleased()
            case .pump(let channel):
                pump?.didCompleteWrite(on: channel, success: message == nil)
            case .none:
                break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let uuid = characteristic.uuid.uuidString
        let id = peripheral.identifier
        let bytes = characteristic.value.map { [UInt8]($0) }
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id, lifecycle.isCurrent(id) else { return }
            onConsoleEvent?(.read(characteristic: uuid, bytes: bytes, error: message))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id, lifecycle.isCurrent(id) else { return }
            pump?.transportReadyForWriteWithoutResponse()
        }
    }

    private static func properties(_ p: CBCharacteristicProperties) -> CharacteristicProperties {
        var result: CharacteristicProperties = []
        if p.contains(.read) { result.insert(.read) }
        if p.contains(.write) { result.insert(.write) }
        if p.contains(.writeWithoutResponse) { result.insert(.writeWithoutResponse) }
        if p.contains(.notify) { result.insert(.notify) }
        return result
    }
}

/// Bridges the RideCore write pump to one connected peripheral.
final class CoreBluetoothClusterTransport: ClusterWriteTransport {
    private let peripheral: CBPeripheral
    private let navigation: CBCharacteristic
    private let status: CBCharacteristic?

    init(peripheral: CBPeripheral, navigation: CBCharacteristic, status: CBCharacteristic?) {
        self.peripheral = peripheral
        self.navigation = navigation
        self.status = status
    }

    func maximumWriteLength(for mode: WriteMode) -> Int {
        peripheral.maximumWriteValueLength(for: mode == .withResponse ? .withResponse : .withoutResponse)
    }

    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }

    func write(_ bytes: [UInt8], to channel: ClusterChannel, mode: WriteMode) {
        guard let characteristic = channel == .navigation ? navigation : status else { return }
        peripheral.writeValue(Data(bytes), for: characteristic, type: mode == .withResponse ? .withResponse : .withoutResponse)
    }
}
