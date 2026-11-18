import Foundation
import Testing
@testable import CcinnStarRocksKit

/// 1.3.2: AI tools never read other sessions' SQL, credentials or files on the servers. Probed on StarRocks 3.3 and 4.1:
/// a plain account reads other users' task SQL (literals included) from information_schema.tasks, and
/// `FILES('path' = 'file:///etc/passwd', …)` returns the backend host's files to an account with SELECT on one database.
@Suite("Secret-bearing sources")
struct SecretSourceTests {
    @Test(arguments: [
        "SELECT * FROM information_schema.tasks",
        "SELECT DEFINITION FROM INFORMATION_SCHEMA.TASK_RUNS",
        "SELECT * FROM `information_schema`.`loads`",
        "SELECT * FROM information_schema . routine_load_jobs",
        "SELECT * FROM default_catalog.information_schema.pipes",
        "SELECT * FROM information_schema/*c*/.pipe_files",
        "SELECT * FROM information_schema.be_logs",
        "SELECT * FROM information_schema.be_configs",
        "SELECT * FROM information_schema.warehouse_queries",
        "SELECT * FROM information_schema.load_tracking_logs WHERE label = 'x'",
        "SELECT * FROM information_schema.stream_loads",
        "SELECT * FROM information_schema.some_future_table",
        "SELECT * FROM _statistics_.query_history",
        "SELECT * FROM _statistics_.task_run_history",
        "SELECT * FROM _statistics_.loads_history",
        "SELECT * FROM sys.fe_locks",
        "SELECT * FROM starrocks_audit_db__.starrocks_audit_tbl__",
        "SELECT a FROM shop.orders o JOIN information_schema.tasks t ON t.TASK_NAME = o.city",
        "WITH x AS (SELECT * FROM information_schema.tasks) SELECT * FROM x",
        "SELECT * FROM shop.orders WHERE city IN (SELECT DEFINITION FROM information_schema.tasks)",
        "SHOW PROCESSLIST", "SHOW FULL PROCESSLIST", "SHOW PROC '/current_queries'", "SHOW RUNNING QUERIES",
        "SHOW CREATE CATALOG hive", "SHOW CREATE ROUTINE LOAD shop.job", "SHOW ROUTINE LOAD", "SHOW LOAD", "SHOW EXPORT",
        "SHOW RESOURCES", "SHOW STORAGE VOLUMES", "SHOW REPOSITORIES", "SHOW AUTHENTICATION", "SHOW ALL AUTHENTICATION",
        "SHOW GRANTS FOR 'root'@'%'", "SHOW PIPES", "SHOW PROFILELIST", "SHOW USERS", "SHOW BACKUP",
        "ADMIN SHOW FRONTEND CONFIG", "ADMIN SHOW FRONTEND CONFIG LIKE '%secret%'",
        "DESC STORAGE VOLUME builtin_storage_volume", "DESCRIBE STORAGE VOLUME v",
        "SELECT * FROM FILES('path' = 'file:///etc/passwd', 'format' = 'csv')",
        "SELECT * FROM files ('path' = 's3://bucket/x.parquet', 'format' = 'parquet')",
        "SELECT * FROM FILES/*c*/('path' = 'hdfs://x/y')",
        "SELECT * FROM `files`('path' = 'file:///etc/hostname')",
        "SELECT * FROM TABLE(FILES('path' = 'file:///etc/hostname'))",
        "DESC FILES('path' = 'file:///etc/hostname', 'format' = 'csv')",
        "SELECT get_query_profile('8f1c…')",
        // 4.1: the backend POSTs the prompt (query data) to any endpoint and returns the reply (review of 1.3.2).
        "SELECT ai_query(concat('x:', (SELECT max(city) FROM shop.orders)), '{\"model\":\"m\",\"endpoint\":\"http://10.0.0.1/x\"}') AS r",
        "SELECT AI_QUERY ('p', '{}')",
        "SELECT `ai_query`('p', '{}')",
        "EXPLAIN SELECT * FROM information_schema.tasks",
        "EXPLAIN SELECT * FROM FILES('path' = 'file:///etc/passwd')",
    ])
    func secretSourcesAreRefused(sql: String) throws {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
        #expect(throws: MCPToolError.self, "execute_statement too: \(sql)") { try StarRocksMCPTools.executableStatement(sql) }
    }

