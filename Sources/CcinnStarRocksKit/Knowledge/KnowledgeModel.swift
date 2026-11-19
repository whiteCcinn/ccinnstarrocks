import CryptoKit
import Foundation

// The knowledge base's data model: what is persisted per database and in the shared index. Plain values, Codable with
// tolerant decoding (fields added later fall back to defaults); no row data, DDL or code excerpts are ever stored.

// MARK: - Identity

/// A cluster as reached from this Mac: its FE endpoint, through the SSH bastion when tunnelled (private addresses repeat
/// across networks). Derived from a profile's endpoint, never its name or id, so every profile reaching the cluster
/// shares the cluster's knowledge. User names are not part of it.
public struct ClusterKey: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(profile: ConnectionProfile) {
        let endpoint = Self.bracketed(Self.normalized(profile.host)) + ":" + String(profile.port)
        if let ssh = profile.ssh {
            rawValue = "sr+ssh://" + Self.bracketed(Self.normalized(ssh.host)) + ":" + String(ssh.port) + "/" + endpoint
        } else {
            rawValue = "sr://" + endpoint
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: ClusterKey, rhs: ClusterKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Lower-cased, trimmed, without the trailing dot of a fully qualified name.
    static func normalized(_ host: String) -> String {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// IPv6 addresses in brackets, as `Endpoint` prints them.
    static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
    }
}

/// One database's knowledge: cluster, catalog and database, with exact case.
public struct DatabaseKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let cluster: ClusterKey
    public let catalog: String
    public let database: String

    public init(cluster: ClusterKey, catalog: String, database: String) {
        self.cluster = cluster
        self.catalog = catalog
        self.database = database
    }

    public var description: String { "\(cluster) \(catalog).\(database)" }

