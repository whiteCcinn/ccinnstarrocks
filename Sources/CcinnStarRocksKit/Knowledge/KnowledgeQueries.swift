import Foundation

/// Shared rules of the query engine.
enum KnowledgeRules {
    /// Rejected by the user (or stored as rejected): never shown, never joined.
    static func isRejected(_ relationship: Relationship) -> Bool {
        if relationship.status == .rejected { return true }
        return relationship.evidence.contains { (evidence: Evidence) -> Bool in evidence.source == .user && evidence.verdict == .reject }
    }

    /// Sources that assert the relationship, in a stable order.
    static func sources(_ relationship: Relationship) -> [String] {
        let present = Set(relationship.evidence.filter { $0.verdict == .assert }.map(\.source))
        return Evidence.Source.allCases.filter { present.contains($0) }.map(\.rawValue)
    }

    /// `table`, or `db.table` for another database.
    static func node(_ end: Relationship.End) -> String {
        end.database.map { $0 + "." + end.table } ?? end.table
    }

    static func condition(_ relationship: Relationship, leftFirst left: String) -> String {
        let fromNode = node(relationship.from)
        let toNode = node(relationship.to)
        let pairs: [String] = zip(relationship.from.columns, relationship.to.columns).map { (pair: (String, String)) -> String in
            fromNode == left ? "\(fromNode).\(pair.0) = \(toNode).\(pair.1)" : "\(toNode).\(pair.1) = \(fromNode).\(pair.0)"
        }
        return pairs.joined(separator: " AND ")
    }

    /// Cardinality seen when moving from `origin` across the relationship.
    static func cardinality(_ relationship: Relationship, from origin: String) -> String {
        let forward = node(relationship.from) == origin
        switch relationship.kind {
        case .manyToOne: return forward ? "n:1" : "1:n"
        case .oneToOne: return "1:1"
        case .manyToMany: return "n:n"
        case .sharedKey: return "shared"
        case .lineage: return "lineage"
        }
    }

    /// Lower-cased words of a name or question: `reportAdxHour`, `report_adx_hour` and `report adx hour` all give
    /// report / adx / hour. CJK runs stay whole.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousIsLower = false
        for character in text {
            let isWordCharacter = character.isLetter || character.isNumber
            if !isWordCharacter {
                if !current.isEmpty { tokens.append(current.lowercased()) }
                current = ""
                previousIsLower = false
                continue
            }
            if character.isUppercase, previousIsLower, !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousIsLower = character.isLowercase
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }
}

/// Finds tables, columns, notes and glossary entries for a question, best first.
public enum KnowledgeSearch {
    public struct Hit: Codable, Sendable, Equatable {
        /// table, column, note or term.
        public var type: String
        public var name: String
        public var why: String
        public var score: Int

        public init(type: String, name: String, why: String, score: Int) {
            self.type = type
            self.name = name
            self.why = why
            self.score = score
        }
    }

    public enum Scope: String, CaseIterable, Codable, Sendable {
        case tables, columns, notes, terms
    }

