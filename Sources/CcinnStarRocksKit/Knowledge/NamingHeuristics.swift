import Foundation

/// Relationships guessed from names (design §2.5): `report_adx_hour.dsp_id` → `dsp.id`. Pure and deterministic.
///
/// 1. A table's entity is its lower-cased name without one warehouse prefix (`dim_`, `ods_`, …) and without trailing
///    grain or bookkeeping words (`_hour`, `_info`, `_v2`, …); variants are the remainder, its last word and simple
///    singulars.
/// 2. A column ending in `_id`, `Id`, `_key`, `_code` or `_no` names an entity: the longest stem first
///    (`publisher_app_id` → `publisher_app`), then shorter ones (`app`). The first stem with a candidate wins.
/// 3. Candidates: exact table name 55, entity 50, last word of the entity 40; then `id` +15, same column name +10, a
///    key +10, same type family +5, the column comment names the table +5, a view −5, equal best candidates −10 each
///    (flagged `ambiguous`). Scores stay within 30–70; incompatible types reject a candidate.
/// 4. No edge from `id`, none to the column's own table except from `parent_*`, none without a target table. A key
///    that no table owns links the tables that carry it as a `sharedKey` at 30.
public enum NamingHeuristics {
    /// A key carried by more tables than this, with no table owning it, is too generic to link them all pairwise.
    public static let maxSharedKeyTables = 10

    static let tablePrefixes: Set<String> = [
        "dim", "dwd", "dws", "ods", "ads", "dm", "t", "tb", "tbl", "d", "f", "fact", "ref", "cfg", "conf", "config", "meta",
    ]
    static let tableSuffixes: Set<String> = [
        "info", "dim", "dict", "tab", "table", "list", "base", "all", "latest", "bak", "tmp", "hour", "hourly", "day",
        "daily", "week", "month", "min", "5min", "rt", "realtime", "utc", "snapshot", "hist", "history",
    ]
    static let keySuffixes = ["_id", "_key", "_code", "_no"]