    /// The file name stem: `d` and 20 hex characters of the SHA-256 of the canonical key. Each file also stores its key,
    /// so a collision would be detected rather than mix two databases.
    public var fileID: String {
        let canonical = cluster.rawValue + "\u{1F}" + catalog + "\u{1F}" + database
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "d" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Index (clusters, databases, projects, links)

/// `index.json`: what exists, and which local projects use which databases (many to many).
public struct KnowledgeIndex: Codable, Sendable, Equatable {
    public static let formatName = "ccinnstarrocks.knowledge-index"

    public var format = KnowledgeIndex.formatName
    public var schemaVersion = KnowledgeStore.schemaVersion
    public var minReaderVersion = 1
    public var revision = 0
    public var updatedAt: Date?
    public var clusters: [ClusterEntry] = []
    public var databases: [DatabaseEntry] = []
    public var projects: [Project] = []
    public var links: [Link] = []
    public var tombstones: [Tombstone] = []

    public init() {}

    public struct ClusterEntry: Codable, Sendable, Equatable {
        public var key: ClusterKey
        /// Other endpoints the user declared to be the same cluster (a load balancer and an FE, say).
        public var aliases: [ClusterKey] = []
        /// `ClusterId` from `SHOW FRONTENDS`, used only to suggest merges.
        public var starrocksClusterID: String?
        public var label: String?

        public init(key: ClusterKey) {
            self.key = key
        }
    }

    public struct DatabaseEntry: Codable, Sendable, Equatable {
        public var id: String
        public var key: DatabaseKey

        public init(key: DatabaseKey) {
            id = key.fileID
            self.key = key
        }
    }

    public struct Project: Codable, Sendable, Equatable {
        public var id: String
        /// `~/…` when under the home directory, so the link survives a move to another Mac.
        public var path: String
        public var name: String
        /// The `origin` URL without credentials, to recognise the project on another Mac.
        public var gitRemote: String?
        public var addedAt: Date
        /// `user`, or `ai:<client name>`.
        public var addedBy: String

        public init(id: String, path: String, name: String, gitRemote: String?, addedAt: Date, addedBy: String) {
            self.id = id
            self.path = path
            self.name = name
            self.gitRemote = gitRemote
            self.addedAt = addedAt
            self.addedBy = addedBy
        }
    }

    public struct Link: Codable, Sendable, Equatable, Hashable {
        public var project: String
        public var database: String
        public var addedAt: Date
        public var addedBy: String

        public init(project: String, database: String, addedAt: Date, addedBy: String) {
            self.project = project
            self.database = database
            self.addedAt = addedAt
            self.addedBy = addedBy
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        minReaderVersion = try container.decodeIfPresent(Int.self, forKey: .minReaderVersion) ?? 1
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        clusters = try container.decodeIfPresent([ClusterEntry].self, forKey: .clusters) ?? []
        databases = try container.decodeIfPresent([DatabaseEntry].self, forKey: .databases) ?? []
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        links = try container.decodeIfPresent([Link].self, forKey: .links) ?? []
        tombstones = try container.decodeIfPresent([Tombstone].self, forKey: .tombstones) ?? []
    }
}

// MARK: - One database

/// `databases/<fileID>.json`: facts extracted from the server plus curated knowledge.
public struct DatabaseKnowledge: Codable, Sendable, Equatable {
    public static let formatName = "ccinnstarrocks.knowledge"

    public var format = DatabaseKnowledge.formatName
    public var schemaVersion = KnowledgeStore.schemaVersion
    public var minReaderVersion = 1
    public var revision = 0
    public var key: DatabaseKey
    public var refreshedAt: Date?
    public var serverVersion: String?
    /// Sorted by name.
    public var tables: [TableFacts] = []
    public var relationships: [Relationship] = []
    public var notes: [Note] = []
    public var terms: [Term] = []
    public var areas: [SubjectArea] = []
    public var tombstones: [Tombstone] = []

    public init(key: DatabaseKey) {
        self.key = key
    }

    public func table(named name: String) -> TableFacts? {
        tables.first { $0.name == name }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        minReaderVersion = try container.decodeIfPresent(Int.self, forKey: .minReaderVersion) ?? 1
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        key = try container.decode(DatabaseKey.self, forKey: .key)
        refreshedAt = try container.decodeIfPresent(Date.self, forKey: .refreshedAt)
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)
        tables = try container.decodeIfPresent([TableFacts].self, forKey: .tables) ?? []
        relationships = try container.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
        notes = try container.decodeIfPresent([Note].self, forKey: .notes) ?? []
        terms = try container.decodeIfPresent([Term].self, forKey: .terms) ?? []
        areas = try container.decodeIfPresent([SubjectArea].self, forKey: .areas) ?? []
        tombstones = try container.decodeIfPresent([Tombstone].self, forKey: .tombstones) ?? []
    }
}

/// Structure of one table, view or materialized view as the server reported it at the last refresh.
public struct TableFacts: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case table, view, materializedView, externalTable, systemView
    }

    public enum State: String, Codable, Sendable {
        /// Seen for the first time at the last refresh.
        case new
        case fresh
        /// The structure fingerprint differs from the one knowledge was written against.
        case changed
        /// Gone from the server; kept until the user prunes it.
        case dropped
    }

    public var name: String
    public var kind: Kind
    /// DUP / AGG / UNI / PK.
    public var model: String?
    public var comment: String?
    public var keys = Keys()
    public var columns: [ColumnFacts] = []
    /// Tables a view or materialized view reads.
    public var lineage: [TableReference] = []
    /// Structure fingerprint (see `SchemaFingerprint`).
    public var fingerprint: String
    public var commentFingerprint: String?
    public var state: State
    public var firstSeen: Date
    public var changedAt: Date?

    public struct Keys: Codable, Sendable, Equatable {
        public var primary: [String] = []
        public var sort: [String] = []
        public var distribution: [String] = []
        public var partition: [String] = []

        public init(primary: [String] = [], sort: [String] = [], distribution: [String] = [], partition: [String] = []) {
            self.primary = primary
            self.sort = sort
            self.distribution = distribution
            self.partition = partition
        }
    }

    public init(name: String, kind: Kind, model: String? = nil, comment: String? = nil, keys: Keys = Keys(), columns: [ColumnFacts] = [],
                lineage: [TableReference] = [], fingerprint: String, commentFingerprint: String? = nil, state: State = .new,
                firstSeen: Date, changedAt: Date? = nil) {
        self.name = name
        self.kind = kind
        self.model = model
        self.comment = comment
        self.keys = keys
        self.columns = columns
        self.lineage = lineage
        self.fingerprint = fingerprint
        self.commentFingerprint = commentFingerprint
        self.state = state
        self.firstSeen = firstSeen
        self.changedAt = changedAt
    }