    @Test(arguments: [
        "SELECT * FROM information_schema.tables WHERE table_schema = 'shop'",
        "SELECT * FROM `INFORMATION_SCHEMA`.`COLUMNS`",
        "SELECT * FROM information_schema.partitions_meta",
        "SELECT * FROM information_schema.materialized_views",
        "SELECT * FROM information_schema.be_tablets",
        "SELECT * FROM _statistics_.column_statistics",
        "SELECT * FROM sys.object_dependencies",
        "SELECT tasks, files, definition FROM shop.tasks",
        "SELECT * FROM shop.loads",
        "SELECT files.a FROM shop.files",
        "SHOW TABLES", "SHOW FULL TABLES FROM shop", "SHOW DATABASES", "SHOW COLUMNS FROM shop.orders", "SHOW CREATE TABLE shop.orders",
        "SHOW CREATE MATERIALIZED VIEW shop.mv_city_daily", "SHOW CREATE VIEW shop.v", "SHOW PARTITIONS FROM shop.orders",
        "SHOW TEMPORARY PARTITIONS FROM shop.orders", "SHOW TABLET FROM shop.orders", "SHOW DATA", "SHOW MATERIALIZED VIEWS FROM shop",
        "SHOW CATALOGS", "SHOW VARIABLES LIKE 'query_timeout'", "SHOW BACKENDS", "SHOW FRONTENDS", "SHOW GRANTS", "SHOW ROLES",
        "SHOW ALTER TABLE COLUMN FROM shop", "SHOW INDEX FROM shop.orders", "SHOW TABLE STATUS FROM shop", "SHOW FUNCTIONS",
        "DESC shop.orders", "DESCRIBE orders", "ADMIN SHOW REPLICA DISTRIBUTION FROM shop.orders", "ADMIN SHOW REPLICA STATUS FROM shop.orders",
        "EXPLAIN SELECT * FROM information_schema.tables",
    ])
    func ordinaryReadsAreAllowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    /// 1.3.2 review: StarRocks matches keywords per character with Java's upper case (ı is I, ſ is S) and system schema
    /// names with Java's equalsIgnoreCase (İ and ı equal i, K equals k, ſ equals s). `fıles(` returned the backend's
    /// /etc/passwd on 3.3 and 4.1 while the guard compared "fıles" with "files". A name with a letter whose case maps to
    /// an ASCII letter cannot be compared the way the server reads it: refused, quoted or not.
    @Test(arguments: [
        "SELECT * FROM fıles(\"path\" = \"file:///etc/passwd\", \"format\" = \"csv\", \"csv.column_separator\" = \"\\\\x01\") LIMIT 3",
        "SELECT * FROM fileſ('path' = 'file:///etc/passwd', 'format' = 'csv')",
        "SELECT * FROM FıLES('path' = 'file:///etc/passwd', 'format' = 'csv')",
        "WITH x AS (SELECT * FROM fıles('path' = 'file:///etc/passwd', 'format' = 'csv')) SELECT * FROM x",
        "SELECT * FROM (SELECT * FROM fıles('path' = 'file:///etc/passwd', 'format' = 'csv')) d",
        "SELECT * FROM `fıles`('path' = 'file:///etc/hostname')",
        "SELECT * FROM ﬁles('path' = 'file:///etc/hostname')",
        "SELECT get_query_profıle('8f1c…')",
        "SELECT * FROM ınformation_schema.tasks",
        "SELECT * FROM `ınformation_schema`.`tasks`",
        "SELECT * FROM İNFORMATION_SCHEMA.TASKS",
        "SELECT * FROM _ſtatistics_.query_history",
        "SELECT * FROM starroc\u{212A}s_audit_db__.starrocks_audit_tbl__",
        "SELECT * FROM shop.orders WHERE city IN (SELECT DEFINITION FROM ınformation_schema.tasks)",
        "EXPLAIN SELECT * FROM fıles('path' = 'file:///etc/passwd')",
        "DESC fıles('path' = 'file:///etc/hostname', 'format' = 'csv')",
    ])
    func caseConfusableNamesAreRefused(sql: String) throws {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
        #expect(throws: MCPToolError.self, "execute_statement too: \(sql)") { try StarRocksMCPTools.executableStatement(sql) }
    }