    /// Inferred relationships from names, with `naming` evidence (score) and kind `manyToOne` or `sharedKey`, sorted by
    /// id. `tables` is this database; `otherDatabases` maps database names (same cluster, linked to the same project) to
    /// their tables, for cross-database targets (`End.database` set). Dropped tables take no part.
    public static func relationships(tables: [TableFacts], otherDatabases: [String: [TableFacts]] = [:], now: Date) -> [Relationship] {
        let home = tables.filter { $0.state != .dropped }.sorted { $0.name < $1.name }
        var candidates = home.map { Candidate(database: nil, table: $0) }
        for database in otherDatabases.keys.sorted() {
            let others = (otherDatabases[database] ?? []).filter { $0.state != .dropped }.sorted { $0.name < $1.name }
            candidates += others.map { Candidate(database: database, table: $0) }
        }
        let index = CandidateIndex(candidates)

        var byID: [String: Relationship] = [:]
        var ownedKeys: Set<String> = []
        for source in home {
            for column in source.columns {
                let found = targets(of: column, in: source, index: index)
                guard !found.isEmpty else { continue }
                ownedKeys.insert(column.name.lowercased())
                for relationship in edges(from: column, in: source, to: found, now: now) where byID[relationship.id] == nil {
                    byID[relationship.id] = relationship
                }
            }
        }
        for relationship in sharedKeys(home, excluding: ownedKeys, now: now) where byID[relationship.id] == nil {
            byID[relationship.id] = relationship
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// The entity variants of a table name (prefix and suffix words dropped, singulars), exposed for tests and search.
    public static func entityNames(of table: String) -> [String] {
        let entity = Entity(table)
        return entity.fullForms + entity.lastForms
    }

    // MARK: Entities and stems

    /// What a table is about: `dim_publisher_apps_daily` → `publisher_apps` (and `publisher_app`), last word `apps`
    /// (and `app`).
    struct Entity {
        /// The remainder and its singulars.
        let fullForms: [String]
        /// Its last word and singulars, when the remainder has several words.
        let lastForms: [String]

        init(_ table: String) {
            var words = NamingHeuristics.snakeCase(table).split(separator: "_").map(String.init)
            if words.count > 1, let first = words.first, NamingHeuristics.tablePrefixes.contains(first) { words.removeFirst() }
            while words.count > 1, let last = words.last, NamingHeuristics.isTableSuffix(last) { words.removeLast() }
            guard let last = words.last else {
                fullForms = []
                lastForms = []
                return
            }
            let full = NamingHeuristics.withSingulars(words.joined(separator: "_"))
            fullForms = full
            lastForms = words.count > 1 ? NamingHeuristics.withSingulars(last).filter { !full.contains($0) } : []
        }
    }

    static func isTableSuffix(_ word: String) -> Bool {
        if tableSuffixes.contains(word) { return true }
        // utce8, utce0…, v2, v10
        if word.hasPrefix("utce") { return word.dropFirst(4).allSatisfy(\.isASCIIDigit) }
        if word.hasPrefix("v"), word.count > 1 { return word.dropFirst().allSatisfy(\.isASCIIDigit) }
        return false
    }

    /// The word and its simple singulars: `categories` → `category`, `movie`; `boxes` → `box`; `apps` → `app`. Words
    /// ending in `ss`, `us` or `is` (`class`, `status`, `analysis`) are left alone.
    static func withSingulars(_ word: String) -> [String] {
        var forms = [word]
        if word.count > 3, word.hasSuffix("ies") {
            forms.append(String(word.dropLast(3)) + "y")
            forms.append(String(word.dropLast()))
        } else if word.count > 3, word.hasSuffix("es"), ["ses", "xes", "zes", "ches", "shes"].contains(where: { word.hasSuffix($0) }) {
            forms.append(String(word.dropLast(2)))
        } else if word.count > 1, word.hasSuffix("s"), !["ss", "us", "is"].contains(where: { word.hasSuffix($0) }) {
            forms.append(String(word.dropLast()))
        }
        return forms
    }

    /// Lower-cased with `_` between camel-case words: `publisherAppID` → `publisher_app_id`.
    static func snakeCase(_ name: String) -> String {
        var result = ""
        var previousIsLowerOrDigit = false
        for character in name {
            if character.isUppercase, previousIsLowerOrDigit { result.append("_") }
            result += character.lowercased()
            previousIsLowerOrDigit = character.isLowercase || character.isNumber
        }
        return result
    }

    /// The entity names a key column may refer to, longest first, and the key word it ends with: `publisher_app_id` →
    /// (["publisher_app", "app"], "id"). `nil` for other columns (`id`, `name`, `dsp_request`).
    static func stems(of column: String) -> (stems: [String], keyWord: String)? {
        let name = snakeCase(column)
        guard let suffix = keySuffixes.first(where: { name.hasSuffix($0) }) else { return nil }
        let words = name.dropLast(suffix.count).split(separator: "_").map(String.init)
        guard !words.isEmpty else { return nil }
        let stems = words.indices.map { (start: Int) -> String in words[start...].joined(separator: "_") }
        return (stems, String(suffix.dropFirst()))
    }

    // MARK: Candidates

    private struct Candidate {
        /// `nil` for this database.
        let database: String?
        let table: TableFacts

        var fingerprintKey: String { database.map { $0 + "." + table.name } ?? table.name }
    }

    private enum Match: Int, Comparable {
        case lastWord = 40, entity = 50, exactName = 55

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Entity name → candidate tables, each with its best kind of match.
    private struct CandidateIndex {
        let candidates: [Candidate]
        private var matches: [String: [Int: Match]] = [:]

        init(_ candidates: [Candidate]) {
            self.candidates = candidates
            for (offset, candidate) in candidates.enumerated() {
                let entity = Entity(candidate.table.name)
                add(NamingHeuristics.snakeCase(candidate.table.name), offset, .exactName)
                for form in entity.fullForms { add(form, offset, .entity) }
                for form in entity.lastForms { add(form, offset, .lastWord) }
            }
        }

        private mutating func add(_ name: String, _ offset: Int, _ match: Match) {
            guard !name.isEmpty else { return }
            let current = matches[name]?[offset]
            if current == nil || current.map({ $0 < match }) == true { matches[name, default: [:]][offset] = match }
        }

        /// Candidates for one stem, in candidate order.
        func lookup(_ stem: String) -> [(candidate: Candidate, match: Match)] {
            guard let found = matches[stem] else { return [] }
            return found.keys.sorted().map { (offset: Int) -> (candidate: Candidate, match: Match) in
                (candidates[offset], found[offset] ?? .lastWord)
            }
        }
    }

    /// One possible target of a key column.
    private struct Target {
        let candidate: Candidate
        let column: ColumnFacts
        /// Match and bonuses, uncapped.
        let positive: Int
        /// The view/MV penalty.
        let penalty: Int

        var rank: Int { positive - penalty }
    }

    /// The best targets of a key column: those of the first stem that has any, then the equal best of them.
    private static func targets(of column: ColumnFacts, in source: TableFacts, index: CandidateIndex) -> [Target] {
        guard let (columnStems, keyWord) = stems(of: column.name) else { return [] }
        let allowsSelf = snakeCase(column.name).hasPrefix("parent_")
        var found: [Target] = []
        for stem in columnStems {
            found = index.lookup(stem).compactMap { (entry: (candidate: Candidate, match: Match)) -> Target? in
                target(column, in: source, keyWord: keyWord, candidate: entry.candidate, match: entry.match, allowsSelf: allowsSelf)
            }
            if !found.isEmpty { break }
        }
        if found.isEmpty, allowsSelf {
            // `parent_id` with no `parent` table: the row's own table.
            let ownTable = Candidate(database: nil, table: source)
            found = [target(column, in: source, keyWord: keyWord, candidate: ownTable, match: .entity, allowsSelf: true)].compactMap { $0 }
        }
        guard let best = found.map(\.rank).max() else { return [] }
        return found.filter { $0.rank == best }
    }

    /// The best column of one candidate table for a key column, or nil when the candidate does not qualify.
    private static func target(_ column: ColumnFacts, in source: TableFacts, keyWord: String, candidate: Candidate, match: Match,
                               allowsSelf: Bool) -> Target? {
        let isOwnTable = candidate.database == nil && candidate.table.name == source.name
        if isOwnTable, !allowsSelf { return nil }
        let table = candidate.table
        let sourceName = column.name.lowercased()
        let uniqueColumn = soleKey(of: table)
        let primary = Set(table.keys.primary.map { $0.lowercased() })
        let entity = Entity(table.name)
        let entityWords = entity.fullForms + entity.lastForms + [table.name.lowercased()]
        let comment = (column.comment ?? "").lowercased()
        let commentNamesTable = entityWords.contains { $0.count >= 3 && comment.contains($0) }
        let sourceFamily = ColumnTypeFamily(column.type)
        let isView = table.kind == .view || table.kind == .materializedView

        var best: Target?
        for targetColumn in table.columns {
            let name = targetColumn.name.lowercased()
            if isOwnTable, name == sourceName { continue }
            let isID = name == "id"
            let isSameName = name == sourceName
            let isKeyWord = name == keyWord
            let isSoleKey = name == uniqueColumn
            guard isID || isSameName || isKeyWord || isSoleKey else { continue }
            // A last-word match (`report_app_hour` for `app`) must offer an owning key, not just the same column.
            if match == .lastWord, !isID, !isSoleKey { continue }
            let targetFamily = ColumnTypeFamily(targetColumn.type)
            guard sourceFamily.isCompatible(with: targetFamily) else { continue }

            var positive = match.rawValue
            if isID { positive += 15 }
            if isSameName { positive += 10 }
            if targetColumn.isKey || primary.contains(name) { positive += 10 }
            if sourceFamily == targetFamily, sourceFamily.isKeyLike { positive += 5 }
            if commentNamesTable { positive += 5 }
            let scored = Target(candidate: candidate, column: targetColumn, positive: positive, penalty: isView ? 5 : 0)
            if best.map({ scored.rank > $0.rank }) ?? true { best = scored }
        }
        return best
    }

    /// The single column that identifies a row: a one-column primary key, or the only key column of a primary-key,
    /// unique-key or aggregate table.
    static func soleKey(of table: TableFacts) -> String? {
        if table.keys.primary.count == 1, let primary = table.keys.primary.first { return primary.lowercased() }
        guard let model = table.model?.uppercased(), ["PK", "UNI", "AGG", "PRIMARY", "UNIQUE", "AGGREGATE"].contains(model) else { return nil }
        let keys = table.columns.filter(\.isKey)
        guard keys.count == 1, let key = keys.first else { return nil }
        return key.name.lowercased()
    }

    private static func edges(from column: ColumnFacts, in source: TableFacts, to targets: [Target], now: Date) -> [Relationship] {
        let isAmbiguous = targets.count > 1
        return targets.map { (target: Target) -> Relationship in
            let capped: Int = min(RelationshipConfidence.namingCap, target.positive)
            let penalties: Int = target.penalty + (isAmbiguous ? 10 : 0)
            let score: Int = max(30, min(RelationshipConfidence.namingCap, capped - penalties))
            let evidence = Evidence(source: .naming, score: score, rationale: isAmbiguous ? "ambiguous" : nil, at: now)
            return Relationship(from: .init(table: source.name, columns: [column.name]),
                                to: .init(database: target.candidate.database, table: target.candidate.table.name, columns: [target.column.name]),
                                kind: .manyToOne, evidence: [evidence],
                                fingerprints: fingerprints((source.name, source.fingerprint),
                                                           (target.candidate.fingerprintKey, target.candidate.table.fingerprint)))
        }
    }

    /// Both tables' fingerprints; a self-reference has one (a dictionary literal with the key twice would trap).
    private static func fingerprints(_ first: (key: String, value: String), _ second: (key: String, value: String)) -> [String: String] {
        var fingerprints = [first.key: first.value]
        fingerprints[second.key] = fingerprints[second.key] ?? second.value
        return fingerprints
    }

    /// Key columns no table owns, carried by 2…`maxSharedKeyTables` tables of this database: one `sharedKey` per pair of
    /// tables whose types agree, ends ordered by table name. Views and materialized views only re-expose their base
    /// tables' columns (lineage), so they carry no shared keys.
    private static func sharedKeys(_ tables: [TableFacts], excluding owned: Set<String>, now: Date) -> [Relationship] {
        var carriers: [String: [(table: TableFacts, column: ColumnFacts)]] = [:]
        for table in tables where table.kind != .view && table.kind != .materializedView {
            for column in table.columns where stems(of: column.name) != nil {
                let key = column.name.lowercased()
                guard !owned.contains(key), carriers[key]?.contains(where: { $0.table.name == table.name }) != true else { continue }
                carriers[key, default: []].append((table, column))
            }
        }
        var result: [Relationship] = []
        for key in carriers.keys.sorted() {
            guard let group = carriers[key], group.count >= 2, group.count <= maxSharedKeyTables else { continue }
            for (offset, first) in group.enumerated() {
                for second in group[(offset + 1)...] {
                    let firstFamily = ColumnTypeFamily(first.column.type)
                    guard firstFamily.isCompatible(with: ColumnTypeFamily(second.column.type)) else { continue }
                    let evidence = Evidence(source: .naming, score: RelationshipConfidence.sharedKeyCap, at: now)
                    result.append(Relationship(from: .init(table: first.table.name, columns: [first.column.name]),
                                               to: .init(table: second.table.name, columns: [second.column.name]),
                                               kind: .sharedKey, evidence: [evidence],
                                               fingerprints: fingerprints((first.table.name, first.table.fingerprint),
                                                                          (second.table.name, second.table.fingerprint))))
                }
            }
        }
        return result
    }
}

/// The family of a column type, enough to tell whether two columns can hold the same key.
enum ColumnTypeFamily: Equatable {
    case integer, string, decimal, floating, temporal, boolean, binary, complex, unknown

    init(_ type: String) {
        let base = String(type.lowercased().trimmingCharacters(in: .whitespaces).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        switch base {
        case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "largeint": self = .integer
        case "char", "varchar", "string", "text", "tinytext", "mediumtext", "longtext": self = .string
        case _ where base.hasPrefix("decimal") || base == "numeric": self = .decimal
        case "float", "double", "real": self = .floating
        case "date", "datetime", "timestamp", "time", "date_v2", "datetime_v2": self = .temporal
        case "boolean", "bool": self = .boolean
        case "binary", "varbinary", "blob": self = .binary
        case "array", "map", "struct", "json", "jsonb", "bitmap", "hll", "percentile", "variant": self = .complex
        default: self = .unknown
        }
    }

    /// Families that make keys; agreeing on one of them is a hint.
    var isKeyLike: Bool { self == .integer || self == .string }

    /// Unknown types never reject; integers and decimals (`decimal(20,0)` ids) may hold the same key.
    func isCompatible(with other: ColumnTypeFamily) -> Bool {
        if self == .unknown || other == .unknown || self == other { return true }
        let numeric: Set<ColumnTypeFamily> = [.integer, .decimal]
        return numeric.contains(self) && numeric.contains(other)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
