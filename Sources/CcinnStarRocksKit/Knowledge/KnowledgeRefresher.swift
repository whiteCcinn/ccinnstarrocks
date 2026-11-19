import Foundation
import StarRocksKit

/// Merges a fresh extraction into a database's knowledge (pure; the caller saves). Tables become new, fresh, changed or
/// dropped; relationships from machine sources (declared, lineage, definition, history, naming) are recomputed every
/// time, while what the user, code references and AI added stays.
public enum KnowledgeRefresher {
    public struct Report: Codable, Sendable, Equatable {
        public struct Tables: Codable, Sendable, Equatable {
            /// Tables on the server now.
            public var total = 0
            public var new = 0
            public var changed = 0
            public var dropped = 0

            public init(total: Int = 0, new: Int = 0, changed: Int = 0, dropped: Int = 0) {
                self.total = total
                self.new = new
                self.changed = changed
                self.dropped = dropped
            }
        }

        public struct Relationships: Codable, Sendable, Equatable {
            public var added = 0
            public var removed = 0
            /// Relationships whose tables changed since their evidence was written.
            public var nowStale = 0

            public init(added: Int = 0, removed: Int = 0, nowStale: Int = 0) {
                self.added = added
                self.removed = removed
                self.nowStale = nowStale
            }
        }

        public var tables = Tables()
        /// `[dropped, new]` pairs with the same structure; never moved automatically.
        public var possibleRenames: [[String]] = []
        public var relationships = Relationships()
        public var notesStale = 0

        public init() {}
    }

    static let machineSources: Set<Evidence.Source> = [.declared, .lineage, .definition, .history, .naming]

    /// Applies the extraction and the machine relationships inferred from it. Lineage relationships are derived here from
    /// the views' and materialized views' facts.
    ///
    /// `partial`: the extraction came through an account that may see less than the knowledge holds (an AI session's
    /// connection; `information_schema` lists only what it may read). Tables it does not list are not dropped, a table it
    /// sees only some columns of or a view or materialized view whose definition it cannot read is left as it was,
    /// relationships with an end it did not see keep their evidence, and the report counts only what it saw. Only the
    /// user's refresh in the app marks tables dropped.
    @discardableResult
    public static func apply(_ schema: ExtractedSchema, machineRelationships: [Relationship], to knowledge: inout DatabaseKnowledge, now: Date,
                             partial: Bool = false) -> Report {
        var report = Report()
        let seen = updateTables(schema, in: &knowledge, now: now, report: &report, partial: partial)
        if let version = schema.serverVersion { knowledge.serverVersion = version }
        knowledge.refreshedAt = now
        let scope: Set<String>? = partial ? seen : nil
        mergeMachineRelationships(machineRelationships + lineageRelationships(knowledge.tables, now: now), into: &knowledge, report: &report, scope: scope)
        let inScope = { (relationship: Relationship) -> Bool in isInScope(relationship, scope) }
        report.relationships.nowStale = knowledge.relationships.filter { inScope($0) && KnowledgeFreshness.isStale($0, in: knowledge) }.count
        report.notesStale = knowledge.notes.filter { (scope?.contains($0.table) ?? true) && KnowledgeFreshness.isStale($0, in: knowledge) }.count
        return report
    }

    /// Whether every end of `relationship` in this database is among `scope` (every relationship when `scope` is nil).
    static func isInScope(_ relationship: Relationship, _ scope: Set<String>?) -> Bool {
        guard let scope else { return true }
        return [relationship.from, relationship.to].allSatisfy { $0.database != nil || scope.contains($0.table) }
    }

    // MARK: Tables

    /// Returns the names of the tables the extraction saw.
    @discardableResult
    static func updateTables(_ schema: ExtractedSchema, in knowledge: inout DatabaseKnowledge, now: Date, report: inout Report,
                             partial: Bool = false) -> Set<String> {
        var previous: [String: TableFacts] = [:]
        for table in knowledge.tables { previous[table.name] = table }
        var tables: [TableFacts] = []
        var seen: Set<String> = []
        for extracted in schema.tables {
            if partial, let old = previous[extracted.object.name], old.state != .dropped, !isFullySeen(extracted, comparedTo: old) {
                seen.insert(old.name)
                tables.append(old)
                continue
            }
            let facts = tableFacts(extracted, database: schema.database, previous: previous[extracted.object.name], now: now)
            seen.insert(facts.name)
            switch facts.state {
            case .new: report.tables.new += 1
            case .changed: report.tables.changed += 1
            case .fresh, .dropped: break
            }
            tables.append(facts)
        }
        report.tables.total = tables.count
        if partial {
            let unseen = knowledge.tables.filter { !seen.contains($0.name) }
            knowledge.tables = (tables + unseen).sorted { $0.name < $1.name }
            return seen
        }
        var dropped: [TableFacts] = []
        for old in knowledge.tables where !seen.contains(old.name) {
            var gone = old
            if gone.state != .dropped {
                gone.state = .dropped
                gone.changedAt = now
                report.tables.dropped += 1
            }
            dropped.append(gone)
        }
        let newByFingerprint = Dictionary(grouping: tables.filter { $0.state == .new }, by: \.fingerprint)
        for gone in dropped where gone.changedAt == now {
            for candidate in newByFingerprint[gone.fingerprint] ?? [] { report.possibleRenames.append([gone.name, candidate.name]) }
        }
        report.possibleRenames.sort { $0.joined(separator: "\u{1F}") < $1.joined(separator: "\u{1F}") }
        knowledge.tables = (tables + dropped).sorted { $0.name < $1.name }
        return seen
    }