    public func column(named name: String) -> ColumnFacts? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// A column, stored compactly as `["dsp_id", "bigint", "K", "DSP id"]`: name, type, flags (`K` key, `N` nullable,
/// `A:SUM` aggregation, comma-separated) and comment.
public struct ColumnFacts: Codable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var isKey: Bool
    public var isNullable: Bool
    /// SUM / REPLACE / MAX / … for AGG-model value columns.
    public var aggregation: String?
    public var comment: String?

    public init(name: String, type: String, isKey: Bool = false, isNullable: Bool = true, aggregation: String? = nil, comment: String? = nil) {
        self.name = name
        self.type = type
        self.isKey = isKey
        self.isNullable = isNullable
        self.aggregation = aggregation
        self.comment = comment
    }

    public var flags: String {
        var flags: [String] = []
        if isKey { flags.append("K") }
        if isNullable { flags.append("N") }
        if let aggregation { flags.append("A:" + aggregation) }
        return flags.joined(separator: ",")
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
        type = try container.decode(String.self)
        let flags = (try container.decodeIfPresent(String.self) ?? "").split(separator: ",").map(String.init)
        isKey = flags.contains("K")
        isNullable = flags.contains("N")
        aggregation = flags.first { $0.hasPrefix("A:") }.map { String($0.dropFirst(2)) }
        comment = try container.decodeIfPresent(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(name)
        try container.encode(type)
        try container.encode(flags)
        try container.encode(comment ?? "")
    }
}

/// A table, in this database (`database == nil`) or another database of the same cluster.
public struct TableReference: Codable, Sendable, Hashable, Comparable {
    public var database: String?
    public var table: String

    public init(database: String? = nil, table: String) {
        self.database = database
        self.table = table
    }

    public static func < (lhs: TableReference, rhs: TableReference) -> Bool {
        (lhs.database ?? "", lhs.table) < (rhs.database ?? "", rhs.table)
    }
}

// MARK: - Relationships

/// How rows of two tables relate, with every piece of evidence for (or against) it. Confidence is computed from the
/// evidence when read (`RelationshipConfidence`), never stored.
public struct Relationship: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case manyToOne, oneToOne, manyToMany
        /// The same key in two tables with no table that owns it.
        case sharedKey
        /// A view or materialized view reading a table; drawn in diagrams, never used to join.
        case lineage
    }

    public enum Status: String, Codable, Sendable {
        case inferred, confirmed, rejected
    }

    public struct End: Codable, Sendable, Equatable, Hashable {
        /// `nil` for this knowledge base's database.
        public var database: String?
        public var table: String
        public var columns: [String]

        public init(database: String? = nil, table: String, columns: [String]) {
            self.database = database
            self.table = table
            self.columns = columns
        }
    }

    /// Deterministic: the same two ends from any source land on the same record.
    public var id: String
    public var from: End
    public var to: End
    public var kind: Kind
    public var status: Status
    public var evidence: [Evidence]
    /// Structure fingerprints of both tables when the evidence was last updated; a different current fingerprint makes
    /// the relationship stale.
    public var fingerprints: [String: String]

    public init(from: End, to: End, kind: Kind, status: Status = .inferred, evidence: [Evidence], fingerprints: [String: String] = [:]) {
        id = Self.id(from: from, to: to)
        self.from = from
        self.to = to
        self.kind = kind
        self.status = status
        self.evidence = evidence
        self.fingerprints = fingerprints
    }

    /// `r` and 16 hex characters of the SHA-256 of the canonical ends (lower-cased; columns in order).
    public static func id(from: End, to: End) -> String {
        func canonical(_ end: End) -> String {
            (end.database ?? "").lowercased() + "." + end.table.lowercased() + "(" + end.columns.map { $0.lowercased() }.joined(separator: ",") + ")"
        }
        let digest = SHA256.hash(data: Data((canonical(from) + "->" + canonical(to)).utf8))
        return "r" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why something is believed. One shape for every source; fields not used by a source stay `nil`.
public struct Evidence: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// The user confirmed or rejected it in the app.
        case user
        /// A `foreign_key_constraints` / `unique_constraints` table property.
        case declared
        /// A view or materialized view reads the table.
        case lineage
        /// An equi-join inside a view or materialized view definition.
        case definition
        /// Equi-joins in successful statements of the editor history.
        case history
        /// An AI pointed at code (path, line, symbol).
        case code
        /// An AI asserted it without verifiable evidence.
        case ai
        /// Column and table names.
        case naming
    }

    public enum Verdict: String, Codable, Sendable {
        case assert, reject
    }

    public var source: Source
    public var verdict: Verdict = .assert
    /// Heuristic score 0–100 (`naming`).
    public var score: Int?
    /// `history`: distinct statements and total occurrences.
    public var statements: Int?
    public var count: Int?
    public var lastSeen: Date?
    /// Up to 3 statement digests (literals replaced by `?`).
    public var samples: [String]?
    /// `code`: project id, path inside it, line and symbol. Never code itself.
    public var project: String?
    public var path: String?
    public var line: Int?
    public var symbol: String?
    public var rationale: String?
    /// `user`, or `ai:<client name>`.
    public var by: String?
    public var at: Date?

    public init(source: Source, verdict: Verdict = .assert, score: Int? = nil, statements: Int? = nil, count: Int? = nil, lastSeen: Date? = nil,
                samples: [String]? = nil, project: String? = nil, path: String? = nil, line: Int? = nil, symbol: String? = nil,
                rationale: String? = nil, by: String? = nil, at: Date? = nil) {
        self.source = source
        self.verdict = verdict
        self.score = score
        self.statements = statements
        self.count = count
        self.lastSeen = lastSeen
        self.samples = samples
        self.project = project
        self.path = path
        self.line = line
        self.symbol = symbol
        self.rationale = rationale
        self.by = by
        self.at = at
    }
}

