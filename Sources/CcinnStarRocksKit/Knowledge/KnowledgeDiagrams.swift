import Foundation

/// Groups of tables worth looking at together: curated areas, groups connected by trustworthy relationships, and
/// tables sharing a name prefix.
public enum SubjectAreas {
    public struct Area: Codable, Sendable, Equatable {
        public var name: String
        /// curated, connected or prefix.
        public var source: String
        public var tables: [String]
        public var description: String?
    }

    public static func areas(in knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int) -> [Area] {
        let live = knowledge.tables.filter { $0.state != .dropped }.map(\.name)
        let liveSet = Set(live)
        var areas: [Area] = knowledge.areas.map { (area: SubjectArea) -> Area in
            Area(name: area.name, source: "curated", tables: area.tables.filter { liveSet.contains($0) }.sorted(), description: area.description)
        }
        areas += connected(live: liveSet, knowledge: knowledge, confidence: confidence)
        areas += prefixClusters(live)
        return areas
    }

    /// Union-find over relationships of at least 50% between tables of this database (no shared keys, no lineage).
    static func connected(live: Set<String>, knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int) -> [Area] {
        var parent: [String: String] = [:]
        func root(_ node: String) -> String {
            var node = node
            while let next = parent[node], next != node { node = next }
            return node
        }
        var degree: [String: Int] = [:]
        for relationship in knowledge.relationships {
            guard relationship.kind != .lineage, relationship.kind != .sharedKey, !KnowledgeRules.isRejected(relationship) else { continue }
            guard relationship.from.database == nil, relationship.to.database == nil else { continue }
            let left = relationship.from.table
            let right = relationship.to.table
            guard left != right, live.contains(left), live.contains(right), confidence(relationship) >= 50 else { continue }
            parent[left] = parent[left] ?? left
            parent[right] = parent[right] ?? right
            let leftRoot = root(left)
            let rightRoot = root(right)
            if leftRoot != rightRoot { parent[max(leftRoot, rightRoot)] = min(leftRoot, rightRoot) }
            degree[left, default: 0] += 1
            degree[right, default: 0] += 1
        }
        let groups = Dictionary(grouping: parent.keys, by: root).values.filter { $0.count >= 2 }
        let areas: [Area] = groups.map { (members: [String]) -> Area in
            let hub = members.max { (left: String, right: String) -> Bool in
                let leftDegree = degree[left] ?? 0
                let rightDegree = degree[right] ?? 0
                return leftDegree != rightDegree ? leftDegree < rightDegree : left > right
            } ?? members[0]
            return Area(name: "\(hub) (+\(members.count - 1))", source: "connected", tables: members.sorted(), description: nil)
        }
        return areas.sorted { $0.tables.count != $1.tables.count ? $0.tables.count > $1.tables.count : $0.name < $1.name }
    }

    /// Tables sharing their first name token (3 or more); groups over 25 split by their first two tokens.
    static func prefixClusters(_ tables: [String]) -> [Area] {
        func prefix(_ name: String, _ count: Int) -> String? {
            let parts = name.split(separator: "_")
            guard parts.count > count else { return nil }
            return parts.prefix(count).joined(separator: "_")
        }
        var areas: [Area] = []
        for (first, members) in Dictionary(grouping: tables, by: { prefix($0, 1) ?? "" }) where !first.isEmpty && members.count >= 3 {
            if members.count <= 25 {
                areas.append(Area(name: first + "_*", source: "prefix", tables: members.sorted(), description: nil))
                continue
            }
            for (second, subgroup) in Dictionary(grouping: members, by: { prefix($0, 2) ?? first }) where subgroup.count >= 3 {
                areas.append(Area(name: second + "_*", source: "prefix", tables: subgroup.sorted(), description: nil))
            }
        }
        return areas.sorted { $0.name < $1.name }
    }
}

/// Mermaid `erDiagram` text for a set of tables. Names are turned into safe identifiers (originals in `%%` comments),
/// labels carry only join columns and confidence, and nothing a database comment or name contains can become a Mermaid
/// directive, link or style.
public enum MermaidERDRenderer {
    public enum Columns: String, Codable, Sendable, CaseIterable {
        /// Keys and the columns relationships use.
        case keys
        /// Only the columns relationships use.
        case related
        case all
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge(count: Int, limit: Int)

        public var errorDescription: String? {
            switch self {
            case let .tooLarge(count, limit):
                "\(count) tables do not make a readable diagram (limit \(limit)); pick a subject area, a prefix or the tables around one table."
            }
        }
    }

    public struct Diagram: Codable, Sendable, Equatable {
        public var title: String
        public var tables: [String]
        /// Requested tables that are unknown or dropped.
        public var omitted: [String]
        public var mermaid: String
        public var legend: String
    }

    public static let hardLimit = 60

