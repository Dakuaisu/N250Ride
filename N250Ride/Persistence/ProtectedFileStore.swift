import Foundation

enum StoreError: Error, Equatable {
    /// Before first unlock, or the disk refused: the data is unavailable, not empty.
    case unavailable(String)
    case tooLarge(bytes: Int, limit: Int)
    /// Written by a newer app version; never overwritten without an explicit discard.
    case unknownSchema(Int)
    case corrupt
}

/// One small versioned record in a file under Application Support: atomic
/// replacement, a size cap, after-first-unlock protection (so a locked phone can
/// still save during a ride) and exclusion from backups. Payloads are never logged.
@MainActor
final class RecordFile<Payload: Codable> {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let payload: Payload
    }

    private struct Header: Decodable {
        let schemaVersion: Int
    }

    let url: URL
    let schemaVersion: Int
    let maxBytes: Int
    private let fileManager: FileManager

    init(directory: URL, name: String, schemaVersion: Int, maxBytes: Int, fileManager: FileManager = .default) {
        url = directory.appendingPathComponent(name)
        self.schemaVersion = schemaVersion
        self.maxBytes = maxBytes
        self.fileManager = fileManager
    }

    /// The stored payload, nil when there is none.
    func load() throws(StoreError) -> Payload? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unavailable((error as NSError).domain)
        }
        guard data.count <= maxBytes else { throw .tooLarge(bytes: data.count, limit: maxBytes) }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw .corrupt }
        guard header.schemaVersion == schemaVersion else { throw .unknownSchema(header.schemaVersion) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw .corrupt }
        return envelope.payload
    }

    func save(_ payload: Payload) throws(StoreError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(Envelope(schemaVersion: schemaVersion, payload: payload))
        } catch {
            throw .corrupt
        }
        guard data.count <= maxBytes else { throw .tooLarge(bytes: data.count, limit: maxBytes) }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try target.setResourceValues(values)
        } catch {
            throw .unavailable((error as NSError).domain)
        }
    }

    /// Removes the record. Deleting nothing is not an error.
    func delete() throws(StoreError) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw .unavailable((error as NSError).domain)
        }
    }

    var isExcludedFromBackup: Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }
}

enum StorageLocation {
    /// Application Support/N250Ride, created on demand.
    static var standard: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("N250Ride", isDirectory: true)
    }
}