    /// Only names are compared: the same letters in strings and comments, and other non-ASCII letters in names, pass.
    @Test(arguments: [
        "SELECT 'fıles(' AS a, city FROM shop.orders -- ınformation_schema.tasks",
        "SELECT city /* fileſ('path' = 'x') */ FROM shop.orders WHERE note = 'ınformation_schema.tasks'",
        "SELECT `café`, `名前`, `prix_€` FROM shop.orders",
        "SELECT straat, ciudad, città FROM shop.orders",
    ])
    func confusableLettersOutsideNamesAreAllowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    @Test func confusableSessionDatabaseIsRefused() {
        for database in ["ınformation_schema", "İnformation_schema", "_ſtatistics_", "ſys"] {
            #expect(ReadOnlySQLGuard.check("SELECT * FROM tasks", database: database) != nil, "\(database)")
        }
    }

    /// The letters refused in names: every non-ASCII character whose upper, lower or title case contains an ASCII letter.
    /// Pinned, so a Unicode update that changes the set is reviewed.
    @Test func caseConfusableLettersArePinned() {
        let found = (0x80...0x10FFFF).compactMap { Unicode.Scalar(UInt32($0)) }.filter(ReadOnlySQLGuard.caseMapsToASCII).map(\.value)
        #expect(found == [0xDF, 0x130, 0x131, 0x149, 0x17F, 0x1F0, 0x1E96, 0x1E97, 0x1E98, 0x1E99, 0x1E9A, 0x212A,
                          0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB05, 0xFB06])
        #expect(!ReadOnlySQLGuard.caseMapsToASCII("a") && !ReadOnlySQLGuard.caseMapsToASCII("é") && !ReadOnlySQLGuard.caseMapsToASCII("中"))
    }

    /// Unqualified names would resolve in a system schema chosen as the session's database: refused there.
    @Test func systemSchemasAreNotASessionDatabase() {
        for database in ["information_schema", "INFORMATION_SCHEMA", "sys", "_statistics_", "starrocks_audit_db__"] {
            #expect(ReadOnlySQLGuard.check("SELECT * FROM tasks", database: database) != nil, "\(database)")
        }
        #expect(ReadOnlySQLGuard.check("SELECT * FROM tasks", database: "shop") == nil)
        #expect(ReadOnlySQLGuard.check("SHOW TABLES", database: "information_schema") == nil, "names only")
    }

    /// 1.3.2 review: the handshake database `default_catalog.information_schema` is catalog + database on the server, so
    /// task SQL leaked through `SELECT … FROM tasks`; every dotted part is checked. The wire writer drops NUL from a
    /// handshake string, and the server ignores control characters: neither may hide a system schema.
    @Test func catalogQualifiedAndControlCharacterSessionDatabasesAreRefused() {
        for database in ["default_catalog.information_schema", "DEFAULT_CATALOG.INFORMATION_SCHEMA", "`default_catalog`.`information_schema`",
                         "default_catalog . information_schema", "hive.information_schema", "default_catalog.sys", "default_catalog._statistics_",
                         "default_catalog.starrocks_audit_db__", "information_\u{0}schema", "information_schema\u{0}", "shop\u{0}", "shop\u{7}",
                         "information_schema\t", "shop\u{85}"] {
            #expect(ReadOnlySQLGuard.check("SELECT * FROM tasks", database: database) != nil, "\(database.debugDescription)")
            #expect(throws: MCPToolError.self, "execute_statement: \(database.debugDescription)") {
                try StarRocksMCPTools.executableStatement("SELECT * FROM tasks", database: database)
            }
        }
        for database in ["default_catalog.shop", "hive_catalog.sales", "shop"] {
            #expect(ReadOnlySQLGuard.check("SELECT * FROM orders", database: database) == nil, "\(database)")
        }
    }

    /// Names in tool arguments go to the server as given (handshake, SET CATALOG, metadata statements), and the wire
    /// and identifier quoting drop NUL: every argument but the SQL text is refused when it holds a control character.
    @Test func controlCharactersInNameArgumentsAreRefused() {
        for (key, value) in [("catalog", "default\u{0}_catalog"), ("database", "information_\u{0}schema"), ("table", "tasks\u{1}"),
                             ("connection", "prod\u{7F}"), ("name", "mv\u{85}")] {
            #expect(Arguments([key: .string(value), "sql": .string("SELECT 1")]).controlCharacterArgument() == key, "\(key)")
        }
        #expect(Arguments(["sql": .string("SELECT\t1\n FROM t"), "database": .string("shop"), "limit": .int(5)]).controlCharacterArgument() == nil)
    }

    /// The text sent to the server is built and guarded by one function: the guard checks the exact final text.
    @Test func theWireTextIsTheGuardedText() throws {
        let plain = try ReadOnlySQLGuard.wireStatement(for: "select * from shop.orders", rowLimit: 201, database: nil)
        #expect(plain.sql == "select * from shop.orders LIMIT 201")
        #expect(plain.limitApplied)
        #expect(ReadOnlySQLGuard.check(plain.sql) == nil)
        let tail = try ReadOnlySQLGuard.wireStatement(for: "SELECT 1 AS a -- note\n;", rowLimit: 11, database: nil)
        #expect(tail.sql == "SELECT 1 AS a LIMIT 11 -- note")
        let limited = try ReadOnlySQLGuard.wireStatement(for: "SELECT 1 LIMIT 5", rowLimit: 11, database: nil)
        #expect(limited.sql == "SELECT 1 LIMIT 5")
        #expect(!limited.limitApplied)
        let show = try ReadOnlySQLGuard.wireStatement(for: "SHOW TABLES;", rowLimit: 11, database: nil)
        #expect(show.sql == "SHOW TABLES")
        #expect(throws: ReadOnlySQLGuard.Rejection.self) { try ReadOnlySQLGuard.wireStatement(for: "SELECT 1; SELECT 2", rowLimit: 11, database: nil) }
        #expect(throws: ReadOnlySQLGuard.Rejection.self) { try ReadOnlySQLGuard.wireStatement(for: "SELECT * FROM information_schema.tasks", rowLimit: 11, database: nil) }
        let explain = try ReadOnlySQLGuard.explainStatement(for: "SELECT * FROM shop.orders", costs: true, database: nil)
        #expect(explain.sql == "EXPLAIN COSTS SELECT * FROM shop.orders")
        #expect(throws: ReadOnlySQLGuard.Rejection.self) { try ReadOnlySQLGuard.explainStatement(for: "SELECT 1; DROP TABLE t", costs: false, database: nil) }
        #expect(throws: ReadOnlySQLGuard.Rejection.self) { try ReadOnlySQLGuard.explainStatement(for: "DELETE FROM t", costs: false, database: nil) }
        // Whatever the builder returns passes the guard as sent.
        var generator = SystemRandomNumberGenerator()
        let pieces = ["SELECT", "a", "FROM", "t", "WHERE", "x", "=", "'s'", "--c\n", "/*c*/", "LIMIT", "1", ";", "(", ")", ",", "INTO", "OUTFILE",
                      "information_schema", ".", "tasks", "files", "UNION", "ALL", "WITH", "AS", "SHOW", "EXPLAIN"]
        for _ in 0..<3_000 {
            let text = (0..<Int.random(in: 1...14, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined(separator: " ")
            guard let wire = try? ReadOnlySQLGuard.wireStatement(for: text, rowLimit: 11, database: nil) else { continue }
            #expect(ReadOnlySQLGuard.check(wire.sql) == nil, "\(text.debugDescription) → \(wire.sql.debugDescription)")
            #expect(SQLStatementSplitter.split(wire.sql).count == 1)
        }
    }

    /// Session tools show other sessions' statements as digests: every literal becomes `?`, comments go.
    @Test func digestsHideEveryLiteral() {
        #expect(SQLDigest.digest("SELECT * FROM t WHERE token = 'CCINNSECRET' AND n = 42 /* note CCINNSECRET2 */")
            == "SELECT * FROM t WHERE token = ? AND n = ?")
        #expect(SQLDigest.digest("INSERT INTO t SELECT * FROM FILES(\"path\" = \"s3://b/x\", \"aws.s3.secret_key\" = \"CCINNSECRET\")")
            == "INSERT INTO t SELECT * FROM FILES(? = ?, ? = ?)")
        #expect(SQLDigest.digest("CREATE USER u IDENTIFIED BY 'pw' -- CCINNSECRET") == "CREATE USER u IDENTIFIED BY ?")
        #expect(SQLDigest.digest("SELECT x'0F', 1.5e3, -7, @v, `name`") == "SELECT x?, ?, -?, @v, `name`")
        #expect(SQLDigest.digest("SELECT 'unterminated CCINNSECRET") == "SELECT ?")
        #expect(SQLDigest.digest("Unexpected input 'CCINNSECRET', near line 1") == "Unexpected input ?, near line ?")
    }
}
