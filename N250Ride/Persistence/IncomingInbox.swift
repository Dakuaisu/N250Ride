import Foundation
import Observation
import RideCore

/// A destination shared or pasted into the app, waiting for the rider.
struct IncomingDestination: Codable, Identifiable, Equatable {
    enum Status: Codable, Equatable {
        case pending
        /// Open in the confirmation screen; returns to pending on cancel or restart.
        case reserved
        /// Confirmed; removed once its ride has started. After a restart it is
        /// shown with Retry, never dispatched automatically.
        case accepted
        case failed(String)
    }

    let id: UUID
    let receivedAt: Date
    var coordinate: Coordinate?
    var label: String
    /// A short link still to be expanded (HTTPS map hosts only, at most 4 KiB).
    var link: String?
    var status: Status

    var isResolved: Bool { coordinate != nil }
}

/// The app's own queue of incoming destinations: at most ten, seven days from
/// receipt, in Application Support. Importing never requests a route.
@MainActor
@Observable
final class IncomingInbox {
    static let capacity = 10
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let maxInputBytes = 4 * 1_024
    static let duplicateWindow: TimeInterval = 60

    enum AddResult: Equatable {
        case added(UUID)
        /// The same place arrived again within a minute; the earlier item stands.
        case duplicate(UUID)
        case full
        case tooLarge
        case storageFailed
    }

    private(set) var items: [IncomingDestination] = []
    private(set) var problem: String?
    @ObservationIgnored private let file: RecordFile<[IncomingDestination]>

    init(directory: URL, now: Date) {
        file = RecordFile(directory: directory, name: "inbox.json", schemaVersion: 1, maxBytes: 64 * 1_024)
        do {
            items = try file.load() ?? []
        } catch {
            problem = "Saved destinations couldn't be read."
        }
        for index in items.indices where items[index].status == .reserved { items[index].status = .pending }
        prune(now: now)
    }

    var waiting: [IncomingDestination] { items.filter { $0.status != .reserved } }

    func add(coordinate: Coordinate?, label: String, link: String?, now: Date) -> AddResult {
        prune(now: now)
        if let link, link.utf8.count > Self.maxInputBytes { return .tooLarge }
        let label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RideDestination.maxLabelLength))
        if let same = items.first(where: { now.timeIntervalSince($0.receivedAt) < Self.duplicateWindow
            && $0.coordinate == coordinate && $0.link == link && $0.label == label }) {
            return .duplicate(same.id)
        }
        guard items.count < Self.capacity else { return .full }
        let item = IncomingDestination(id: UUID(), receivedAt: now, coordinate: coordinate, label: label, link: link,
                                       status: .pending)
        items.append(item)
        guard save() else {
            items.removeAll { $0.id == item.id }
            return .storageFailed
        }
        return .added(item.id)
    }

    func item(_ id: UUID) -> IncomingDestination? { items.first { $0.id == id } }

    func resolve(_ id: UUID, coordinate: Coordinate, label: String?) {
        update(id) {
            $0.coordinate = coordinate
            $0.link = nil
            if let label, $0.label.isEmpty { $0.label = String(label.prefix(RideDestination.maxLabelLength)) }
        }
    }

    func setStatus(_ id: UUID, _ status: IncomingDestination.Status) {
        update(id) { $0.status = status }
    }

    /// The ride for this item has started: it is consumed.
    func consume(_ id: UUID) {
        remove(id)
    }

    func discard(_ id: UUID) {
        remove(id)
    }

    func prune(now: Date) {
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.receivedAt) >= Self.lifetime || $0.receivedAt > now.addingTimeInterval(300) }
        if items.count != before { _ = save() }
    }

    private func update(_ id: UUID, _ change: (inout IncomingDestination) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        _ = save()
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        _ = save()
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try file.save(items)
            problem = nil
            return true
        } catch {
            problem = "Saved destinations couldn't be stored."
            return false
        }
    }
}