    /// Scores: exact name 100, glossary term or synonym 90 (substring 50), every name token 60, prefix 40, column 30,
    /// comment or note text 20. Ties are ordered by name, so results are stable.
    public static func search(_ query: String, in knowledge: DatabaseKnowledge, scopes: Set<Scope> = Set(Scope.allCases),
                              limit: Int = 20) -> (hits: [Hit], truncated: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !lowered.isEmpty else { return ([], false) }
        let tokens = KnowledgeRules.tokens(trimmed) // before lower-casing: camelCase marks the word boundaries
        let joined = tokens.joined(separator: "_")
        var best: [String: Hit] = [:]
        func offer(_ hit: Hit) {
            let key = hit.type + "\u{1F}" + hit.name
            if let current = best[key], current.score >= hit.score { return }
            best[key] = hit
        }
        let live = knowledge.tables.filter { $0.state != .dropped }
        let liveNames = Set(live.map(\.name))
        if scopes.contains(.tables) {
            for table in live {
                let name = table.name.lowercased()
                let nameTokens = Set(KnowledgeRules.tokens(table.name))
                if name == lowered || name == joined {
                    offer(Hit(type: "table", name: table.name, why: "name", score: 100))
                } else if !tokens.isEmpty, tokens.allSatisfy({ nameTokens.contains($0) }) {
                    offer(Hit(type: "table", name: table.name, why: "name", score: 60))
                } else if name.hasPrefix(lowered) || nameTokens.contains(where: { $0.hasPrefix(lowered) }) {
                    offer(Hit(type: "table", name: table.name, why: "name prefix", score: 40))
                }
                if let comment = table.comment?.lowercased(), comment.contains(lowered) {
                    offer(Hit(type: "table", name: table.name, why: "comment", score: 20))
                }
            }
        }
        if scopes.contains(.terms) {
            for term in knowledge.terms {
                let words: [String] = ([term.term] + term.synonyms).map { $0.lowercased() }
                let score: Int
                if words.contains(lowered) {
                    score = 90
                } else if lowered.count >= 2, words.contains(where: { $0.contains(lowered) }) {
                    score = 50
                } else {
                    continue
                }
                for mapping in term.mapsTo where liveNames.contains(mapping.table) {
                    offer(Hit(type: "table", name: mapping.table, why: "term: " + term.term, score: score))
                }
                offer(Hit(type: "term", name: term.term, why: "glossary", score: score - 5))
            }
        }
        if scopes.contains(.columns) {
            for table in live {
                for column in table.columns {
                    let name = column.name.lowercased()
                    let columnTokens = Set(KnowledgeRules.tokens(column.name))
                    let qualified = table.name + "." + column.name
                    if name == lowered || name == joined || (!tokens.isEmpty && tokens.allSatisfy { columnTokens.contains($0) }) {
                        offer(Hit(type: "column", name: qualified, why: "column", score: 30))
                    } else if let comment = column.comment?.lowercased(), comment.contains(lowered) {
                        offer(Hit(type: "column", name: qualified, why: "column comment", score: 20))
                    }
                }
            }
        }
        if scopes.contains(.notes) {
            for note in knowledge.notes where liveNames.contains(note.table) && note.text.lowercased().contains(lowered) {
                offer(Hit(type: "note", name: note.table + (note.column.map { "." + $0 } ?? ""), why: "note " + note.id, score: 20))
            }
        }
        let sorted = best.values.sorted { (left: Hit, right: Hit) -> Bool in
            if left.score != right.score { return left.score > right.score }
            if left.name != right.name { return left.name < right.name }
            return left.type < right.type
        }
        let limit = max(1, limit)
        return (Array(sorted.prefix(limit)), sorted.count > limit)
    }
}

/// Everything known about one table, compact enough for an AI's context.
public struct TableExplanation: Codable, Sendable, Equatable {
    public struct RelationshipSummary: Codable, Sendable, Equatable {
        public var id: String
        /// `out` when this table holds the foreign columns, `in` otherwise.
        public var direction: String
        public var other: String
        public var on: String
        /// n:1, 1:n, 1:1, n:n, shared or lineage, seen from this table.
        public var cardinality: String
        public var confidence: Int
        public var sources: [String]
        /// fresh, stale (a table changed since the evidence) or broken (a column is gone).
        public var state: String
        public var status: String
    }

    public struct NoteSummary: Codable, Sendable, Equatable {
        public var id: String
        public var column: String?
        public var kind: String
        public var text: String
        public var by: String
        public var at: Date
        public var stale: Bool
    }

    public struct TermSummary: Codable, Sendable, Equatable {
        public var term: String
        public var definition: String
        public var expression: String?
    }

    public struct Usage: Codable, Sendable, Equatable {
        public var project: String
        public var path: String
        public var line: Int?
        public var symbol: String?

        public init(project: String, path: String, line: Int?, symbol: String?) {
            self.project = project
            self.path = path
            self.line = line
            self.symbol = symbol
        }
    }

    public var table: String
    public var kind: String
    public var model: String?
    public var comment: String?
    public var state: String
    public var refreshedAt: Date?
    public var keys: TableFacts.Keys
    public var columnFormat = ["name", "type", "flags", "comment"]
    public var columns: [[String]]
    public var relationships: [RelationshipSummary]
    public var notes: [NoteSummary]
    public var terms: [TermSummary]
    public var usedBy: [Usage]
    public var hints: [String]