    public static func render(tables requested: [String], in knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int,
                              columns: Columns = .keys, minConfidence: Int = 40, title: String, maxTables: Int = 25) throws -> Diagram {
        let limit = min(max(maxTables, 1), hardLimit)
        var seen: Set<String> = []
        let unique = requested.filter { seen.insert($0).inserted }
        guard unique.count <= limit else { throw Failure.tooLarge(count: unique.count, limit: limit) }
        let present = unique.filter { knowledge.table(named: $0).map { $0.state != .dropped } ?? false }
        let presentSet = Set(present)
        let omitted = unique.filter { !presentSet.contains($0) }

        var identifiers: [String: String] = [:]
        var used: Set<String> = []
        for name in present {
            var identifier = Self.identifier(name)
            var suffix = 2
            while used.contains(identifier) {
                identifier = Self.identifier(name) + "_" + String(suffix)
                suffix += 1
            }
            used.insert(identifier)
            identifiers[name] = identifier
        }

        let drawn = knowledge.relationships.filter { (relationship: Relationship) -> Bool in
            guard relationship.from.database == nil, relationship.to.database == nil else { return false }
            guard presentSet.contains(relationship.from.table), presentSet.contains(relationship.to.table), relationship.from.table != relationship.to.table else { return false }
            guard !KnowledgeRules.isRejected(relationship), !KnowledgeFreshness.isBroken(relationship, in: knowledge) else { return false }
            return relationship.kind == .lineage || confidence(relationship) >= minConfidence
        }
        var foreignColumns: [String: Set<String>] = [:]
        for relationship in drawn where relationship.kind != .lineage {
            foreignColumns[relationship.from.table, default: []].formUnion(relationship.from.columns.map { $0.lowercased() })
            foreignColumns[relationship.to.table, default: []].formUnion(relationship.to.columns.map { $0.lowercased() })
        }

        var lines: [String] = ["erDiagram"]
        for name in present {
            guard let table = knowledge.table(named: name), let identifier = identifiers[name] else { continue }
            if identifier != name { lines.append("  %% \(identifier) = \(commentSafe(name))") }
            let primary = Set(table.keys.primary.map { $0.lowercased() })
            let related = foreignColumns[name] ?? []
            let shown = table.columns.filter { (column: ColumnFacts) -> Bool in
                let lowered = column.name.lowercased()
                switch columns {
                case .all: return true
                case .related: return related.contains(lowered)
                case .keys: return column.isKey || primary.contains(lowered) || related.contains(lowered)
                }
            }
            lines.append("  \(identifier) {")
            for column in shown {
                let lowered = column.name.lowercased()
                var markers: [String] = []
                if primary.contains(lowered) { markers.append("PK") }
                if related.contains(lowered), !primary.contains(lowered) { markers.append("FK") }
                let marker = markers.isEmpty ? "" : " " + markers.joined(separator: ", ")
                lines.append("    \(Self.identifier(column.type)) \(Self.identifier(column.name))\(marker)")
            }
            lines.append("  }")
        }
        for relationship in drawn.sorted(by: { $0.id < $1.id }) {
            guard let left = identifiers[relationship.from.table], let right = identifiers[relationship.to.table] else { continue }
            lines.append("  \(left) \(connector(relationship, knowledge: knowledge, confidence: confidence)) \(right) : \"\(label(relationship, knowledge: knowledge, confidence: confidence))\"")
        }
        let legend = "Solid: confirmed, declared or at least 70% confidence. Dashed: inferred below 70%, stale, or lineage (a view reading a table). Labels: join columns and confidence."
        return Diagram(title: title, tables: present, omitted: omitted, mermaid: lines.joined(separator: "\n"), legend: legend)
    }

    static func connector(_ relationship: Relationship, knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int) -> String {
        let declared = relationship.evidence.contains { $0.source == .declared || $0.source == .user }
        let solid = relationship.kind != .lineage && !KnowledgeFreshness.isStale(relationship, in: knowledge)
            && (relationship.status == .confirmed || declared || confidence(relationship) >= 70)
        let line = solid ? "--" : ".."
        switch relationship.kind {
        case .manyToOne:
            let target = knowledge.table(named: relationship.to.table)
            let primary = Set((target?.keys.primary ?? []).map { $0.lowercased() })
            let keyed = !relationship.to.columns.isEmpty && relationship.to.columns.allSatisfy { (column: String) -> Bool in
                primary.contains(column.lowercased()) || (target?.column(named: column)?.isKey ?? false)
            }
            return keyed ? "}o\(line)||" : "}o\(line)o{"
        case .oneToOne: return "||\(line)||"
        case .manyToMany, .sharedKey: return "}o\(line)o{"
        case .lineage: return "}o..||"
        }
    }

    static func label(_ relationship: Relationship, knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int) -> String {
        guard relationship.kind != .lineage else { return "reads" }
        let columns = relationship.from.columns.map(identifier).joined(separator: ",")
        let stale = KnowledgeFreshness.isStale(relationship, in: knowledge) ? " stale" : ""
        return "\(columns) \(confidence(relationship))%\(stale)"
    }

    /// `[A-Za-z0-9_]` only, never starting with a digit, with Mermaid keywords that could start a directive or a link
    /// (click, style, classDef, linkStyle, call, href, init) taken out.
    static func identifier(_ text: String) -> String {
        var result = String(text.unicodeScalars.map { (scalar: Unicode.Scalar) -> Character in
            let value = scalar.value
            let isAlphanumeric = (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
            return isAlphanumeric ? Character(scalar) : "_"
        })
        for keyword in ["click", "style", "classdef", "linkstyle", "call", "href", "init"] {
            result = result.replacingOccurrences(of: keyword, with: "_", options: .caseInsensitive)
        }
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { return "t" }
        if let first = result.unicodeScalars.first, (0x30...0x39).contains(first.value) { result = "t_" + result }
        return result
    }

    static func commentSafe(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { (scalar: Unicode.Scalar) -> Bool in
            scalar.value >= 0x20 && !"%{}\"".unicodeScalars.contains(scalar)
        }
        return String(String.UnicodeScalarView(cleaned).prefix(80))
    }
}
