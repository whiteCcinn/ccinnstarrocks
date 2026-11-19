import Foundation

public struct QueryHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sql: String
    public var database: String?
    public var executedAt: Date
    public var durationMilliseconds: Double
    public var rowCount: Int?
    public var affectedRows: UInt64?
    public var errorMessage: String?

    public init(id: UUID = UUID(), sql: String, database: String?, executedAt: Date = Date(), durationMilliseconds: Double,
                rowCount: Int? = nil, affectedRows: UInt64? = nil, errorMessage: String? = nil) {
        self.id = id
        self.sql = sql
        self.database = database
        self.executedAt = executedAt
        self.durationMilliseconds = durationMilliseconds
        self.rowCount = rowCount
        self.affectedRows = affectedRows
        self.errorMessage = errorMessage
    }

    public var succeeded: Bool { errorMessage == nil }
}

/// Per-connection query history, newest first, bounded, persisted as JSON (private, atomic writes). The cached copy is
/// read again when the file changed on disk (another window on the same connection, or an import), so a write never
/// puts back a stale copy.
public actor QueryHistoryStore {
    /// `History/` in the data directory: the app writes it, the `mcp` process reads it to mine joins.
    public static var defaultDirectory: URL {
        ProfileRepository.defaultDirectory.appendingPathComponent("History", isDirectory: true)
    }

    public nonisolated let fileURL: URL
    private let maxEntries: Int
    private let maxStatementLength = 100_000
    private var entries: [QueryHistoryEntry]?
    /// The file as it was when `entries` was read or written; a different stamp means someone else replaced it.
    private var cachedStamp: FileStamp?

    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.inode = inode
            self.size = size
            self.modified = modified
        }
    }

    public init(directory: URL, profileID: UUID, maxEntries: Int = 1_000) {
        fileURL = directory.appendingPathComponent("history-\(profileID.uuidString).json")
        self.maxEntries = max(1, maxEntries)
    }

    public func all() -> [QueryHistoryEntry] {
        loadIfNeeded()
    }

    /// Case-insensitive search over statement text and database.
    public func search(_ text: String) -> [QueryHistoryEntry] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        let all = loadIfNeeded()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.sql.localizedCaseInsensitiveContains(needle) || ($0.database?.localizedCaseInsensitiveContains(needle) ?? false) }
    }

    public func append(_ entry: QueryHistoryEntry) {
        var entry = entry
        entry.sql = SQLRedactor.redact(entry.sql)
        if entry.sql.count > maxStatementLength { entry.sql = String(entry.sql.prefix(maxStatementLength)) }
        let maxEntries = maxEntries
        mutate { (all: inout [QueryHistoryEntry]) -> Void in
            // Re-running the latest statement replaces it instead of stacking duplicates.
            if let first = all.first, first.sql == entry.sql, first.database == entry.database { all.removeFirst() }
            all.insert(entry, at: 0)
            if all.count > maxEntries { all.removeLast(all.count - maxEntries) }
        }
    }

    public func delete(_ id: UUID) {
        mutate { (all: inout [QueryHistoryEntry]) -> Void in all.removeAll { $0.id == id } }
    }

    /// `History/.lock`: held around every read-modify-write of a history file, by each window's store and by imports.
    public static func withFileLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        try SecureFile.createDirectory(directory)
        return try FileLock.withLock(at: directory.appendingPathComponent(".lock"), timeout: .seconds(2), body)
    }

    /// Reads the file as it is now and writes the change under the lock. If the lock cannot be had, the change is still
    /// written: a lost entry elsewhere is better than losing this one.
    private func mutate(_ change: (inout [QueryHistoryEntry]) -> Void) {
        let directory = fileURL.deletingLastPathComponent()
        func write() {
            var all = loadIfNeeded()
            change(&all)
            entries = all
            persist(all)
        }
        do {
            try Self.withFileLock(in: directory, write)
        } catch {
            write()
        }
    }

    public func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
        cachedStamp = nil
    }

    private func loadIfNeeded() -> [QueryHistoryEntry] {
        let stamp = FileStamp(fileURL)
        if let entries, stamp == cachedStamp { return entries }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([QueryHistoryEntry].self, from: $0) } ?? []
        entries = loaded
        cachedStamp = stamp
        return loaded
    }

    private func persist(_ all: [QueryHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? SecureFile.write(data, to: fileURL)
        cachedStamp = FileStamp(fileURL)
    }
}
