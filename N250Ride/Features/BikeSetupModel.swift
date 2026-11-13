import Foundation
import Observation
import RideCore

/// What one observation established. Transport results and what the rider saw are
/// recorded separately: a write acknowledgement never counts as "the rider saw it".
enum SetupObservation: String, Codable, CaseIterable {
    case notRun, pass, fail, inconclusive

    var label: String {
        switch self {
        case .notRun: "Not checked"
        case .pass: "Pass"
        case .fail: "Fail"
        case .inconclusive: "Inconclusive"
        }
    }
}

/// The evidence for one bike, tied to the app and calibration it was gathered with.
struct BikeCapabilityReport: Codable, Equatable {
    static let calibration = "n250-roundabout-2026-11-12"

    var appVersion: String
    var calibration: String
    var statusProfile: String?
    var date: Date
    var gatt = SetupObservation.notRun
    var writeMode = ""
    var maximumWrite = 0
    /// Bytes accepted by the bike's Bluetooth (not proof of display).
    var clearTransport = SetupObservation.notRun
    var samples: [String: SetupObservation] = [:]
    var stopFrameVisual = SetupObservation.notRun
    var statusVisual = SetupObservation.notRun
    var reconnect = SetupObservation.notRun

    /// Out of date when the app's calibration or the status packet changed since.
    func isCurrent(statusProfile: GeneralStatusProfile?) -> Bool {
        calibration == Self.calibration && self.statusProfile == statusProfile?.rawValue
    }

    var verdict: String {
        let visual = Array(samples.values) + [stopFrameVisual]
        if gatt == .fail || visual.contains(.fail) { return "Not compatible as tested" }
        if gatt == .pass, !visual.isEmpty, visual.allSatisfy({ $0 == .pass }), samples.count == BikeSetupModel.samples.count {
            return "Works as tested (parked)"
        }
        return "Inconclusive - some checks not done"
    }
}

/// Parked, ordered compatibility check for the bike the app is connected to. Uses
/// the existing connection and the fixed diagnostic frames only: no exploration,
/// no unknown channels, no firmware services.
@MainActor
@Observable
final class BikeSetupModel {
    enum Step: Int, CaseIterable {
        case parked, connect, link, clear, samples, stopFrame, status, reconnect, report

        var title: String {
            switch self {
            case .parked: "Park safely"
            case .connect: "Connect"
            case .link: "Bluetooth check"
            case .clear: "Clear the dashboard"
            case .samples: "Test directions"
            case .stopFrame: "Navigation off"
            case .status: "Phone status (optional)"
            case .reconnect: "Reconnect"
            case .report: "Report"
            }
        }
    }

    struct Sample: Identifiable, Sendable {
        let id: String
        let label: String
        let maneuver: Maneuver
        let metres: Int
    }

    nonisolated static let samples = [
        Sample(id: "left", label: "Left turn, 250 m", maneuver: .turnLeft, metres: 250),
        Sample(id: "right", label: "Right turn, 250 m", maneuver: .turnRight, metres: 250),
        Sample(id: "straight", label: "Straight, 1.2 km", maneuver: .straight, metres: 1_200),
        Sample(id: "arrival", label: "Destination reached", maneuver: .arrival, metres: 0),
    ]

    private(set) var step: Step = .parked
    private(set) var report: BikeCapabilityReport
    private(set) var message: String?
    private(set) var saved: [String: BikeCapabilityReport] = [:]

    @ObservationIgnored weak var host: AppModel?
    @ObservationIgnored private let file: RecordFile<[String: BikeCapabilityReport]>
    @ObservationIgnored private let appVersion: String

    init(directory: URL, appVersion: String) {
        file = RecordFile(directory: directory, name: "bike-reports.json", schemaVersion: 1, maxBytes: 64 * 1_024)
        self.appVersion = appVersion
        report = BikeCapabilityReport(appVersion: appVersion, calibration: BikeCapabilityReport.calibration, date: Date())
        saved = (try? file.load()) ?? [:]
    }

    func savedReport(for bike: UUID?) -> BikeCapabilityReport? {
        bike.flatMap { saved[$0.uuidString] }
    }

    func begin() {
        report = BikeCapabilityReport(appVersion: appVersion, calibration: BikeCapabilityReport.calibration,
                                      statusProfile: host?.statusProfile?.rawValue, date: Date())
        message = nil
        step = .parked
    }

    func cancel() {
        host?.clearTestFrame()
        step = .parked
        message = nil
    }

    /// Moves on; refused while a required observation is missing.
    func next() {
        guard let host else { return }
        message = nil
        switch step {
        case .parked:
            if let reason = host.diagnosticsLockReason { return message = reason }
        case .connect:
            guard host.bike.state.isReady else { return message = "Connect to the bike on the Bike tab first." }
            if case .ready(let info) = host.bike.state {
                report.gatt = .pass
                report.writeMode = info.navigationWriteMode == .withResponse ? "acknowledged" : "unacknowledged"
                report.maximumWrite = info.maximumWriteLength
            }
        case .link:
            break
        case .clear:
            guard report.clearTransport != .notRun else { return message = "Send the clear first." }
        case .samples:
            guard Self.samples.allSatisfy({ (report.samples[$0.id] ?? .notRun) != .notRun }) else {
                return message = "Record what the dashboard showed for every sample."
            }
        case .stopFrame:
            guard report.stopFrameVisual != .notRun else { return message = "Record whether the arrow disappeared." }
        case .status, .reconnect:
            break
        case .report:
            return
        }
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
        if step == .report { save() }
    }

    /// Clears the dashboard and records only what the Bluetooth layer can tell.
    func sendClear() {
        guard let host, allowed(host) else { return }
        host.clearTestFrame()
        switch host.dashboardDelivery {
        case .clearTransportAcknowledged:
            report.clearTransport = .pass
        case .clearHandedOffWithoutResponse, .clearPending:
            report.clearTransport = .inconclusive
            message = "Sent; this bike doesn't confirm writes, so delivery is unconfirmed."
        default:
            report.clearTransport = .fail
        }
    }

    func send(_ sample: Sample) {
        guard let host, allowed(host) else { return }
        host.sendTestFrame(sample.maneuver, stepMetres: sample.metres)
    }

    func observe(_ sample: Sample, _ observation: SetupObservation) {
        report.samples[sample.id] = observation
    }

    func sendStopFrame() {
        guard let host, allowed(host) else { return }
        host.sendTestFrame(.turnRight, stepMetres: 300)
        host.clearTestFrame()
    }

    func observeStopFrame(_ observation: SetupObservation) {
        report.stopFrameVisual = observation
    }

    func observeStatus(_ observation: SetupObservation) {
        report.statusVisual = observation
    }

    func observeReconnect(_ observation: SetupObservation) {
        report.reconnect = observation
    }

    func forget(_ bike: UUID) {
        saved[bike.uuidString] = nil
        try? file.save(saved)
    }

    private func allowed(_ host: AppModel) -> Bool {
        if let reason = host.diagnosticsLockReason {
            message = reason
            return false
        }
        guard host.bike.state.isReady else {
            message = "Bike not connected."
            return false
        }
        return true
    }

    private func save() {
        guard let bike = host?.bike.rememberedBikeID else { return }
        report.date = Date()
        saved[bike.uuidString] = report
        do {
            try file.save(saved)
        } catch {
            message = "The report couldn't be saved on this phone."
        }
    }
}
