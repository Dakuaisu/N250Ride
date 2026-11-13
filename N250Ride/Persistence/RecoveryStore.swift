import Foundation
import Observation
import RideCore

/// The journey journal for "resume after an interruption". Off until the rider
/// accepts the disclosure. Stores intent only (destination, stop, leg, preferences),
/// never a route, instructions or a position, and forgets it after 24 hours.
@MainActor
@Observable
final class RecoveryStore {
    private(set) var enabled: Bool
    /// Set when the journal could not be read or written; recovery is then unavailable.
    private(set) var problem: String?
    private(set) var journal = RecoveryJournal()

    @ObservationIgnored private let file: RecordFile<RecoveryJournal>
    @ObservationIgnored private let defaults: UserDefaults
    private static let enabledKey = "recoveryEnabled"
    private static let finishedKey = "recoveryFinishedRides"

    init(directory: URL, defaults: UserDefaults) {
        file = RecordFile(directory: directory, name: "recovery.json", schemaVersion: RecoveryJournal.schemaVersion,
                          maxBytes: 64 * 1_024)
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if !on { discard() }
    }

    /// Reads the journal at launch. Never requests a route or starts anything.
    func offer(now: Date) -> RecoveryOffer? {
        guard enabled else { return nil }
        do {
            journal = try file.load() ?? RecoveryJournal()
            problem = nil
        } catch .unknownSchema {
            problem = "A saved ride from a newer version can't be read. Discard it to continue."
            return nil
        } catch .unavailable {
            problem = "Saved ride unavailable until the phone is unlocked."
            return nil
        } catch {
            problem = "The saved ride was damaged. Discard it to continue."
            return nil
        }
        return RecoveryPolicy.offer(for: journal, now: now, suppressed: finished(now: now))
    }

    /// Best effort, before the start commits. A failure is reported, never blocking.
    func recordPendingStart(_ context: RideContext, reason: String, now: Date) {
        guard enabled else { return }
        journal.pendingStart = PendingStart(context: context, reason: reason, recordedAt: now)
        write()
    }

    func commit(_ context: RideContext, startedAt: Date, now: Date) {
        guard enabled else { return }
        journal = RecoveryJournal(lastCommitted: RideIntent(context: context, startedAt: startedAt, checkpointAt: now))
        write()
    }

    func clearPendingStart() {
        guard enabled, journal.pendingStart != nil else { return }
        journal.pendingStart = nil
        write()
    }

    /// The ride is over (arrived or ended): it must never be offered again.
    func finish(_ ride: RideID, now: Date) {
        var list = finishedList(now: now)
        list.append(FinishedRide(id: ride.raw, at: now))
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.finishedKey)
        discard()
    }

    func discard() {
        journal = RecoveryJournal()
        do {
            try file.delete()
            problem = nil
        } catch {
            problem = "Couldn't delete the saved ride. It won't be resumed automatically."
        }
    }

    private func write() {
        do {
            try file.save(journal)
            problem = nil
        } catch {
            problem = "Ride recovery unavailable: the ride couldn't be saved."
        }
    }

    private struct FinishedRide: Codable {
        let id: UUID
        let at: Date
    }

    private func finishedList(now: Date) -> [FinishedRide] {
        let list = defaults.data(forKey: Self.finishedKey)
            .flatMap { try? JSONDecoder().decode([FinishedRide].self, from: $0) } ?? []
        return list.filter { now.timeIntervalSince($0.at) < RecoveryPolicy.lifetime }
    }

    private func finished(now: Date) -> Set<RideID> {
        Set(finishedList(now: now).map { RideID($0.id) })
    }
}
