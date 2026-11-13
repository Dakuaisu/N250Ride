import Foundation

enum StoreError: Error, Equatable {
    /// Before first unlock, or the disk refused: the data is unavailable, not empty.
    case unavailable(String)
    case tooLarge(bytes: Int, limit: Int)
    /// Written by a newer app version; never overwritten without an explicit discard.
    case unknownSchema(Int)
    case corrupt
}

/// File operations a record needs, replaceable in tests to inject failures.
struct RecordIO: Sendable {
    var write: @Sendable (Data, URL) throws -> Void
    var excludeFromBackup: @Sendable (URL) throws -> Void

    static let real = RecordIO(
        write: { data, url in try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) },
        excludeFromBackup: { url in
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try target.setResourceValues(values)
        })
}

/// One small versioned record in a file under Application Support: atomic
/// replacement, a size cap, after-first-unlock protection (so a locked phone can
/// still save during a ride) and exclusion from backups. Payloads are never logged.
///
/// An existing file that can't be read (newer schema, damaged, oversized or
/// unavailable) is never overwritten: saves are refused until `delete()` (an
/// explicit discard) succeeds.
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
    private let io: RecordIO
    /// Why the existing file must be kept as it is; nil when it was read or is absent.
    private(set) var blocked: StoreError?
    /// The last save replaced the file but could not exclude it from backups.
    private(set) var backupExclusionFailed = false
    private var checked = false

    init(directory: URL, name: String, schemaVersion: Int, maxBytes: Int, fileManager: FileManager = .default,
         io: RecordIO = .real) {
        url = directory.appendingPathComponent(name)
        self.schemaVersion = schemaVersion
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        self.io = io
    }

    /// The stored payload, nil when there is none.
    func load() throws(StoreError) -> Payload? {
        checked = true
        do {
            let payload = try read()
            blocked = nil
            return payload
        } catch {
            blocked = error
            throw error
        }
    }

    private func read() throws(StoreError) -> Payload? {
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
        if !checked { _ = try? load() }
        if let blocked { throw blocked }
        let data: Data
        do {
            data = try JSONEncoder().encode(Envelope(schemaVersion: schemaVersion, payload: payload))
        } catch {
            throw .corrupt
        }
        guard data.count <= maxBytes else { throw .tooLarge(bytes: data.count, limit: maxBytes) }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try io.write(data, url)
        } catch {
            throw .unavailable((error as NSError).domain)
        }
        // The new bytes are in place: a metadata failure is a warning, not a failed save.
        do {
            try io.excludeFromBackup(url)
            backupExclusionFailed = false
        } catch {
            backupExclusionFailed = true
        }
    }

    /// Removes the record, including one that couldn't be read. Deleting nothing is not an error.
    func delete() throws(StoreError) {
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw .unavailable((error as NSError).domain)
            }
        }
        blocked = nil
        checked = true
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