    /// Whether an extraction shows all of an object the knowledge already describes: not for a view or materialized view
    /// whose definition it cannot read, nor when every column it lists is a known column of the same type but some are
    /// missing.
    static func isFullySeen(_ extracted: ExtractedTable, comparedTo old: TableFacts) -> Bool {
        let readsADefinition: Bool = extracted.object.kind == .view || extracted.object.kind == .asyncMaterializedView
        if readsADefinition, extracted.definition == nil { return false }
        guard extracted.columns.count < old.columns.count else { return true }
        let known = Dictionary(old.columns.map { ($0.name.lowercased(), $0.type.lowercased()) }, uniquingKeysWith: { first, _ in first })
        let subset = extracted.columns.allSatisfy { (column: ColumnInfo) -> Bool in
            let type = column.columnType.isEmpty ? column.dataType : column.columnType
            return known[column.name.lowercased()] == type.lowercased()
        }
        return !subset
    }

    /// The facts of one extracted object; `previous` decides new / fresh / changed and keeps `firstSeen`.
    public static func tableFacts(_ table: ExtractedTable, database: String, previous: TableFacts?, now: Date) -> TableFacts {
        let object = table.object
        let kind: TableFacts.Kind
        switch object.kind {
        case .table: kind = .table
        case .view: kind = .view
        case .asyncMaterializedView, .syncMaterializedView: kind = .materializedView
        case .externalTable: kind = .externalTable
        case .systemView: kind = .systemView
        }
        let keys = TableFacts.Keys(primary: keyList(object.primaryKey), sort: keyList(object.sortKey),
                                   distribution: keyList(object.distributionKey), partition: keyList(object.partitionKey))
        let columns: [ColumnFacts] = table.columns.sorted { $0.ordinal < $1.ordinal }.map { (column: ColumnInfo) -> ColumnFacts in
            ColumnFacts(name: column.name, type: column.columnType.isEmpty ? column.dataType : column.columnType, isKey: column.isKey,
                        isNullable: column.isNullable, aggregation: column.aggregation, comment: column.comment?.nilIfEmpty)
        }
        let model = object.model?.badge
        let fingerprint = SchemaFingerprint.structure(kind: kind, model: model, keys: keys, columns: columns, definition: table.definition)
        var facts = TableFacts(name: object.name, kind: kind, model: model, comment: object.comment?.nilIfEmpty, keys: keys, columns: columns,
                               lineage: lineage(table, database: database), fingerprint: fingerprint,
                               commentFingerprint: SchemaFingerprint.comments(table: object.comment, columns: columns), state: .new, firstSeen: now)
        if let previous {
            facts.firstSeen = previous.firstSeen
            if previous.fingerprint == fingerprint, previous.state != .dropped {
                facts.state = .fresh
                facts.changedAt = previous.changedAt
            } else {
                facts.state = .changed
                facts.changedAt = now
            }
        }
        return facts
    }

