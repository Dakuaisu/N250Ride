import Foundation
import Observation
import RideCore

/// Opt-in ride summaries, kept on this phone only: at most 100 rides or 30 days,
/// excluded from backups. Each summary holds times and an estimated distance;
/// never positions, a track, or place names from Apple Maps.
@MainActor
@Observable
final class RideHistoryStore {
    private struct Contents: Codable {
        /// Consent token; nil when history is off. A new token per enable.
        var consentEpoch: UUID?
        var rides: [RideSummary] = []
        var draft: RideSummary?
        /// Rides the rider deleted while still resumable; never recreated.
        var deleted: [RideID] = []
    }

    private struct Recording {
        let id: RideID
        let startedAt: Date
        let epoch: UUID
        var accumulator: RideAccumulator
        var revision: Int
        var lastFlush: Date
    }

    static let draftInterval: TimeInterval = 60

    private(set) var rides: [RideSummary] = []
    private(set) var problem: String?
    var enabled: Bool { contents.consentEpoch != nil }

    @ObservationIgnored private var contents = Contents()
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private let file: RecordFile<Contents>

    init(directory: URL, now: Date) {
        file = RecordFile(directory: directory, name: "history.json", schemaVersion: 1, maxBytes: 512 * 1_024)
        do {
            contents = try file.load() ?? Contents()
        } catch {
            problem = "Ride history couldn't be read."
        }
        // A draft left by a stopped app becomes an interrupted ride at its last observation.
        var changed = false
        if let draft = contents.draft {
            upsert(draft)
            contents.draft = nil
            changed = true
        }
        let kept = RideHistoryPolicy.pruned(contents.rides, now: now)
        changed = changed || kept != contents.rides
        contents.rides = kept
        rides = contents.rides
        if changed { save() }
    }

    func setEnabled(_ on: Bool) {
        if on {
            guard contents.consentEpoch == nil else { return }
            contents.consentEpoch = UUID()
        } else {
            contents.consentEpoch = nil
            contents.draft = nil
            recording = nil
        }
        save()
    }

    /// Whether this ride ended for good (and must not be offered for recovery).
    func isFinished(_ id: RideID) -> Bool {
        contents.rides.contains { $0.id == id && $0.outcome.isTerminal }
    }

    /// Starts recording if history is on now. A resumed ride continues from its saved
    /// totals only under the same consent it started with.
    func begin(_ id: RideID, startedAt: Date, now: Date) {
        guard let epoch = contents.consentEpoch, !contents.deleted.contains(id) else {
            recording = nil
            return
        }
        if let previous = contents.rides.first(where: { $0.id == id }) {
            guard previous.consentEpoch == epoch, !previous.outcome.isTerminal else {
                recording = nil
                return
            }
            recording = Recording(id: id, startedAt: previous.startedAt, epoch: epoch,
                                  accumulator: RideAccumulator(baselineSeconds: previous.activeSeconds,
                                                               baselineMetres: previous.estimatedMetres),
                                  revision: previous.revision, lastFlush: now)
        } else {
            recording = Recording(id: id, startedAt: startedAt, epoch: epoch, accumulator: RideAccumulator(),
                                  revision: 0, lastFlush: now)
        }
    }

    var isRecording: Bool { recording != nil }

    func add(_ fix: LocationFix, now: Date) {
        guard recording != nil else { return }
        recording?.accumulator.add(fix)
        if let last = recording?.lastFlush, now.timeIntervalSince(last) >= Self.draftInterval {
            flushDraft(now: now)
        }
    }

    /// Leg change, reroute or pause: distance is not bridged across it.
    func breakSegment() {
        recording?.accumulator.breakSegment()
    }

    func finish(_ outcome: RideSummary.Outcome, now: Date) {
        guard let recording else { return }
        upsert(summary(recording, outcome: outcome, now: now))
        contents.draft = nil
        self.recording = nil
        save()
    }

    func delete(_ id: RideID) {
        contents.rides.removeAll { $0.id == id }
        if contents.draft?.id == id { contents.draft = nil }
        if recording?.id == id { recording = nil }
        contents.deleted.append(id)
        contents.deleted = Array(contents.deleted.suffix(50))
        save()
    }

    func deleteAll() {
        contents.deleted.append(contentsOf: contents.rides.map(\.id))
        if let id = recording?.id { contents.deleted.append(id) }
        contents.deleted = Array(contents.deleted.suffix(50))
        contents.rides = []
        contents.draft = nil
        recording = nil
        save()
    }

    /// Summary fields only, for the rider to share.
    func exportJSON() -> String {
        struct Row: Encodable {
            let title: String
            let startedAt: Date
            let endedAt: Date
            let activeMinutes: Int
            let estimatedKilometres: Double
            let outcome: String
        }
        let rows = contents.rides.map {
            Row(title: $0.title, startedAt: $0.startedAt, endedAt: $0.lastObservedAt,
                activeMinutes: Int(($0.activeSeconds / 60).rounded()),
                estimatedKilometres: ($0.estimatedMetres / 100).rounded() / 10, outcome: $0.outcome.rawValue)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(rows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private func flushDraft(now: Date) {
        guard var recording else { return }
        recording.revision += 1
        recording.lastFlush = now
        self.recording = recording
        contents.draft = summary(recording, outcome: .interrupted, now: now)
        save()
    }

    private func summary(_ r: Recording, outcome: RideSummary.Outcome, now: Date) -> RideSummary {
        RideSummary(id: r.id, startedAt: r.startedAt, lastObservedAt: now, activeSeconds: r.accumulator.activeSeconds,
                    estimatedMetres: r.accumulator.estimatedMetres, outcome: outcome, revision: r.revision + 1,
                    consentEpoch: r.epoch)
    }

    private func upsert(_ summary: RideSummary) {
        guard !contents.deleted.contains(summary.id) else { return }
        contents.rides.removeAll { $0.id == summary.id }
        contents.rides.append(summary)
        contents.rides = RideHistoryPolicy.pruned(contents.rides, now: summary.lastObservedAt)
    }

    private func save() {
        rides = contents.rides
        do {
            try file.save(contents)
            problem = nil
        } catch {
            problem = "Ride history couldn't be saved."
        }
    }
}
