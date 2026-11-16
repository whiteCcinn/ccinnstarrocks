import Foundation

/// Compares setting values the way an operator reads them (design D7): trimmed, booleans case-insensitive,
/// decimal numbers by value (`1` = `1.0` = `1e0`). Anything else compares exactly.
public enum ConfigValue {
    public static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        key(lhs) == key(rhs)
    }

    /// Canonical form used for equality and for grouping node values. Lists compare without the spaces after
    /// commas (`a, b` = `a,b`).
    static func key(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(",") {
            value = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
        }
        let lowered = value.lowercased()
        if lowered == "true" || lowered == "false" { return lowered }
        if value.wholeMatch(of: decimalPattern) != nil, var number = Double(value), number.isFinite {
            if number == 0 { number = 0 } // -0 == 0
            return "#\(number)"
        }
        return value
    }

    /// Plain decimal notation only: `Double.init` would also accept hex floats, `inf` and `nan`.
    nonisolated(unsafe) private static let decimalPattern = /[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/

    static func isNumber(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).wholeMatch(of: decimalPattern) != nil
    }

    /// Defaults such as `${STARROCKS_HOME}/storage` are templates, not values.
    static func isPlaceholder(_ raw: String) -> Bool {
        raw.contains("${")
    }

    /// A bare number or boolean that can be written without quotes in `SET`.
    static func isScalarLiteral(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        return value.wholeMatch(of: decimalPattern) != nil || ["true", "false"].contains(value.lowercased())
    }
}

