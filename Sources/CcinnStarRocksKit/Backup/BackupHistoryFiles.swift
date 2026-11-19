import Foundation

/// `History/history-<profile id>.json`, read and written in `QueryHistoryStore`'s format (a JSON array, ISO 8601 dates,
/// newest first), and the merge an import applies to it.
enum BackupHistoryFiles {
    /// As `QueryHistoryStore`.
    static let maximumEntries = 1_000
    static let maximumStatementLength = 100_000

    static func fileURL(for profileID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("history-\(profileID.uuidString).json")
    }

    /// The entries, or none when the profile has no history yet.
    static func read(for profileID: UUID, in directory: URL) throws -> [QueryHistoryEntry] {
        let url = fileURL(for: profileID, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([QueryHistoryEntry].self, from: Data(contentsOf: url))
    }

    /// Replaces the file 0600, atomically.
    static func write(_ entries: [QueryHistoryEntry], for profileID: UUID, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try SecureFile.write(try encoder.encode(entries), to: fileURL(for: profileID, in: directory))
    }

    static func remove(for profileID: UUID, in directory: URL) throws {
        let url = fileURL(for: profileID, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Credentials redacted again (rules may have improved since the entry was written) and statements capped.
    static func sanitized(_ entry: QueryHistoryEntry) -> QueryHistoryEntry {
        var entry = entry
        entry.sql = SQLRedactor.redact(entry.sql)
        if entry.sql.count > maximumStatementLength { entry.sql = String(entry.sql.prefix(maximumStatementLength)) }
        return entry
    }

    /// The union by entry id (the local copy wins), newest first, capped at 1,000.
    static func merge(local: [QueryHistoryEntry], imported: [QueryHistoryEntry]) -> [QueryHistoryEntry] {
        var seen = Set(local.map(\.id))
        var merged = local
        for entry in imported where seen.insert(entry.id).inserted {
            merged.append(entry)
        }
        merged.sort { (lhs: QueryHistoryEntry, rhs: QueryHistoryEntry) -> Bool in
            if lhs.executedAt != rhs.executedAt { return lhs.executedAt > rhs.executedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if merged.count > maximumEntries { merged.removeLast(merged.count - maximumEntries) }
        return merged
    }

    /// How many of `imported` the local history does not have yet.
    static func newEntryCount(local: Set<UUID>, imported: [QueryHistoryEntry]) -> Int {
        var seen = local
        var count = 0
        for entry in imported where seen.insert(entry.id).inserted {
            count += 1
        }
        return count
    }
}
