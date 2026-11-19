import Foundation

/// Knowledge files under `<data directory>/Knowledge/`:
///
///     Knowledge/               0700
///       .lock                  flock target for every write
///       index.json             clusters, databases, projects, links
///       databases/<id>.json    one file per database
///
/// Writes take `FileLock`, re-read the file, apply the change and replace the file atomically, so the app and the `mcp`
/// process never lose each other's updates. Reads take no lock: a file is always whole. A file written by a newer app
/// (`schemaVersion` above ours) is read but never rewritten, so its new fields are not silently dropped; one that
/// requires a newer reader (`minReaderVersion`) is refused.
public struct KnowledgeStore: Sendable {
    public static let schemaVersion = 1
    /// Files beyond this are refused rather than slowly parsed on every call.
    public static let maxFileBytes = 64 << 20

    public enum Failure: Error, Equatable, LocalizedError {
        case newerFormat(String)
        case wrongFile(String)
        case tooLarge(String)

        public var errorDescription: String? {
            switch self {
            case let .newerFormat(file): "\(file) was written by a newer CcinnStarRocks; update the app to change it."
            case let .wrongFile(file): "\(file) does not hold the knowledge it is named for; it was left untouched."
            case let .tooLarge(file): "\(file) is larger than 64 MB; prune knowledge for this database first."
            }
        }
    }

    public let directory: URL

    public static var defaultDirectory: URL {
        ProfileRepository.defaultDirectory.appendingPathComponent("Knowledge", isDirectory: true)
    }

    public init(directory: URL = KnowledgeStore.defaultDirectory) {
        self.directory = directory
    }

    var lockURL: URL { directory.appendingPathComponent(".lock") }
    var indexURL: URL { directory.appendingPathComponent("index.json") }

    func databaseURL(_ key: DatabaseKey) -> URL {
        directory.appendingPathComponent("databases", isDirectory: true).appendingPathComponent(key.fileID + ".json")
    }

    // MARK: Reading

    /// The index; empty when nothing was written yet.
    public func index() throws -> KnowledgeIndex {
        guard let data = try read(indexURL) else { return KnowledgeIndex() }
        let index = try Self.decoder.decode(KnowledgeIndex.self, from: data)
        guard index.format == KnowledgeIndex.formatName else { throw Failure.wrongFile(indexURL.lastPathComponent) }
        guard index.minReaderVersion <= Self.schemaVersion else { throw Failure.newerFormat(indexURL.lastPathComponent) }
        return index
    }

    /// The knowledge of `key`'s database, or `nil` when there is none yet.
    public func database(_ key: DatabaseKey) throws -> DatabaseKnowledge? {
        let url = databaseURL(key)
        guard let data = try read(url) else { return nil }
        let knowledge = try Self.decoder.decode(DatabaseKnowledge.self, from: data)
        guard knowledge.format == DatabaseKnowledge.formatName, knowledge.key == key else { throw Failure.wrongFile(url.lastPathComponent) }
        guard knowledge.minReaderVersion <= Self.schemaVersion else { throw Failure.newerFormat(url.lastPathComponent) }
        return knowledge
    }

    /// Every database the index lists that has a readable file (for backups and overviews).
    public func databases() throws -> [DatabaseKnowledge] {
        try index().databases.compactMap { try database($0.key) }
    }

    // MARK: Writing

    /// Applies `change` to the index under the lock and saves it with the next revision.
    @discardableResult
    public func updateIndex<T>(_ change: (inout KnowledgeIndex) throws -> T) throws -> T {
        try SecureFile.createDirectory(directory)
        return try FileLock.withLock(at: lockURL) {
            var index = try self.index()
            guard index.schemaVersion <= Self.schemaVersion else { throw Failure.newerFormat(indexURL.lastPathComponent) }
            let result = try change(&index)
            try save(&index)
            return result
        }
    }

    /// Applies `change` to the database's knowledge (created when missing) under the lock, saves it with the next
    /// revision, and lists the database in the index.
    @discardableResult
    public func updateDatabase<T>(_ key: DatabaseKey, _ change: (inout DatabaseKnowledge) throws -> T) throws -> T {
        try SecureFile.createDirectory(directory)
        return try FileLock.withLock(at: lockURL) {
            var knowledge = try database(key) ?? DatabaseKnowledge(key: key)
            guard knowledge.schemaVersion <= Self.schemaVersion else { throw Failure.newerFormat(databaseURL(key).lastPathComponent) }
            let result = try change(&knowledge)
            knowledge.revision += 1
            knowledge.tables.sort { $0.name < $1.name }
            try write(knowledge, to: databaseURL(key))
            var index = try self.index()
            if !index.databases.contains(where: { $0.key == key }) {
                guard index.schemaVersion <= Self.schemaVersion else { throw Failure.newerFormat(indexURL.lastPathComponent) }
                index.databases.append(KnowledgeIndex.DatabaseEntry(key: key))
                if !index.clusters.contains(where: { $0.key == key.cluster || $0.aliases.contains(key.cluster) }) {
                    index.clusters.append(KnowledgeIndex.ClusterEntry(key: key.cluster))
                }
                try save(&index)
            }
            return result
        }
    }

    private func save(_ index: inout KnowledgeIndex) throws {
        index.revision += 1
        index.updatedAt = Date()
        index.databases.sort { $0.id < $1.id }
        try write(index, to: indexURL)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        guard data.count <= Self.maxFileBytes else { throw Failure.tooLarge(url.lastPathComponent) }
        try SecureFile.write(data, to: url)
    }

    private func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxFileBytes else { throw Failure.tooLarge(url.lastPathComponent) }
        return try Data(contentsOf: url)
    }

    // MARK: Coding

    /// Sorted keys and indentation: files diff cleanly and back up deterministically.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