    /// `` `dt`, hour `` → ["dt", "hour"]; expressions keep their text.
    static func keyList(_ text: String?) -> [String] {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`")) }.filter { !$0.isEmpty }
    }

    /// Base tables a view or materialized view reads (its query, or a sync MV's base table).
    static func lineage(_ table: ExtractedTable, database: String) -> [TableReference] {
        var references: Set<TableReference> = []
        if let base = table.object.baseTable { references.insert(TableReference(table: base)) }
        if let definition = table.definition {
            let lexer = SQLLexer(definition)
            let tokens = lexer.tokens().filter { $0.kind != .comment }
            for reference in SQLTableReferences.references(tokens: tokens, lexer: lexer) where reference.derivedColumns == nil {
                let otherDatabase: String? = reference.database.flatMap { $0 == database ? nil : $0 }
                references.insert(TableReference(database: otherDatabase, table: reference.table))
            }
        }
        references.remove(TableReference(table: table.object.name))
        return references.sorted()
    }

    static func lineageRelationships(_ tables: [TableFacts], now: Date) -> [Relationship] {
        tables.filter { $0.state != .dropped }.flatMap { (table: TableFacts) -> [Relationship] in
            table.lineage.map { (base: TableReference) -> Relationship in
                Relationship(from: .init(table: table.name, columns: []), to: .init(database: base.database, table: base.table, columns: []),
                             kind: .lineage, evidence: [Evidence(source: .lineage, at: now)])
            }
        }
    }

    // MARK: Relationships

    /// `scope`: for a partial refresh, the tables the extraction saw; relationships with an end outside it keep their
    /// machine evidence and are not counted.
    static func mergeMachineRelationships(_ machine: [Relationship], into knowledge: inout DatabaseKnowledge, report: inout Report,
                                          scope: Set<String>? = nil) {
        let tombstoned = Set(knowledge.tombstones.map(\.id))
        var byID: [String: Relationship] = [:]
        var order: [String] = []
        var outside: Set<String> = []
        for var relationship in knowledge.relationships {
            if isInScope(relationship, scope) {
                relationship.evidence.removeAll { machineSources.contains($0.source) }
            } else {
                outside.insert(relationship.id)
            }
            byID[relationship.id] = relationship
            order.append(relationship.id)
        }
        let previousIDs = Set(order)
        let fingerprints = currentFingerprints(knowledge)
        for incoming in machine where !tombstoned.contains(incoming.id) && !outside.contains(incoming.id) && isInScope(incoming, scope) {
            var current = fingerprints(incoming)
            if var existing = byID[incoming.id] {
                existing.evidence += incoming.evidence
                current.merge(existing.fingerprints) { (refreshed: String, _: String) -> String in refreshed }
                existing.fingerprints = current
                byID[incoming.id] = existing
            } else {
                var relationship = incoming
                relationship.fingerprints = current
                byID[incoming.id] = relationship
                order.append(incoming.id)
            }
        }
        var merged: [Relationship] = []
        for id in Set(order).sorted() {
            guard let relationship = byID[id], !relationship.evidence.isEmpty else { continue }
            merged.append(relationship)
        }
        let mergedIDs = Set(merged.map(\.id)).subtracting(outside)
        let previousInScope = previousIDs.subtracting(outside)
        report.relationships.added = mergedIDs.subtracting(previousInScope).count
        report.relationships.removed = previousInScope.subtracting(mergedIDs).count
        knowledge.relationships = merged
    }

    /// Machine evidence is current by construction: its relationship records the tables' fingerprints of this refresh.
    private static func currentFingerprints(_ knowledge: DatabaseKnowledge) -> (Relationship) -> [String: String] {
        var byName: [String: String] = [:]
        for table in knowledge.tables where table.state != .dropped { byName[table.name] = table.fingerprint }
        return { (relationship: Relationship) -> [String: String] in
            var result: [String: String] = [:]
            for end in [relationship.from, relationship.to] where end.database == nil {
                if let fingerprint = byName[end.table] { result[end.table] = fingerprint }
            }
            return result
        }
    }
}

/// Whether knowledge still describes the tables it was written for.
public enum KnowledgeFreshness {
    /// A table it involves changed (or was dropped) since its evidence was written. Ends in other databases are checked
    /// against `otherFingerprints` (`db.table` → fingerprint) when given.
    public static func isStale(_ relationship: Relationship, in knowledge: DatabaseKnowledge, otherFingerprints: [String: String] = [:]) -> Bool {
        for end in [relationship.from, relationship.to] {
            if let database = end.database {
                let name = database + "." + end.table
                if let current = otherFingerprints[name], let recorded = relationship.fingerprints[name], current != recorded { return true }
                continue
            }
            guard let table = knowledge.table(named: end.table), table.state != .dropped else { return true }
            if let recorded = relationship.fingerprints[end.table], recorded != table.fingerprint { return true }
        }
        return false
    }

    /// A column it joins on no longer exists (ends in this database only).
    public static func isBroken(_ relationship: Relationship, in knowledge: DatabaseKnowledge) -> Bool {
        for end in [relationship.from, relationship.to] where end.database == nil {
            guard let table = knowledge.table(named: end.table), table.state != .dropped else { return true }
            if end.columns.contains(where: { table.column(named: $0) == nil }) { return true }
        }
        return false
    }

    public static func isStale(_ note: Note, in knowledge: DatabaseKnowledge) -> Bool {
        guard let table = knowledge.table(named: note.table), table.state != .dropped else { return true }
        guard let recorded = note.fingerprint else { return false }
        return recorded != table.fingerprint
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
