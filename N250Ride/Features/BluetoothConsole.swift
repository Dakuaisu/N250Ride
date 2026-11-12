import Foundation
import Observation
import RideCore

/// Parked-bike Bluetooth console: send raw bytes to a chosen channel, watch the
/// dashboard's control channel for button presses, and keep a log. Safety rules:
/// locked while riding or simulating, firmware-update service never written,
/// unknown channels need confirmation, nothing longer than one write is sent.
@MainActor
@Observable
final class BluetoothConsole {
    struct Entry: Identifiable {
        enum Kind { case sent, received, info, error }
        let id = UUID()
        let time: Date
        let kind: Kind
        let channel: String
        let text: String
    }

    struct Target: Identifiable, Hashable {
        let id: String
        let name: String
        let known: Bool
    }

    struct Preset: Identifiable {
        var id: String { name }
        let name: String
        let target: String
        let bytes: [UInt8]
    }

    static let controlChannel = "0A10676E-6972-6565-6E69-676E4543544F"
    static let knownTargets: [Target] = [
        Target(id: ClusterGATT.navigation, name: "Navigation frame (0110)", known: true),
        Target(id: ClusterGATT.generalStatus, name: "Phone status (0210)", known: true),
        Target(id: PhonePackets.missedCallCharacteristic, name: "Missed call (0310)", known: true),
        Target(id: PhonePackets.alertCharacteristic, name: "Message alert (0410)", known: true),
    ]

    private(set) var entries: [Entry] = []
    private(set) var controlBytes: [UInt8] = []
    private(set) var changedControlBytes: Set<Int> = []
    @ObservationIgnored private var controlSeeded = false
    private(set) var polling = false
    var target = ClusterGATT.navigation
    var hexText = ""
    var withResponse = true
    var fixChecksum = true
    var confirmingUnknown = false

    weak var host: AppModel?
    let bike: BikeConnection
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(bike: BikeConnection) {
        self.bike = bike
        bike.onConsoleEvent = { [weak self] in self?.handle($0) }
    }