// MARK: - Curated knowledge

public struct Note: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case description, caveat, usage, metric
    }

    public var id: String
    public var table: String
    public var column: String?
    public var kind: Kind
    /// At most 2,000 characters; untrusted text.
    public var text: String
    public var evidence: [Evidence]
    public var by: String
    public var at: Date
    /// Structure fingerprint of the table when the note was written.
    public var fingerprint: String?

    public init(id: String, table: String, column: String?, kind: Kind, text: String, evidence: [Evidence], by: String, at: Date, fingerprint: String?) {
        self.id = id
        self.table = table
        self.column = column
        self.kind = kind
        self.text = text
        self.evidence = evidence
        self.by = by
        self.at = at
        self.fingerprint = fingerprint
    }
}

/// A glossary entry: business words (in any language) and where they live in the schema.
public struct Term: Codable, Sendable, Equatable {
    public struct Mapping: Codable, Sendable, Equatable {
        public var table: String
        public var column: String?
        /// For metrics: `SUM(dsp_fill) / SUM(dsp_request)`.
        public var expression: String?

        public init(table: String, column: String? = nil, expression: String? = nil) {
            self.table = table
            self.column = column
            self.expression = expression
        }
    }

    public var id: String
    public var term: String
    public var synonyms: [String]
    public var definition: String
    public var mapsTo: [Mapping]
    public var by: String
    public var at: Date

    public init(id: String, term: String, synonyms: [String], definition: String, mapsTo: [Mapping], by: String, at: Date) {
        self.id = id
        self.term = term
        self.synonyms = synonyms
        self.definition = definition
        self.mapsTo = mapsTo
        self.by = by
        self.at = at
    }
}

/// A named group of tables, for diagrams and overviews.
public struct SubjectArea: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var tables: [String]
    public var description: String?
    public var by: String
    public var at: Date

    public init(id: String, name: String, tables: [String], description: String?, by: String, at: Date) {
        self.id = id
        self.name = name
        self.tables = tables
        self.description = description
        self.by = by
        self.at = at
    }
}

/// A deleted item's id, so merging an older copy (a backup, another Mac) never brings it back.
public struct Tombstone: Codable, Sendable, Equatable {
    public var id: String
    public var deletedAt: Date
    public var by: String?

    public init(id: String, deletedAt: Date, by: String?) {
        self.id = id
        self.deletedAt = deletedAt
        self.by = by
    }
}
