import Foundation

/// Decides whether SQL is a single read-only statement (used for MCP read-only access). The check
/// is token-based (strings, quoted identifiers and comments cannot smuggle keywords) and
/// conservative: anything not clearly a read is rejected.
public enum ReadOnlySQLGuard {
    /// Keywords that must not appear anywhere in a read-only statement.
    static let forbidden: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "DROP", "CREATE", "ALTER", "TRUNCATE", "GRANT", "REVOKE", "KILL", "SUBMIT",
        "OUTFILE", "OVERWRITE", "RENAME", "RECOVER", "INSTALL", "UNINSTALL", "CANCEL", "PAUSE", "RESUME", "STOP",
        "REFRESH", "ANALYZE", "BACKUP", "RESTORE", "LOAD", "EXPORT", "SWAP", "UPSERT", "MERGE",
    ]

    /// Text where supported servers disagree about statement boundaries. StarRocks 4.1 reads `$$ … $$` as one block
    /// while 3.3 reads `$$` as part of a name, so `SELECT 1 $$a; DROP … -- $$` is one statement on one version and two on
    /// the other. A block can only start where code is, so any `$$` outside strings, comments and back-quoted names (as
    /// 3.3 lexes the text) is refused; `LIKE '%$$%'` or `-- costs $$` are fine.
    public static func ambiguityRejection(_ sql: String) -> String? {
        let lexer = SQLLexer(sql) // `$$` blocks off: what StarRocks 3.3 reads
        let tokens = lexer.tokens()
        // `#`, `\`, control characters and characters above U+FFFF (emoji, invisible tag characters) are dropped by the
        // server: `SELECT 1 # ; DROP …` runs two statements. Readers (and lexers up to 1.3.0) take `#` for a comment.
        if lexer.containsDroppedCharacters(tokens) {
            return "Statements with #, \\, control characters or characters such as emoji outside quotes and comments are not allowed here: StarRocks ignores them (# is not a comment), so the statement may not be what it looks like."
        }
        let ambiguous = tokens.contains { token in
            token.kind != .string && token.kind != .comment && token.kind != .quotedIdentifier
                && SQLFormatter.containsDollarPair(lexer.units[token.range])
        }
        guard ambiguous else { return nil }
        return "Statements with $$ outside quotes and comments are not allowed here: StarRocks versions read $$ differently (a code block on 4.1, part of a name on 3.3), so where the statement ends cannot be known."
    }

    /// Why a statement may not be sent.
    public struct Rejection: Error, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// The exact text sent to the server, already guarded.
    public struct WireStatement: Sendable, Equatable {
        public let sql: String
        public let limitApplied: Bool
    }

    /// The one place that builds what `run_query` sends: one statement, an automatic LIMIT for queries without one, and
    /// the guard run on that exact final text (a rewrite can never smuggle in anything the guard did not see).
    public static func wireStatement(for sql: String, rowLimit: Int?, database: String?) throws -> WireStatement {
        let statement = try singleStatement(sql)
        if let reason = check(statement, database: database) { throw Rejection(message: reason) }
        var wire = WireStatement(sql: statement, limitApplied: false)
        if let rowLimit, SQLStatementKind.of(statement) == .query {
            let outcome = AutoLimit.apply(to: statement, limit: rowLimit)
            wire = WireStatement(sql: outcome.sql, limitApplied: outcome.applied)
        }
        if let reason = check(wire.sql, database: database) { throw Rejection(message: reason) }
        return wire
    }

    /// What `explain_query` sends: `EXPLAIN [COSTS]` and one query, guarded as sent.
    public static func explainStatement(for sql: String, costs: Bool, database: String?) throws -> WireStatement {
        let statement = try singleStatement(sql)
        let body = SQLStatementKind.of(statement) == .explain ? statement : (costs ? "EXPLAIN COSTS " : "EXPLAIN ") + statement
        if let reason = check(body, database: database) { throw Rejection(message: reason) }
        return WireStatement(sql: body, limitApplied: false)
    }

    static func singleStatement(_ sql: String) throws -> String {
        if let ambiguous = ambiguityRejection(sql) { throw Rejection(message: ambiguous) }
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first?.text else { throw Rejection(message: "The statement is empty.") }
        guard statements.count == 1 else { throw Rejection(message: "Only one statement can be run at a time; send statements separately.") }
        return statement
    }

    /// `nil` when allowed; otherwise the reason it is rejected. `database` is the session's database (unqualified names
    /// resolve there).
    public static func check(_ sql: String, database: String? = nil) -> String? {
        if let ambiguous = ambiguityRejection(sql) { return ambiguous }
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let lexer = SQLLexer(statement.text)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : lexer.text(of: $0) }
        guard let first = words.first else { return "The statement is empty." }
        if let secret = secretSourceRejection(tokens: tokens, words: words, lexer: lexer, database: database) { return secret }

        // Where the statement's own text starts: after EXPLAIN and its modifiers.
        var body = 0
        switch first {
        case "SELECT", "WITH", "(":
            if let reason = checkQuery(tokens: tokens, words: words, lexer: lexer) { return reason }
        case "SHOW":
            guard showIsAllowed(words) else {
                return "This SHOW statement is not available to AI: it may show other sessions' SQL, credentials or server configuration. Use the metadata tools, or SHOW DATABASES / TABLES / COLUMNS / CREATE TABLE / PARTITIONS / …"
            }
        case "DESC", "DESCRIBE":
            if words.count > 1 && words[1] == "STORAGE" { return "Storage volumes are not available to AI: they carry storage credentials." }
        case "ADMIN":
            guard words.count > 2 && words[1] == "SHOW" && words[2] == "REPLICA" else {
                return "Only ADMIN SHOW REPLICA DISTRIBUTION / STATUS is available to AI; configuration can carry secrets."
            }
        case "EXPLAIN":
            var index = 1
            let modifiers: Set<String> = ["LOGICAL", "VERBOSE", "COSTS", "SCHEDULER", "ANALYZE"]
            while index < words.count, modifiers.contains(words[index]) { index += 1 }
            guard index < words.count, ["SELECT", "WITH", "("].contains(words[index]) else {
                return "Only EXPLAIN of a SELECT query is allowed in read-only mode."
            }
            if let reason = checkQuery(tokens: Array(tokens[index...]), words: Array(words[index...]), lexer: lexer) { return reason }
            body = index
        default:
            return rejection(first)
        }
        return unreviewedCallRejection(tokens: Array(tokens[body...]), lexer: lexer)
    }

    // MARK: Reviewed functions

    /// The first call of a function AI may not use: anything but a reviewed built-in, and every qualified call (a
    /// user-defined function, which can do anything). Deny by default: functions a later version adds are refused until
    /// reviewed. `tokens` exclude comments.
    static func unreviewedCallRejection(tokens: [SQLToken], lexer: SQLLexer) -> String? {
        guard let call = SQLFunctionCalls.calls(in: tokens, lexer: lexer).first(where: { $0.isQualified || !ReviewedFunctions.names.contains($0.name) })
        else { return nil }
        return "`\(call.name)()` is not on CcinnStarRocks's list of reviewed functions for AI (functions that read files, other users' data or the network are excluded). Run it in the SQL editor if it is needed."
    }

    // MARK: Secret-bearing sources

    /// Schemas whose tables are readable by AI only when listed in `allowedSystemTables`: everything else in them may
    /// carry other sessions' SQL (task definitions, query history, running queries), credentials (load, pipe and
    /// routine-load properties, backend configuration) or server logs. Deny by default: tables added by later versions
    /// are refused until reviewed.
    static let allowedSystemTables: [String: Set<String>] = [
        "information_schema": [
            "tables", "columns", "schemata", "views", "partitions", "partitions_meta", "tables_config", "materialized_views", "statistics",
            "key_column_usage", "table_constraints", "referential_constraints", "character_sets", "collations",
            "collation_character_set_applicability", "engines", "keywords", "column_privileges", "schema_privileges", "table_privileges",
            "user_privileges", "applicable_roles", "be_tablets", "be_compactions", "be_cloud_native_compactions", "fe_tablet_schedules",
            "be_metrics", "fe_metrics", "be_bvars", "be_threads", "fe_threads", "be_datacache_metrics", "warehouse_metrics", "analyze_status",
            "column_stats_usage", "global_variables", "session_variables", "verbose_session_variables", "temp_tables", "events", "triggers",
            "routines", "be_txns",
        ],
        "sys": ["object_dependencies", "fe_memory_usage", "role_edges", "grants_to_roles", "grants_to_users"],
        "_statistics_": [
            "column_statistics", "external_column_statistics", "histogram_statistics", "external_histogram_statistics", "table_statistic_v1",
            "multi_column_statistics", "predicate_columns", "external_predicate_columns",
        ],
    ]

    /// Functions that reach outside the database or past the account's privileges from a plain SELECT, refused on every
    /// AI path (read-only queries call only `ReviewedFunctions` anyway). Probed on 3.3 and 4.1 for an account with
    /// SELECT on one table:
    /// - FILES() reads any path the backends can reach, their local file system included (`file:///etc/passwd`);
    /// - get_query_profile() returns other queries' profiles with their SQL;
    /// - ai_query() (4.1) makes the backend POST its prompt, query data included, to any endpoint and returns the
    ///   reply: exfiltration and requests from the backend's network position;
    /// - lookup_string() (3.3) and dict_mapping() (4.1) return rows of tables the account cannot read; dictionary_get()
    ///   reads a dictionary's rows, another table's data (denied on review);
    /// - get_query_dump() returns any table's DDL, partition row counts and column statistics, and
    ///   get_query_dump_from_query_id() another query's;
    /// - list_rowsets() lists a tablet's storage, host_name() a backend's host name (SHOW BACKENDS is refused there);
    /// - every `inspect_…` function (inspect_mv_meta, inspect_mv_plan, inspect_mv_refresh_info,
    ///   inspect_table_partition_info, …) shows server internals, materialized views the account cannot read included.
    static let deniedFunctions: Set<String> = [
        "files", "get_query_profile", "ai_query", "lookup_string", "dict_mapping", "dictionary_get", "get_query_dump",
        "get_query_dump_from_query_id", "list_rowsets", "host_name",
    ]

    /// `name` is lower-case.
    static func isDeniedFunction(_ name: String) -> Bool { deniedFunctions.contains(name) || name.hasPrefix("inspect_") }

    /// SHOW forms available to AI (after FULL / EXTENDED / TEMPORARY / GLOBAL / SESSION / BUILTIN).
    static let allowedShows: Set<String> = [
        "DATABASES", "SCHEMAS", "TABLES", "TABLE", "COLUMNS", "FIELDS", "INDEX", "INDEXES", "KEYS", "PARTITIONS", "TABLET", "TABLETS", "DATA",
        "CATALOGS", "VARIABLES", "CHARSET", "CHARACTER", "COLLATION", "ENGINES", "FUNCTIONS", "BACKENDS", "FRONTENDS", "COMPUTE", "WAREHOUSES",
        "DYNAMIC", "ALTER", "GRANTS", "ROLES", "MATERIALIZED", "CREATE", "ANALYZE", "STATS", "HISTOGRAM",
    ]

    static func showIsAllowed(_ words: [String]) -> Bool {
        var index = 1
        while index < words.count, ["FULL", "EXTENDED", "TEMPORARY", "GLOBAL", "SESSION", "BUILTIN"].contains(words[index]) { index += 1 }
        guard index < words.count, allowedShows.contains(words[index]) else { return false }
        let next = index + 1 < words.count ? words[index + 1] : ""
        switch words[index] {
        case "CREATE": return ["TABLE", "VIEW", "MATERIALIZED", "DATABASE", "SCHEMA"].contains(next)
        case "TABLE": return next == "STATUS"
        case "GRANTS": return !words.contains("FOR")
        default: return true
        }
    }

    static func isSystemSchema(_ name: String) -> Bool {
        allowedSystemTables[name] != nil || isAuditName(name)
    }

    /// The audit loader's default names (`starrocks_audit_db__.starrocks_audit_tbl__`): every statement of every user.
    static func isAuditName(_ name: String) -> Bool { name.contains("starrocks_audit") }

    /// A token as a name: identifiers and keywords lower-cased, back-quotes removed; `nil` for anything else. Double-quoted
    /// text counts as a name too: it is one in the trino dialect (`information_schema."tasks"`, `"files"(`). AI
    /// connections pin the StarRocks dialect, so this only matters if that ever fails; a literal is rarely in a name's place.
    static func name(_ token: SQLToken, _ lexer: SQLLexer) -> String? {
        switch token.kind {
        case .identifier, .keyword: return lexer.text(of: token).lowercased()
        case .quotedIdentifier: return lexer.identifierValue(of: token).lowercased()
        case .string:
            let text = lexer.text(of: token)
            guard text.hasPrefix("\"") else { return nil }
            var inner = Substring(text.dropFirst())
            if inner.hasSuffix("\"") { inner = inner.dropLast() }
            return inner.replacingOccurrences(of: "\"\"", with: "\"").lowercased()
        default: return nil
        }
    }

    /// A non-ASCII letter whose upper, lower or title case contains an ASCII letter (ı→I, ſ→S, İ→i̇, K→k, ﬁ→FI, ß→SS, …).
    /// StarRocks reads keywords upper-cased per character (`fıles(` is FILES( there) and compares system schema names
    /// with Java's equalsIgnoreCase (`ınformation_schema` is information_schema), so a name holding one cannot be
    /// compared with the deny lists the way the server reads it.
    static func caseMapsToASCII(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.isASCII, scalar.properties.changesWhenCaseMapped else { return false }
        let properties = scalar.properties
        return [properties.uppercaseMapping, properties.lowercaseMapping, properties.titlecaseMapping].contains { mapping in
            mapping.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
        }
    }

    /// The first case-confusable letter in a name, with the name.
    private static func caseConfusable(_ name: String) -> (name: String, letter: Unicode.Scalar)? {
        name.unicodeScalars.first(where: caseMapsToASCII).map { (name, $0) }
    }

    private static func caseConfusableMessage(_ found: (name: String, letter: Unicode.Scalar)) -> String {
        let code = "U+" + String(found.letter.value, radix: 16, uppercase: true)
        return "`\(found.name)` contains \(found.letter) (\(code)), which StarRocks may read as an ASCII letter (ı is I, ſ is S there), so the name cannot be checked as the server reads it. Write names in plain letters."
    }

    /// The parts of a session database as the server may read them: the handshake's `catalog.database` is split at the
    /// dot there, so every part is checked (back-quotes and surrounding white space removed, lower-cased).
    static func sessionDatabaseParts(_ database: String) -> [String] {
        database.replacingOccurrences(of: "`", with: "").split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    static func secretSourceRejection(tokens: [SQLToken], words: [String], lexer: SQLLexer, database: String?) -> String? {
        if let database {
            // The handshake cannot carry NUL and the server ignores control characters: the database sent could differ
            // from the one checked.
            if database.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return "The database name contains a control character, so it cannot be checked as the server would read it."
            }
            if let found = caseConfusable(database) { return caseConfusableMessage(found) }
        }
        for token in tokens where [.identifier, .keyword, .quotedIdentifier].contains(token.kind) {
            if let found = caseConfusable(lexer.text(of: token)) { return caseConfusableMessage(found) }
        }
        if let database, words.first != "SHOW", let system = sessionDatabaseParts(database).first(where: isSystemSchema) {
            return "Run system-table queries from a user database and qualify the table (for example information_schema.tables); \(system) is not available as the session database for AI."
        }
        for index in tokens.indices {
            guard let current = name(tokens[index], lexer) else { continue }
            if index + 1 < tokens.count, tokens[index + 1].kind == .punctuation, lexer.text(of: tokens[index + 1]) == "(",
               isDeniedFunction(current) {
                return "\(current.uppercased())() is not available to AI: it reaches outside the database or past the account's privileges (files on the servers, other queries' profiles and plans, other tables' rows, server internals, requests from the backends)."
            }
            if isAuditName(current) { return "The audit log is not available to AI: it holds every user's statements." }
            guard let allowed = allowedSystemTables[current], index + 2 < tokens.count, tokens[index + 1].kind == .punctuation,
                  lexer.text(of: tokens[index + 1]) == ".", let table = name(tokens[index + 2], lexer) else { continue }
            if !allowed.contains(table) {
                return "\(current).\(table) is not available to AI: it may hold other sessions' SQL, credentials or server logs. Use the tools get_running_tasks, get_materialized_view or describe_table, which redact them."
            }
        }
        return nil
    }

    private static func checkQuery(tokens: [SQLToken], words: [String], lexer: SQLLexer) -> String? {
        var depth = 0
        for (index, token) in tokens.enumerated() {
            if token.kind == .punctuation {
                if words[index] == "(" { depth += 1 }
                if words[index] == ")" { depth = max(0, depth - 1) }
            }
            guard token.kind == .keyword || token.kind == .identifier else { continue }
            let word = words[index]
            if forbidden.contains(word) { return "`\(word)` is not allowed in a read-only query." }
            if word == "INTO", depth == 0 { return "SELECT … INTO is not allowed in read-only mode." }
        }
        return nil
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH, SHOW, DESC, EXPLAIN, ADMIN SHOW) are allowed; `\(keyword)` statements need a connection with read-write MCP access."
    }
}