    var targets: [Target] {
        let explored = bike.gattServices.flatMap(\.characteristics)
            .filter { characteristic in
                !BikeConnection.isBlocked(characteristic.id)
                    && !Self.knownTargets.contains { $0.id == characteristic.id.uppercased() }
                    && (characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse))
            }
            .map { Target(id: $0.id.uppercased(), name: "Unknown \($0.id.prefix(8))", known: false) }
        return Self.knownTargets + explored
    }

    var parsed: [UInt8]? { HexBytes.parse(hexText) }

    var isNavigationTarget: Bool { target == ClusterGATT.navigation }

    /// Decoded view of a navigation frame being edited.
    var framePreview: TbtFrameSummary? {
        guard isNavigationTarget, let bytes = parsed else { return nil }
        return TbtFrameSummary(frame: fixChecksum ? Self.withChecksum(bytes) : bytes)
    }

    func send(confirmed: Bool = false) {
        if let reason = host?.diagnosticsLockReason { return log(.error, target, "Refused: \(reason)") }
        guard let bytes = parsed else { return log(.error, target, "Not valid hex.") }
        if isNavigationTarget {
            guard bytes.count == TbtFrame.length else {
                return log(.error, target, "A navigation frame is exactly 48 bytes (this is \(bytes.count)).")
            }
            let frame = fixChecksum ? Self.withChecksum(bytes) : bytes
            if let problem = host?.sendConsoleFrame(frame) { return log(.error, target, problem) }
            return log(.sent, target, HexBytes.format(frame) + "  (shown for 5 s)")
        }
        let known = Self.knownTargets.contains { $0.id == target }
        if !known, !confirmed {
            confirmingUnknown = true
            return
        }
        if let problem = bike.rawWrite(bytes, to: target, withResponse: withResponse) {
            return log(.error, target, problem)
        }
        log(.sent, target, HexBytes.format(bytes))
    }

    func clearDashboard() {
        if let reason = host?.clearTestFrame() {
            return log(.error, ClusterGATT.navigation, "Refused: \(reason)")
        }
        log(.info, ClusterGATT.navigation, "Clear sent")
    }

    func use(_ preset: Preset) {
        target = preset.target
        hexText = HexBytes.format(preset.bytes)
        fixChecksum = true
    }

    func explore() {
        guard bike.state.isReady else { return log(.error, "-", "Bike not connected.") }
        bike.exploreGatt()
        log(.info, "-", "Exploring services…")
    }

    /// Explores once per connection so the button channel and service list are ready.
    func appeared() {
        if bike.state.isReady, bike.gattServices.isEmpty { explore() }
    }

    func setPolling(_ on: Bool) {
        pollTask?.cancel()
        polling = on
        guard on else { return }
        controlBytes = []
        changedControlBytes = []
        controlSeeded = false
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let problem = bike.rawRead(Self.controlChannel) {
                    log(.error, Self.controlChannel, problem)
                    polling = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stop() {
        setPolling(false)
        host?.clearTestFrame()
    }

    func clearLog() {
        entries = []
    }

    var exportText: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
        return entries.reversed().map { entry in
            "\(formatter.string(from: entry.time)) \(entry.kind) \(Self.short(entry.channel)) \(entry.text)"
        }.joined(separator: "\n")
    }

    static func short(_ channel: String) -> String {
        channel.count > 8 ? String(channel.prefix(4)) : channel
    }

    static func withChecksum(_ frame: [UInt8]) -> [UInt8] {
        guard frame.count == TbtFrame.length else { return frame }
        var b = frame
        b[47] = TbtFrame.checksum(b)
        return b
    }

    private func handle(_ event: ConsoleLinkEvent) {
        switch event {
        case .wrote(let channel, let error):
            log(error == nil ? .info : .error, channel, error.map { "Write failed: \($0)" } ?? "Write acknowledged")
        case .read(let channel, let bytes, let error):
            if let error { return log(.error, channel, "Read failed: \(error)") }
            let bytes = bytes ?? []
            guard channel.uppercased() == Self.controlChannel else {
                return log(.received, channel, bytes.isEmpty ? "(empty, 0 bytes)" : HexBytes.format(bytes))
            }
            if !controlSeeded {
                controlSeeded = true
                controlBytes = bytes
                log(.received, channel, bytes.isEmpty
                    ? "First sample: empty (0 bytes). Watching for changes…"
                    : "First sample (\(bytes.count) bytes): " + HexBytes.format(bytes))
                return
            }
            let changed = Set((0..<max(bytes.count, controlBytes.count)).filter {
                !controlBytes.indices.contains($0) || !bytes.indices.contains($0) || controlBytes[$0] != bytes[$0]
            })
            guard !changed.isEmpty else { return }
            if bytes.isEmpty || controlBytes.isEmpty {
                log(.received, channel, "Length changed \(controlBytes.count) → \(bytes.count) bytes: "
                    + (bytes.isEmpty ? "(empty)" : HexBytes.format(bytes)))
                changedControlBytes = Set(bytes.indices)
                controlBytes = bytes
                return
            }
            let detail = changed.sorted().map { index in
                let old = controlBytes.indices.contains(index) ? HexBytes.format([controlBytes[index]]) : "--"
                let new = bytes.indices.contains(index) ? HexBytes.format([bytes[index]]) : "--"
                return "byte \(index): \(old)→\(new)"
            }.joined(separator: ", ")
            changedControlBytes = changed
            controlBytes = bytes
            log(.received, channel, detail)
        case .explored(let services):
            for service in services {
                let characteristics = service.characteristics.map { characteristic in
                    "\(characteristic.id.prefix(8)) \(BluetoothConsoleView.describe(characteristic.properties))"
                        + (BikeConnection.isBlocked(characteristic.id) ? " BLOCKED" : "")
                }
                log(.info, service.id, "Service \(service.id): " + characteristics.joined(separator: "; "))
            }
        }
    }

    private func log(_ kind: Entry.Kind, _ channel: String, _ text: String) {
        entries.insert(Entry(time: Date(), kind: kind, channel: channel, text: text), at: 0)
        if entries.count > 300 { entries.removeLast() }
    }

    // MARK: Presets

    static func presets(statusProfile: GeneralStatusProfile) -> [Preset] {
        let now = UInt32(Date().timeIntervalSince1970)
        let base = TbtFields(frameType: .navigation, icon: ClusterIcon.straight, isAM: true,
                             stepMetres: 300, totalMetres: 4_200, etaHour: 9, etaMinute: 30)
        let frame = (try? TbtFrame.encode(base)) ?? TbtFrame.stop()
        func gps(_ value: UInt8) -> [UInt8] {
            var b = frame
            b[12] = (b[12] & ~0x0C) | (value << 2)
            return withChecksum(b)
        }
        func type(_ value: UInt8) -> [UInt8] {
            var b = frame
            b[0] = (b[0] & ~0x03) | value
            return withChecksum(b)
        }
        var text = base
        text.text = "TEST TEXT"
        let status = ClusterGATT.generalStatus
        return [
            Preset(name: "Turn frame, GPS active (1)", target: ClusterGATT.navigation, bytes: gps(1)),
            Preset(name: "Turn frame, GPS off (0) - 'NO GPS'?", target: ClusterGATT.navigation, bytes: gps(0)),
            Preset(name: "Turn frame, GPS searching (2)", target: ClusterGATT.navigation, bytes: gps(2)),
            Preset(name: "Turn frame, type 2 - 'REROUTING'?", target: ClusterGATT.navigation, bytes: type(2)),
            Preset(name: "Turn frame, type 3", target: ClusterGATT.navigation, bytes: type(3)),
            Preset(name: "Turn frame with text", target: ClusterGATT.navigation,
                   bytes: (try? TbtFrame.encode(text)) ?? frame),
            Preset(name: "Missed call from TEST", target: PhonePackets.missedCallCharacteristic,
                   bytes: PhonePackets.missedCall(name: "TEST", number: "9999999999", epochSeconds: now)),
            Preset(name: "SMS alert from TEST", target: PhonePackets.alertCharacteristic,
                   bytes: PhonePackets.alert(.sms, sender: "TEST", epochSeconds: now)),
            Preset(name: "WhatsApp alert from TEST", target: PhonePackets.alertCharacteristic,
                   bytes: PhonePackets.alert(.whatsApp, sender: "TEST", epochSeconds: now)),
            Preset(name: "Incoming call 'TEST' (\(statusProfile.rawValue))", target: status,
                   bytes: GeneralStatusEncoder.encode(statusProfile, GeneralStatusFields(
                       heartbeat: 1, callState: .incoming, callerName: "TEST"))),
            Preset(name: "Call ended (\(statusProfile.rawValue))", target: status,
                   bytes: GeneralStatusEncoder.encode(statusProfile, GeneralStatusFields(heartbeat: 2, callState: .ended))),
        ]
    }
}