    public static func explain(table name: String, in knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int,
                               projects: [KnowledgeIndex.Project]) -> TableExplanation? {
        guard let table = knowledge.table(named: name) else { return nil }
        let involving = knowledge.relationships.filter { (relationship: Relationship) -> Bool in
            let touches = (relationship.from.database == nil && relationship.from.table == name)
                || (relationship.to.database == nil && relationship.to.table == name)
            return touches && !KnowledgeRules.isRejected(relationship)
        }
        var summaries: [RelationshipSummary] = involving.map { (relationship: Relationship) -> RelationshipSummary in
            let outgoing = relationship.from.database == nil && relationship.from.table == name
            let other = KnowledgeRules.node(outgoing ? relationship.to : relationship.from)
            let state: String
            if KnowledgeFreshness.isBroken(relationship, in: knowledge) {
                state = "broken"
            } else if KnowledgeFreshness.isStale(relationship, in: knowledge) {
                state = "stale"
            } else {
                state = "fresh"
            }
            let on = relationship.kind == .lineage ? "" : KnowledgeRules.condition(relationship, leftFirst: KnowledgeRules.node(relationship.from))
            return RelationshipSummary(id: relationship.id, direction: outgoing ? "out" : "in", other: other, on: on,
                                       cardinality: KnowledgeRules.cardinality(relationship, from: name), confidence: confidence(relationship),
                                       sources: KnowledgeRules.sources(relationship), state: state, status: relationship.status.rawValue)
        }
        summaries.sort { (left: RelationshipSummary, right: RelationshipSummary) -> Bool in
            left.confidence != right.confidence ? left.confidence > right.confidence : left.other < right.other
        }
        let notes: [NoteSummary] = knowledge.notes.filter { $0.table == name }.map { (note: Note) -> NoteSummary in
            NoteSummary(id: note.id, column: note.column, kind: note.kind.rawValue, text: note.text, by: note.by, at: note.at,
                        stale: KnowledgeFreshness.isStale(note, in: knowledge))
        }
        let terms: [TermSummary] = knowledge.terms.compactMap { (term: Term) -> TermSummary? in
            guard let mapping = term.mapsTo.first(where: { $0.table == name }) else { return nil }
            return TermSummary(term: term.term, definition: term.definition, expression: mapping.expression)
        }
        return TableExplanation(table: name, kind: table.kind.rawValue, model: table.model, comment: table.comment, state: table.state.rawValue,
                                refreshedAt: knowledge.refreshedAt, keys: table.keys,
                                columns: table.columns.map { [$0.name, $0.type, $0.flags, $0.comment ?? ""] }, relationships: summaries,
                                notes: notes, terms: terms, usedBy: usages(involving: involving, notes: knowledge.notes.filter { $0.table == name }, projects: projects),
                                hints: hints(for: table, in: knowledge))
    }

    static func usages(involving relationships: [Relationship], notes: [Note], projects: [KnowledgeIndex.Project]) -> [Usage] {
        var names: [String: String] = [:]
        for project in projects { names[project.id] = project.name }
        var seen: Set<String> = []
        var usages: [Usage] = []
        let evidence: [Evidence] = relationships.flatMap(\.evidence) + notes.flatMap(\.evidence)
        for item in evidence where item.source == .code {
            guard let path = item.path else { continue }
            let project = item.project.map { names[$0] ?? $0 } ?? "?"
            let key = project + "\u{1F}" + path + "\u{1F}" + String(item.line ?? 0)
            guard seen.insert(key).inserted else { continue }
            usages.append(Usage(project: project, path: path, line: item.line, symbol: item.symbol))
        }
        return usages.sorted { ($0.project, $0.path, $0.line ?? 0) < ($1.project, $1.path, $1.line ?? 0) }
    }

    static func hints(for table: TableFacts, in knowledge: DatabaseKnowledge) -> [String] {
        var hints: [String] = []
        if !table.keys.partition.isEmpty {
            let keys = table.keys.partition.map { "`\($0)`" }.joined(separator: ", ")
            hints.append("Filter on the partition key \(keys) so StarRocks prunes partitions.")
        }
        switch table.model {
        case "AGG":
            hints.append("AGG model: value columns are pre-aggregated (SUM, REPLACE, MAX …) per key; aggregate them again with the same function when grouping.")
        case "PK", "UNI":
            hints.append("\(table.model ?? "") model: one row per key; the latest load wins.")
        default:
            break
        }
        let readers = knowledge.tables.filter { (other: TableFacts) -> Bool in
            other.kind == .materializedView && other.state != .dropped && other.lineage.contains(TableReference(table: table.name))
        }.map(\.name)
        if !readers.isEmpty {
            hints.append("Materialized views read this table: \(readers.joined(separator: ", ")); the optimizer may rewrite matching queries to them.")
        }
        return hints
    }
}