/// One setting of the cluster: a variable, a frontend configuration item or a backend configuration item.
public struct ConfigItem: Sendable, Hashable, Identifiable {
    public enum Scope: String, Sendable, CaseIterable, Identifiable {
        case variables, frontend, backend

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .variables: "Variables"
            case .frontend: "FE Config"
            case .backend: "BE Config"
            }
        }
    }

    /// The value of a backend item on one node.
    public struct NodeValue: Sendable, Hashable {
        public var nodeID: String
        public var host: String?
        public var value: String

        public init(nodeID: String, host: String?, value: String) {
            self.nodeID = nodeID
            self.host = host
            self.value = value
        }
    }

    public var scope: Scope
    public var name: String
    /// Global value (variables), the connected FE's value, or the most common value across backends.
    public var value: String?
    public var defaultValue: String?
    public var type: String?
    /// `nil` when the server does not say (variables).
    public var isMutable: Bool?
    public var aliases: [String]
    public var comment: String?
    /// Per-node values of a backend item (one entry per reported row).
    public var nodes: [NodeValue]
    /// The server's own "changed" flag (`verbose_session_variables.IS_CHANGED`), used when the value and the
    /// default are encoded differently (`sql_mode`: `ONLY_FULL_GROUP_BY` vs bitmask `32`).
    public var reportedChanged: Bool?

    public var id: String { name }

    public init(scope: Scope, name: String, value: String? = nil, defaultValue: String? = nil, type: String? = nil, isMutable: Bool? = nil,
                aliases: [String] = [], comment: String? = nil, nodes: [NodeValue] = [], reportedChanged: Bool? = nil) {
        self.scope = scope
        self.name = name
        self.value = value
        self.defaultValue = defaultValue
        self.type = type
        self.isMutable = isMutable
        self.aliases = aliases
        self.comment = comment
        self.nodes = nodes
        self.reportedChanged = reportedChanged
    }

    /// Differs from the default; `nil` when the default is unknown (FE configuration, `SHOW` fallbacks, `${…}`
    /// templates) or cannot be compared and the server gives no flag.
    public var isModified: Bool? {
        guard let value, let defaultValue, !ConfigValue.isPlaceholder(defaultValue) else { return nil }
        guard ConfigValue.isNumber(value) == ConfigValue.isNumber(defaultValue) else { return reportedChanged }
        return !ConfigValue.equivalent(value, defaultValue)
    }

    /// Backends or compute nodes disagree on the value.
    public var differsAcrossNodes: Bool {
        Set(nodes.map { ConfigValue.key($0.value) }).count > 1
    }

    /// Case-insensitive search over name, aliases, value and comment; a blank keyword matches everything.
    public func matches(_ keyword: String) -> Bool {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return true }
        return ([name, value, comment] + aliases.map(Optional.some)).contains { $0?.range(of: keyword, options: .caseInsensitive) != nil }
    }

    // MARK: Builders

    /// Variables from `information_schema.global_variables` (or `SHOW GLOBAL VARIABLES`) for the value and
    /// `verbose_session_variables` for the default. The verbose view describes the app's pooled session, so its
    /// value is used only for variables that have no global value.
    public static func variables(global: [Record], verbose: [Record]) -> [ConfigItem] {
        var items: [String: ConfigItem] = [:]
        for record in verbose {
            guard let name = record.text("VARIABLE_NAME", "Variable_name") else { continue }
            items[name.lowercased()] = ConfigItem(scope: .variables, name: name, value: record.raw("VARIABLE_VALUE", "Value"),
                                                  defaultValue: record.raw("DEFAULT_VALUE", "Default_value"),
                                                  reportedChanged: record.bool("IS_CHANGED"))
        }
        for record in global {
            guard let name = record.text("VARIABLE_NAME", "Variable_name") else { continue }
            let value = record.raw("VARIABLE_VALUE", "Value")
            items[name.lowercased(), default: ConfigItem(scope: .variables, name: name)].value = value
        }
        return sorted(Array(items.values))
    }

    /// `ADMIN SHOW FRONTEND CONFIG`: `Key, AliasNames, Value, Type, IsMutable, Comment`.
    public static func frontend(_ records: [Record]) -> [ConfigItem] {
        sorted(records.compactMap { record in
            guard let name = record.text("Key", "Name") else { return nil }
            return ConfigItem(scope: .frontend, name: name, value: record.raw("Value"), type: record.text("Type"),
                              isMutable: record.bool("IsMutable"), aliases: parseAliases(record.text("AliasNames")),
                              comment: record.text("Comment"))
        })
    }

    /// `information_schema.be_configs` rows (`BE_ID, NAME, VALUE, TYPE, DEFAULT, MUTABLE`) grouped by name.
    /// The shown value is the most common one; a tie goes to the default, then to the lowest node.
    public static func backend(_ records: [Record], hosts: [String: String]) -> [ConfigItem] {
        var order: [String] = []
        var groups: [String: [Record]] = [:]
        for record in records {
            guard let name = record.text("NAME") else { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(record)
        }
        let items = order.compactMap { name -> ConfigItem? in
            guard let rows = groups[name], let first = rows.first else { return nil }
            let nodes = rows.map { row in
                let id = row.text("BE_ID") ?? "?"
                return NodeValue(nodeID: id, host: hosts[id], value: row.raw("VALUE") ?? "")
            }.sorted { nodeOrder($0.nodeID, $1.nodeID) }
            let defaultValue = first.raw("DEFAULT")
            return ConfigItem(scope: .backend, name: name, value: representative(of: nodes, defaultValue: defaultValue),
                              defaultValue: defaultValue, type: first.text("TYPE"), isMutable: first.bool("MUTABLE"), nodes: nodes)
        }
        return sorted(items)
    }

    private static func representative(of nodes: [NodeValue], defaultValue: String?) -> String? {
        guard !nodes.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for node in nodes { counts[ConfigValue.key(node.value), default: 0] += 1 }
        let defaultKey = defaultValue.map(ConfigValue.key)
        var best: NodeValue?
        var bestCount = 0
        for node in nodes {
            let key = ConfigValue.key(node.value)
            let count = counts[key] ?? 0
            if count > bestCount || (count == bestCount && key == defaultKey && best.map({ ConfigValue.key($0.value) }) != defaultKey) {
                best = node
                bestCount = count
            }
        }
        return best?.value
    }

    /// `[a, b]` → `["a", "b"]`.
    static func parseAliases(_ raw: String?) -> [String] {
        guard var text = raw?.trimmingCharacters(in: .whitespaces) else { return [] }
        if text.hasPrefix("[") { text.removeFirst() }
        if text.hasSuffix("]") { text.removeLast() }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Numeric ids in numeric order, others after them in text order.
    private static func nodeOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch (Int64(lhs), Int64(rhs)) {
        case let (left?, right?): left < right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs < rhs
        }
    }

    private static func sorted(_ items: [ConfigItem]) -> [ConfigItem] {
        items.sorted { $0.name.lowercased() != $1.name.lowercased() ? $0.name.lowercased() < $1.name.lowercased() : $0.name < $1.name }
    }
}

/// Statements that change a setting, for the user to review and run in a SQL editor (design D8).
public enum ConfigStatement {
    public static func edit(for item: ConfigItem) -> String? {
        guard item.name.wholeMatch(of: namePattern) != nil else { return nil }
        let value = item.value ?? ""
        switch item.scope {
        case .variables:
            guard item.isMutable != false else { return nil }
            let literal = ConfigValue.isScalarLiteral(value) ? value.trimmingCharacters(in: .whitespaces) : SQLText.literal(value)
            return "-- Changes the default for new sessions. Use SET without GLOBAL to change only this editor's session.\n"
                + "SET GLOBAL \(item.name) = \(literal);"
        case .frontend:
            guard item.isMutable == true else { return nil }
            return "-- Applies to the connected frontend only and is not written to fe.conf.\n"
                + "ADMIN SET FRONTEND CONFIG (\(SQLText.literal(item.name)) = \(SQLText.literal(value)));"
        case .backend:
            guard item.isMutable == true else { return nil }
            return "-- Applies to every backend and compute node and is not written to be.conf.\n"
                + "UPDATE information_schema.be_configs SET VALUE = \(SQLText.literal(value)) WHERE NAME = \(SQLText.literal(item.name));"
        }
    }

    nonisolated(unsafe) private static let namePattern = /[A-Za-z_][A-Za-z0-9_.]*/
}
