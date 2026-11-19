import Foundation

/// What merging one database's imported knowledge changes, for the preview and the report.
public struct BackupKnowledgeChanges: Sendable, Equatable {
    public var tablesAdded = 0
    public var tablesUpdated = 0
    public var relationshipsAdded = 0
    public var relationshipsUpdated = 0
    public var notesAdded = 0
    public var notesUpdated = 0
    public var termsAdded = 0
    public var termsUpdated = 0
    public var areasAdded = 0
    public var areasUpdated = 0
    /// Local items deleted because the backup holds their tombstone.
    public var removed = 0

    public init() {}

    public var isEmpty: Bool { self == BackupKnowledgeChanges() }
}

/// Merges knowledge item by item. Pure: the planner runs it against a snapshot for the preview, the applier again
/// under the knowledge lock against what is on disk then.
///
/// - Tables: the side refreshed more recently wins for a table both have; tables only one side has are kept.
/// - Notes, terms, areas: union by id; the newer `at` wins; ties keep the local copy.
/// - Relationships: union by id; evidence is a union without duplicates (at most 20), the rest comes from the side with
///   the newest evidence.
/// - Tombstones: a union. An id with a tombstone is never added and is removed locally, so a re-import never brings a
///   deleted item back and a deletion made on the other Mac travels.
enum BackupKnowledgeMerge {
    static let maximumEvidence = 20

    static func merge(local: DatabaseKnowledge?, imported: DatabaseKnowledge) -> (merged: DatabaseKnowledge, changes: BackupKnowledgeChanges) {
        let base = local ?? DatabaseKnowledge(key: imported.key)
        var merged = base
        var changes = BackupKnowledgeChanges()
        merged.tombstones = mergeTombstones(base.tombstones, imported.tombstones)
        let deleted = Set(merged.tombstones.map(\.id))

        let localRefresh = base.refreshedAt ?? .distantPast
        let importedRefresh = imported.refreshedAt ?? .distantPast
        let importedIsNewer = importedRefresh > localRefresh
        mergeTables(&merged.tables, imported.tables, importedWins: importedIsNewer, changes: &changes)
        if importedIsNewer {
            merged.refreshedAt = imported.refreshedAt
            merged.serverVersion = imported.serverVersion ?? base.serverVersion
        } else if merged.serverVersion == nil {
            merged.serverVersion = imported.serverVersion
        }

        let notes = union(base.notes, imported.notes.filter { !deleted.contains($0.id) }, id: \.id, at: \.at)
        let terms = union(base.terms, imported.terms.filter { !deleted.contains($0.id) }, id: \.id, at: \.at)
        let areas = union(base.areas, imported.areas.filter { !deleted.contains($0.id) }, id: \.id, at: \.at)
        let relationships = mergeRelationships(base.relationships, imported.relationships.filter { !deleted.contains($0.id) })
        changes.notesAdded = notes.added
        changes.notesUpdated = notes.updated
        changes.termsAdded = terms.added
        changes.termsUpdated = terms.updated
        changes.areasAdded = areas.added
        changes.areasUpdated = areas.updated
        changes.relationshipsAdded = relationships.added
        changes.relationshipsUpdated = relationships.updated

        let before: Int = notes.items.count + terms.items.count + areas.items.count + relationships.items.count
        merged.notes = notes.items.filter { !deleted.contains($0.id) }
        merged.terms = terms.items.filter { !deleted.contains($0.id) }
        merged.areas = areas.items.filter { !deleted.contains($0.id) }
        merged.relationships = relationships.items.filter { !deleted.contains($0.id) }
        let after: Int = merged.notes.count + merged.terms.count + merged.areas.count + merged.relationships.count
        changes.removed = before - after
        return (merged, changes)
    }

    // MARK: Items

    private static func mergeTables(_ tables: inout [TableFacts], _ imported: [TableFacts], importedWins: Bool, changes: inout BackupKnowledgeChanges) {
        var positions: [String: Int] = [:]
        for (position, table) in tables.enumerated() { positions[table.name] = position }
        var added = false
        for table in imported {
            if let position = positions[table.name] {
                guard importedWins, tables[position] != table else { continue }
                tables[position] = table
                changes.tablesUpdated += 1
            } else {
                positions[table.name] = tables.count
                tables.append(table)
                changes.tablesAdded += 1
                added = true
            }
        }
        // `KnowledgeStore` keeps tables sorted by name; an unchanged list stays exactly as it was.
        if added { tables.sort { $0.name < $1.name } }
    }

    private static func union<Item: Equatable>(_ local: [Item], _ imported: [Item], id: KeyPath<Item, String>,
                                               at: KeyPath<Item, Date>) -> (items: [Item], added: Int, updated: Int) {
        var items = local
        var positions: [String: Int] = [:]
        for (position, item) in items.enumerated() { positions[item[keyPath: id]] = position }
        var added = 0
        var updated = 0
        for item in imported {
            let key = item[keyPath: id]
            if let position = positions[key] {
                let existing = items[position]
                guard item[keyPath: at] > existing[keyPath: at], item != existing else { continue }
                items[position] = item
                updated += 1
            } else {
                positions[key] = items.count
                items.append(item)
                added += 1
            }
        }
        return (items, added, updated)
    }

    private static func mergeRelationships(_ local: [Relationship], _ imported: [Relationship]) -> (items: [Relationship], added: Int, updated: Int) {
        var items = local
        var positions: [String: Int] = [:]
        for (position, relationship) in items.enumerated() { positions[relationship.id] = position }
        var added = 0
        var updated = 0
        for relationship in imported {
            guard let position = positions[relationship.id] else {
                positions[relationship.id] = items.count
                items.append(relationship)
                added += 1
                continue
            }
            let existing = items[position]
            var combined = latestEvidence(relationship) > latestEvidence(existing) ? relationship : existing
            combined.evidence = unionOfEvidence(existing.evidence, relationship.evidence)
            guard combined != existing else { continue }
            items[position] = combined
            updated += 1
        }
        return (items, added, updated)
    }

    /// Local evidence first, then imported evidence not already present.
    private static func unionOfEvidence(_ local: [Evidence], _ imported: [Evidence]) -> [Evidence] {
        var evidence = local
        for item in imported where !evidence.contains(item) {
            evidence.append(item)
        }
        return Array(evidence.prefix(maximumEvidence))
    }

    private static func latestEvidence(_ relationship: Relationship) -> Date {
        var latest = Date.distantPast
        for evidence in relationship.evidence {
            let time = evidence.at ?? evidence.lastSeen ?? .distantPast
            if time > latest { latest = time }
        }
        return latest
    }

    static func mergeTombstones(_ local: [Tombstone], _ imported: [Tombstone]) -> [Tombstone] {
        var tombstones = local
        var positions: [String: Int] = [:]
        for (position, tombstone) in tombstones.enumerated() { positions[tombstone.id] = position }
        for tombstone in imported {
            if let position = positions[tombstone.id] {
                if tombstone.deletedAt > tombstones[position].deletedAt { tombstones[position] = tombstone }
            } else {
                positions[tombstone.id] = tombstones.count
                tombstones.append(tombstone)
            }
        }
        return tombstones
    }
}
