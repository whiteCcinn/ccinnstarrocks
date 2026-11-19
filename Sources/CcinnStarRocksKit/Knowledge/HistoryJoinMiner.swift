import Foundation

/// Relationships from equi-joins people actually ran (editor history) or wrote into views (design §2.5). Pure: the
/// caller reads the history files of every profile that maps to the cluster and passes the entries in.
///
/// - Only successful entries count, split into statements; kept kinds are SELECT, WITH, INSERT … SELECT and CREATE
///   [MATERIALIZED] VIEW. The MCP audit log is never mined: AI-run queries would confirm the AI's own guesses.
/// - Unqualified tables resolve against the entry's database. A join counts when both tables exist (not dropped) in
///   this database or in `otherDatabases`, with the columns it names.
/// - Direction: the side whose columns hold a key of its table (`id`, the primary key, the key of a PK/UNI/AGG table,
///   or the target of a declared foreign key) is `to`, many-to-one; both such sides make one-to-one; neither makes
///   many-to-many. Unordered kinds order their ends by name. Column pairs are sorted, so every spelling of a composite
///   join lands on one relationship id.
public enum HistoryJoinMiner {
    public static let maxSamples = 3
    public static let maxSampleLength = 500

    /// Relationships with one aggregated `history` evidence each (occurrences, distinct statements by `SQLDigest`, last
    /// seen, up to 3 digests, newest first), sorted by id. Ends in this database have `End.database == nil`.
    public static func relationships(entries: [QueryHistoryEntry], knowledge: DatabaseKnowledge,
                                     otherDatabases: [String: [TableFacts]] = [:], now: Date) -> [Relationship] {
        let catalog = TableCatalog(knowledge: knowledge, otherDatabases: otherDatabases)
        var tallies: [String: Tally] = [:]
        for entry in entries where entry.errorMessage == nil {
            for statement in SQLStatementSplitter.split(entry.sql) where isMinable(statement.text) {
                let candidates = catalog.relationships(in: statement.text, defaultDatabase: entry.database)
                guard !candidates.isEmpty else { continue }
                let digest = normalizedDigest(statement.text)
                for candidate in candidates {
                    tallies[candidate.id, default: Tally(candidate)].record(digest: digest, at: entry.executedAt)
                }
            }
        }
        return tallies.values.map { $0.relationship(now: now) }.sorted { $0.id < $1.id }
    }

    /// The same mining over a view or materialized view definition (the query or the whole CREATE statement), giving
    /// `definition` evidence with the view's name as `symbol`. Unqualified tables are this database's.
    public static func definitionRelationships(definition: String, viewName: String, knowledge: DatabaseKnowledge,
                                               otherDatabases: [String: [TableFacts]] = [:], now: Date) -> [Relationship] {
        let catalog = TableCatalog(knowledge: knowledge, otherDatabases: otherDatabases)
        var byID: [String: Relationship] = [:]
        for statement in SQLStatementSplitter.split(definition) {
            for candidate in catalog.relationships(in: statement.text, defaultDatabase: knowledge.key.database) {
                let readsItself = [candidate.from, candidate.to].contains { $0.database == nil && $0.table == viewName }
                guard !readsItself, byID[candidate.id] == nil else { continue }
                let evidence = Evidence(source: .definition, symbol: viewName, at: now)
                byID[candidate.id] = Relationship(from: candidate.from, to: candidate.to, kind: candidate.kind, evidence: [evidence],
                                                  fingerprints: candidate.fingerprints)
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    // MARK: Statements

    /// SELECT, WITH, `(SELECT …)`, INSERT (its query) and CREATE [OR REPLACE] [MATERIALIZED] VIEW.
    static func isMinable(_ statement: String) -> Bool {
        let lexer = SQLLexer(statement)
        let words = lexer.tokens().lazy.filter { $0.kind != .comment }.prefix(6).map { lexer.text(of: $0).uppercased() }
        let leading = Array(words)
        guard let first = leading.first else { return false }
        switch first {
        case "SELECT", "WITH", "INSERT":
            return true
        case "(":
            return SQLStatementKind.of(statement) == .query
        case "CREATE":
            var rest = leading.dropFirst()
            if rest.starts(with: ["OR", "REPLACE"]) { rest = rest.dropFirst(2) }
            return rest.first == "VIEW" || rest.starts(with: ["MATERIALIZED", "VIEW"])
        default:
            return false
        }
    }

    /// `SQLDigest` on one line: literals are `?`, comments gone, whitespace runs single spaces.
    static func normalizedDigest(_ statement: String) -> String {
        SQLDigest.digest(statement).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Aggregation

    private struct Tally {
        let candidate: Candidate
        var count = 0
        /// Digest → last time it ran.
        var digests: [String: Date] = [:]

        init(_ candidate: Candidate) {
            self.candidate = candidate
        }

        mutating func record(digest: String, at date: Date) {
            count += 1
            if let seen = digests[digest], seen >= date { return }
            digests[digest] = date
        }

        func relationship(now: Date) -> Relationship {
            let newestFirst = digests.sorted { (lhs: (key: String, value: Date), rhs: (key: String, value: Date)) -> Bool in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            let samples = newestFirst.prefix(HistoryJoinMiner.maxSamples).map { String($0.key.prefix(HistoryJoinMiner.maxSampleLength)) }
            let evidence = Evidence(source: .history, statements: digests.count, count: count, lastSeen: newestFirst.first?.value,
                                    samples: Array(samples), at: now)
            return Relationship(from: candidate.from, to: candidate.to, kind: candidate.kind, evidence: [evidence],
                                fingerprints: candidate.fingerprints)
        }
    }

    /// A relationship found in one statement, before evidence is attached.
    private struct Candidate {
        let from: Relationship.End
        let to: Relationship.End
        let kind: Relationship.Kind
        let fingerprints: [String: String]

        var id: String { Relationship.id(from: from, to: to) }
    }

    // MARK: Tables

    /// The tables joins may name: this database's and the other databases', dropped ones excluded.
    private struct TableCatalog {
        /// This knowledge base's database.
        let home: String
        let tables: [String: [String: TableFacts]]
        /// Columns that declared foreign keys point at, so they identify rows: "database\u{1F}table" → column sets.
        let declaredKeys: [String: [Set<String>]]

        static let uniqueModels: Set<String> = ["PK", "UNI", "AGG", "PRIMARY", "UNIQUE", "AGGREGATE"]

        init(knowledge: DatabaseKnowledge, otherDatabases: [String: [TableFacts]]) {
            home = knowledge.key.database
            var tables: [String: [String: TableFacts]] = [:]
            for (database, facts) in otherDatabases where database != knowledge.key.database {
                tables[database] = Self.byName(facts)
            }
            tables[knowledge.key.database] = Self.byName(knowledge.tables)
            self.tables = tables
            var declaredKeys: [String: [Set<String>]] = [:]
            for relationship in knowledge.relationships where relationship.kind != .lineage {
                let declared = relationship.evidence.contains { $0.source == .declared && $0.verdict == .assert }
                guard declared else { continue }
                let database = relationship.to.database ?? knowledge.key.database
                declaredKeys[database + "\u{1F}" + relationship.to.table, default: []].append(Set(relationship.to.columns.map { $0.lowercased() }))
            }
            self.declaredKeys = declaredKeys
        }

        private static func byName(_ facts: [TableFacts]) -> [String: TableFacts] {
            var byName: [String: TableFacts] = [:]
            for table in facts where table.state != .dropped && byName[table.name] == nil { byName[table.name] = table }
            return byName
        }

        func facts(_ reference: TableReference, defaultDatabase: String?) -> (database: String, table: TableFacts)? {
            guard let database = reference.database ?? defaultDatabase, let table = tables[database]?[reference.table] else { return nil }
            return (database, table)
        }

        /// Relationships of the joins one statement writes, each once.
        func relationships(in statement: String, defaultDatabase: String?) -> [Candidate] {
            let pairs = SQLJoinExtractor.joins(in: statement, columnsOf: { (reference: TableReference) -> [String]? in
                facts(reference, defaultDatabase: defaultDatabase)?.table.columns.map(\.name)
            })
            var seen: Set<String> = []
            var result: [Candidate] = []
            for pair in pairs {
                guard let candidate = candidate(pair, defaultDatabase: defaultDatabase), seen.insert(candidate.id).inserted else { continue }
                result.append(candidate)
            }
            return result
        }

        private func candidate(_ pair: JoinPair, defaultDatabase: String?) -> Candidate? {
            guard let left = side(pair.left, pair.leftColumns, defaultDatabase: defaultDatabase),
                  let right = side(pair.right, pair.rightColumns, defaultDatabase: defaultDatabase),
                  left.columns.count == right.columns.count else { return nil }
            let sameTable = left.database == right.database && left.table.name == right.table.name
            if sameTable, Set(left.columns.map { $0.lowercased() }) == Set(right.columns.map { $0.lowercased() }) { return nil }

            let leftIsKey = identifiesRows(left)
            let rightIsKey = identifiesRows(right)
            let kind: Relationship.Kind
            let leftFirst: Bool
            if leftIsKey != rightIsKey {
                kind = .manyToOne
                leftFirst = rightIsKey
            } else {
                kind = leftIsKey ? .oneToOne : .manyToMany
                leftFirst = left.sortKey <= right.sortKey
            }
            let from: Side = leftFirst ? left : right
            let to: Side = leftFirst ? right : left
            let columnPairs = zip(from.columns, to.columns).sorted { (lhs: (String, String), rhs: (String, String)) -> Bool in
                let lhsKey = (lhs.0.lowercased(), lhs.1.lowercased())
                let rhsKey = (rhs.0.lowercased(), rhs.1.lowercased())
                return lhsKey < rhsKey
            }
            let fromEnd = Relationship.End(database: endDatabase(from), table: from.table.name, columns: columnPairs.map(\.0))
            let toEnd = Relationship.End(database: endDatabase(to), table: to.table.name, columns: columnPairs.map(\.1))
            // A self-join has one table: a dictionary literal with the key twice would trap.
            let fingerprints = Dictionary([(fingerprintKey(from), from.table.fingerprint), (fingerprintKey(to), to.table.fingerprint)],
                                          uniquingKeysWith: { (first: String, _: String) -> String in first })
            return Candidate(from: fromEnd, to: toEnd, kind: kind, fingerprints: fingerprints)
        }

        /// One end of a join: a known table and the columns named, in the table's own spelling.
        private struct Side {
            let database: String
            let table: TableFacts
            let columns: [String]

            var sortKey: String { database + "\u{1F}" + table.name + "\u{1F}" + columns.joined(separator: ",") }
        }

        private func side(_ reference: TableReference, _ columns: [String], defaultDatabase: String?) -> Side? {
            guard let (database, table) = facts(reference, defaultDatabase: defaultDatabase), !columns.isEmpty else { return nil }
            var spelled: [String] = []
            for column in columns {
                guard let known = table.column(named: column) else { return nil }
                spelled.append(known.name)
            }
            return Side(database: database, table: table, columns: spelled)
        }

        /// Whether the columns contain a key of their table, so each value names one row.
        private func identifiesRows(_ side: Side) -> Bool {
            let columns = Set(side.columns.map { $0.lowercased() })
            if columns.contains("id") { return true }
            let primary = Set(side.table.keys.primary.map { $0.lowercased() })
            if !primary.isEmpty, primary.isSubset(of: columns) { return true }
            if let model = side.table.model?.uppercased(), Self.uniqueModels.contains(model) {
                let keys = Set(side.table.columns.filter(\.isKey).map { $0.name.lowercased() })
                if !keys.isEmpty, keys.isSubset(of: columns) { return true }
            }
            let declared = declaredKeys[side.database + "\u{1F}" + side.table.name] ?? []
            return declared.contains { !$0.isEmpty && $0.isSubset(of: columns) }
        }

        private func endDatabase(_ side: Side) -> String? {
            side.database == home ? nil : side.database
        }

        private func fingerprintKey(_ side: Side) -> String {
            side.database == home ? side.table.name : side.database + "." + side.table.name
        }
    }
}
