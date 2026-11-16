import Foundation
import MySQLWire
import StarRocksKit

/// Opens (once) and caches a client per profile for the lifetime of the MCP process.
public actor MCPClientRegistry {
    public typealias Opener = @Sendable (ConnectionProfile) async throws -> StarRocksClient

    private let opener: Opener
    private var clients: [UUID: StarRocksClient] = [:]
    private var opening: [UUID: Task<StarRocksClient, any Error>] = [:]

    public init(opener: @escaping Opener) {
        self.opener = opener
    }

    public func client(for profile: ConnectionProfile) async throws -> StarRocksClient {
        if let client = clients[profile.id] { return client }
        if let pending = opening[profile.id] { return try await pending.value }
        let opener = opener
        let task = Task { try await opener(profile) }
        opening[profile.id] = task
        do {
            let client = try await task.value
            opening[profile.id] = nil
            clients[profile.id] = client
            return client
        } catch {
            opening[profile.id] = nil
            throw error
        }
    }

    public func closeAll() async {
        let open = Array(clients.values)
        clients.removeAll()
        for client in open { await client.close() }
    }
}

/// The StarRocks tool set of the MCP server (see the ccinn MCP design, section 6).
public struct StarRocksMCPTools: MCPToolProvider {
    public let resolver: MCPProfileResolver
    public let registry: MCPClientRegistry
    public let audit: MCPAuditLog?

    public static let defaultRowLimit = 200
    public static let maxRowLimit = 1_000
    public static let defaultTimeout = 30.0
    public static let maxTimeout = 120.0

    public init(resolver: MCPProfileResolver, registry: MCPClientRegistry, audit: MCPAuditLog?) {
        self.resolver = resolver
        self.registry = registry
        self.audit = audit
    }

    // MARK: Definitions

    public func tools() async -> [MCPTool] {
        var tools: [MCPTool] = [
            MCPTool(name: "list_connections", title: "List connections",
                    description: "Lists the saved StarRocks connections the user enabled for AI access (no secrets).",
                    inputSchema: ["type": "object", "properties": .object([:]), "additionalProperties": false], readOnly: true),
            MCPTool(name: "list_catalogs", title: "List catalogs",
                    description: "Lists catalogs (default_catalog plus external Hive/Iceberg/Hudi/Delta/JDBC catalogs).",
                    inputSchema: Self.schema([:]), readOnly: true),
            MCPTool(name: "list_databases", title: "List databases",
                    description: "Lists databases in a catalog.",
                    inputSchema: Self.schema(["catalog": Self.catalogProperty]), readOnly: true),
            MCPTool(name: "list_tables", title: "List tables and views",
                    description: "Lists tables, views and materialized views of a database with their kind (table, async_materialized_view, sync_materialized_view, view, external_table), table model (DUP/AGG/UNI/PK), row count, size, partition key and materialized-view refresh health.",
                    inputSchema: Self.schema(["database": Self.databaseProperty, "catalog": Self.catalogProperty,
                                              "name_filter": ["type": "string", "description": "Case-insensitive substring to filter object names."]],
                                             required: ["database"]), readOnly: true),
            MCPTool(name: "describe_table", title: "Describe table",
                    description: "Columns (type, key, nullability, aggregation, comment), table design (model, keys, partitioning, distribution, buckets, properties) and optionally the CREATE statement of a table, view or materialized view.",
                    inputSchema: Self.schema(["database": Self.databaseProperty, "table": Self.tableProperty, "catalog": Self.catalogProperty,
                                              "include_ddl": ["type": "boolean", "description": "Include the CREATE statement (default true)."]],
                                             required: ["database", "table"]), readOnly: true),
            MCPTool(name: "get_partitions", title: "Get partitions",
                    description: "Partitions of a table or async materialized view with range/list bounds, rows, data size, buckets, replication and state.",
                    inputSchema: Self.schema(["database": Self.databaseProperty, "table": Self.tableProperty,
                                              "limit": ["type": "integer", "minimum": 1, "maximum": 5000, "description": "Maximum partitions to return (default 500)."]],
                                             required: ["database", "table"]), readOnly: true),
            MCPTool(name: "analyze_tablet_skew", title: "Analyze tablet skew",
                    description: "Tablet (bucket) sizes of a table, optionally of one partition, flags tablets larger than `threshold` × average, and reports replica distribution per backend.",
                    inputSchema: Self.schema(["database": Self.databaseProperty, "table": Self.tableProperty,
                                              "partition": ["type": "string", "description": "Partition name (default: all partitions)."],
                                              "threshold": ["type": "number", "minimum": 1.1, "maximum": 10, "description": "Skew threshold relative to the average (default 1.5)."]],
                                             required: ["database", "table"]), readOnly: true),
            MCPTool(name: "get_materialized_view", title: "Get materialized view",
                    description: "Status of a materialized view (refresh type, active, last refresh state/time/duration/error, query-rewrite status, definition) and its most recent refresh task runs.",
                    inputSchema: Self.schema(["database": Self.databaseProperty, "name": ["type": "string", "description": "Materialized view name."],
                                              "refresh_limit": ["type": "integer", "minimum": 0, "maximum": 200, "description": "Recent refreshes to include (default 10)."]],
                                             required: ["database", "name"]), readOnly: true),
            MCPTool(name: "get_running_tasks", title: "Get running tasks",
                    description: "What is executing right now: running queries, load jobs, materialized-view refreshes and task runs, routine loads and schema-change jobs.",
                    inputSchema: Self.schema(["database": ["type": "string", "description": "Limit loads and schema changes to one database (default: all user databases)."]]),
                    readOnly: true, idempotent: false),
            MCPTool(name: "list_cluster_nodes", title: "List cluster nodes",
                    description: "Frontends, backends and compute nodes with liveness, version, disk/CPU/memory usage, tablet count and running queries.",
                    inputSchema: Self.schema([:]), readOnly: true, idempotent: false),
            MCPTool(name: "run_query", title: "Run read-only SQL",
                    description: "Runs one read-only statement (SELECT, WITH, SHOW, DESC, EXPLAIN, ADMIN SHOW) and returns columns and rows. A LIMIT is added to queries without one; results are capped at `limit` rows and about 256 KB.",
                    inputSchema: Self.schema(["sql": ["type": "string", "description": "A single read-only SQL statement."],
                                              "database": ["type": "string", "description": "Database to run in (USE). Optional when the SQL qualifies names."],
                                              "catalog": Self.catalogProperty,
                                              "limit": ["type": "integer", "minimum": 1, "maximum": .int(Int64(Self.maxRowLimit)), "description": "Maximum rows (default 200)."],
                                              "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout)), "description": "Time limit (default 30)."]],
                                             required: ["sql"]), readOnly: true, idempotent: false),
            MCPTool(name: "explain_query", title: "Explain query",
                    description: "Shows the execution plan of a SELECT query (EXPLAIN, or EXPLAIN COSTS with statistics and costs).",
                    inputSchema: Self.schema(["sql": ["type": "string", "description": "A SELECT or WITH query."],
                                              "database": ["type": "string", "description": "Database to run in."], "catalog": Self.catalogProperty,
                                              "costs": ["type": "boolean", "description": "Use EXPLAIN COSTS (default false)."]],
                                             required: ["sql"]), readOnly: true),
        ]
        if resolver.anyWritable {
            tools.append(MCPTool(name: "execute_statement", title: "Execute SQL (writes allowed)",
                                 description: "Runs one SQL statement that may change data or schema (INSERT, UPDATE, DELETE, CREATE, ALTER, REFRESH MATERIALIZED VIEW, …). Only available on connections with read-write AI access. Cluster settings (SET GLOBAL, ADMIN SET … CONFIG, UPDATE information_schema.be_configs) cannot be changed here. Prefer run_query for reads.",
                                 inputSchema: Self.schema(["sql": ["type": "string", "description": "A single SQL statement."],
                                                           "database": ["type": "string", "description": "Database to run in."], "catalog": Self.catalogProperty,
                                                           "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout))]],
                                                          required: ["sql"]), readOnly: false, destructive: true, idempotent: false))
        }
        return tools
    }

    static let connectionProperty: JSONValue = ["type": "string", "description": "Saved connection name or id (see list_connections). Optional when only one connection is enabled or a default was configured."]
    static let databaseProperty: JSONValue = ["type": "string", "description": "Database name."]
    static let tableProperty: JSONValue = ["type": "string", "description": "Table, view or materialized view name."]
    static let catalogProperty: JSONValue = ["type": "string", "description": "Catalog name (default: default_catalog)."]

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var all = properties
        all["connection"] = connectionProperty
        return ["type": "object", "properties": .object(all), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }

    // MARK: Calls

    /// Collects audit details while a tool runs.
    final class CallContext: @unchecked Sendable {
        var connection: String?
        var statement: String?
        var rows: Int?
    }

    public func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        let clock = ContinuousClock()
        let started = clock.now
        let context = CallContext()
        let result: MCPToolResult
        do {
            result = .success(try await dispatch(name, Arguments(arguments), context))
        } catch let error as MCPToolError {
            result = .failure(error.message)
        } catch let error as StarRocksError {
            result = .failure(error.code.map { "\(error.message) (error \($0))" } ?? error.message)
        } catch {
            result = .failure(error.localizedDescription)
        }
        let elapsed = clock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        await audit?.record(tool: name, connection: context.connection, statement: context.statement, durationMilliseconds: milliseconds,
                            rows: context.rows, error: result.isError ? result.payload.stringValue : nil)
        return result
    }

    private func dispatch(_ name: String, _ args: Arguments, _ context: CallContext) async throws -> JSONValue {
        if name == "list_connections" { return listConnections() }
        let resolved = try resolver.resolve(args.string("connection"))
        context.connection = resolved.profile.displayName
        let client = try await registry.client(for: resolved.profile)
        switch name {
        case "list_catalogs":
            let catalogs = try await client.catalogs()
            return ["catalogs": .array(catalogs.map { ["name": .string($0.name), "type": .string($0.type), "comment": JSONValue($0.comment)] })]
        case "list_databases":
            let catalog = args.string("catalog") ?? SQLText.defaultCatalog
            return ["catalog": .string(catalog), "databases": .array(try await client.databases(catalog: catalog).map(JSONValue.string))]
        case "list_tables":
            return try await listTables(client, args)
        case "describe_table":
            return try await describeTable(client, args)
        case "get_partitions":
            return try await partitions(client, args)
        case "analyze_tablet_skew":
            return try await tabletSkew(client, args)
        case "get_materialized_view":
            return try await materializedView(client, args)
        case "get_running_tasks":
            return try await runningTasks(client, args)
        case "list_cluster_nodes":
            return ["nodes": .array(try await client.nodes().map(Self.encode(node:)))]
        case "run_query":
            return try await runQuery(client, args, context, access: resolved.access)
        case "explain_query":
            return try await explain(client, args, context)
        case "execute_statement":
            guard resolved.access == .readWrite else {
                throw MCPToolError("Connection “\(resolved.profile.displayName)” only allows read-only AI access; use run_query, or change its AI access to Read & write in CcinnStarRocks.")
            }
            return try await execute(client, args, context)
        default:
            throw MCPToolError("Unknown tool “\(name)”.")
        }
    }

    private func listConnections() -> JSONValue {
        ["connections": .array(resolver.enabledProfiles.map { profile in
            [
                "name": .string(profile.displayName),
                "id": .string(profile.id.uuidString),
                "endpoint": .string(profile.endpoint.description),
                "user": .string(profile.username),
                "default_database": JSONValue(profile.defaultDatabase),
                "default_catalog": JSONValue(profile.defaultCatalog),
                "ssh_tunnel": .bool(profile.ssh != nil),
                "access": .string(resolver.access(of: profile) == .readWrite ? "read_write" : "read_only"),
            ]
        })]
    }

    // MARK: Metadata tools

    private func listTables(_ client: StarRocksClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let catalog = args.string("catalog") ?? SQLText.defaultCatalog
        var objects = try await client.objects(catalog: catalog, database: database)
        if let filter = args.string("name_filter"), !filter.isEmpty {
            objects = objects.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        let cap = 1_000
        return [
            "catalog": .string(catalog), "database": .string(database),
            "objects": .array(objects.prefix(cap).map(Self.encode(object:))),
            "count": .int(Int64(objects.count)), "truncated": .bool(objects.count > cap),
        ]
    }

    private func findObject(_ client: StarRocksClient, catalog: String, database: String, name: String) async throws -> DatabaseObject {
        let objects = try await client.objects(catalog: catalog, database: database)
        if let exact = objects.first(where: { $0.name == name }) ?? objects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let similar = objects.filter { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }.prefix(10).map(\.name)
        throw MCPToolError("No table or view named “\(name)” in \(database).\(similar.isEmpty ? "" : " Similar: \(similar.joined(separator: ", ")).")")
    }

    private func describeTable(_ client: StarRocksClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let catalog = args.string("catalog") ?? SQLText.defaultCatalog
        let object = try await findObject(client, catalog: catalog, database: database, name: try args.required("table"))
        let columns = try await client.columns(of: object)
        var result = Self.encode(object: object).objectValue ?? [:]
        result["columns"] = .array(columns.map { column in
            [
                "name": .string(column.name), "type": .string(column.columnType), "nullable": .bool(column.isNullable),
                "key": .bool(column.isKey), "aggregation": JSONValue(column.aggregation), "default": JSONValue(column.defaultValue),
                "comment": JSONValue(column.comment),
            ]
        })
        result["properties"] = .object(object.properties.mapValues(JSONValue.string))
        if args.bool("include_ddl") ?? true, let ddl = try? await client.ddl(of: object) {
            result["ddl"] = .string(ddl.count > 20_000 ? String(ddl.prefix(20_000)) + "\n-- (truncated)" : ddl)
        }
        if object.kind == .asyncMaterializedView || object.kind == .syncMaterializedView, let status = object.materializedView {
            result["materialized_view"] = Self.encode(status: status)
        }
        return .object(result)
    }

    private func partitions(_ client: StarRocksClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let table = try args.required("table")
        let limit = args.int("limit", default: 500, range: 1...5_000)
        let partitions = try await client.partitions(database: database, table: table)
        let totalRows = partitions.reduce(Int64(0)) { $0 &+ ($1.rowCount ?? 0) }
        let totalBytes = partitions.reduce(Int64(0)) { $0 &+ ($1.dataSize ?? 0) }
        return [
            "database": .string(database), "table": .string(table),
            "partition_count": .int(Int64(partitions.count)), "total_rows": .int(totalRows), "total_bytes": .int(totalBytes),
            "note": "Row counts and sizes include synchronous materialized view (rollup) indexes.",
            "partitions": .array(partitions.prefix(limit).map { partition in
                [
                    "name": .string(partition.name), "lower_bound": JSONValue(partition.bounds.lower), "upper_bound": JSONValue(partition.bounds.upper),
                    "values": JSONValue(partition.bounds.values), "rows": JSONValue(partition.rowCount), "data_bytes": JSONValue(partition.dataSize),
                    "buckets": JSONValue(partition.buckets), "replication_num": JSONValue(partition.replicationNum), "state": JSONValue(partition.state),
                    "storage_medium": JSONValue(partition.storageMedium), "visible_version_time": JSONValue(partition.visibleVersionTime),
                    "temporary": .bool(partition.isTemporary),
                ]
            }),
            "truncated": .bool(partitions.count > limit),
        ]
    }

    private func tabletSkew(_ client: StarRocksClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let table = try args.required("table")
        let threshold = min(max(args.double("threshold") ?? 1.5, 1.1), 10)
        let replicas = try await client.tablets(database: database, table: table, partition: args.string("partition"))
        let report = SkewAnalyzer.analyze(replicas, threshold: threshold)
        var result: [String: JSONValue] = [
            "database": .string(database), "table": .string(table), "partition": JSONValue(args.string("partition")),
            "tablets": .int(Int64(report.entries.count)),
            "metric": .string(report.metric == .dataSize ? "data_bytes" : "rows"),
            "average": .double((report.average * 10).rounded() / 10),
            "max_ratio": .double((report.maxRatio * 100).rounded() / 100),
            "coefficient_of_variation": .double((report.coefficientOfVariation * 1000).rounded() / 1000),
            "threshold": .double(threshold),
            "skewed_tablets": .int(Int64(report.skewedCount)),
            "largest_tablets": .array(report.entries.sorted { $0.ratio > $1.ratio }.prefix(20).map { entry in
                ["tablet_id": .string(entry.tabletID), "data_bytes": .int(entry.dataSize), "rows": .int(entry.rowCount),
                 "ratio": .double((entry.ratio * 100).rounded() / 100), "skewed": .bool(entry.isSkewed)]
            }),
        ]
        if let distribution = try? await client.replicaDistribution(database: database, table: table) {
            result["replicas_per_backend"] = .array(distribution.map {
                ["backend_id": .string($0.backendID), "replicas": .int($0.replicaCount), "percent": JSONValue($0.percent)]
            })
        }
        return .object(result)
    }

    private func materializedView(_ client: StarRocksClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let name = try args.required("name")
        guard let status = try await client.materializedViewStatus(database: database, name: name) else {
            throw MCPToolError("No materialized view named “\(name)” in \(database).")
        }
        var result = Self.encode(status: status).objectValue ?? [:]
        result["database"] = .string(database)
        result["name"] = .string(name)
        let limit = args.int("refresh_limit", default: 10, range: 0...200)
        if limit > 0, let task = status.taskName {
            let runs = try await client.taskRuns(taskName: task, limit: limit)
            result["recent_refreshes"] = .array(runs.map(Self.encode(run:)))
        }
        return .object(result)
    }

    private func runningTasks(_ client: StarRocksClient, _ args: Arguments) async throws -> JSONValue {
        let databases: [String]
        if let database = args.string("database") {
            databases = [database]
        } else {
            databases = try await client.databases().filter { !["_statistics_", "information_schema", "sys"].contains($0) }
        }
        let snapshot = await client.activity(databases: databases)
        let cap = 100
        return [
            "queries": .array(snapshot.queries.prefix(cap).map { process in
                ["connection_id": .int(Int64(process.connectionID)), "user": JSONValue(process.user), "database": JSONValue(process.database),
                 "seconds": JSONValue(process.timeSeconds), "statement": JSONValue(process.statement.map { String($0.prefix(2_000)) }),
                 "query_id": JSONValue(process.queryID)]
            }),
            "loads": .array(snapshot.loads.prefix(cap).map { job in
                ["label": .string(job.label), "state": .string(job.state), "type": JSONValue(job.type), "database": JSONValue(job.database),
                 "table": JSONValue(job.table), "progress": JSONValue(job.progress), "created": JSONValue(job.createTime)]
            }),
            "task_runs": .array(snapshot.taskRuns.prefix(cap).map(Self.encode(run:))),
            "routine_loads": .array(snapshot.routineLoads.prefix(cap).map { job in
                ["name": .string(job.name), "state": .string(job.state), "database": JSONValue(job.database), "table": JSONValue(job.table),
                 "source": JSONValue(job.dataSourceType), "running_tasks": JSONValue(job.currentTaskCount)]
            }),
            "schema_changes": .array(snapshot.alterJobs.prefix(cap).map { job in
                ["kind": .string(job.kind.displayName), "database": .string(job.database), "table": .string(job.table),
                 "index": JSONValue(job.indexName), "state": .string(job.state), "progress": JSONValue(job.progress), "created": JSONValue(job.createTime)]
            }),
            "unavailable": .object(snapshot.unavailable.mapValues(JSONValue.string)),
        ]
    }

    // MARK: SQL tools

    private func runQuery(_ client: StarRocksClient, _ args: Arguments, _ context: CallContext, access: MCPAccess) async throws -> JSONValue {
        let sql = try args.required("sql")
        if let reason = ReadOnlySQLGuard.check(sql) {
            let hint = access == .readWrite ? " Use execute_statement for statements that change data." : ""
            throw MCPToolError(reason + hint)
        }
        guard let statement = SQLStatementSplitter.split(sql).first?.text else { throw MCPToolError("The statement is empty.") }
        let limit = args.int("limit", default: Self.defaultRowLimit, range: 1...Self.maxRowLimit)
        var executed = statement
        var limitApplied = false
        if SQLStatementKind.of(statement) == .query {
            let outcome = AutoLimit.apply(to: statement, limit: limit + 1)
            executed = outcome.sql
            limitApplied = outcome.applied
        }
        context.statement = executed
        let started = ContinuousClock.now
        let results = try await runInSession(client, sql: executed, args: args, limits: RowLimits(maxRows: limit, drainRows: 10_000))
        let elapsed = ContinuousClock.now - started
        var payload = Self.encode(results: results, limitRows: limit)
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        payload["statement"] = .string(executed)
        payload["limit_applied"] = .bool(limitApplied)
        payload["database"] = JSONValue(args.string("database"))
        payload["elapsed_ms"] = .int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return .object(payload)
    }

    private func explain(_ client: StarRocksClient, _ args: Arguments, _ context: CallContext) async throws -> JSONValue {
        let sql = try args.required("sql")
        guard let statement = SQLStatementSplitter.split(sql).first?.text, SQLStatementSplitter.split(sql).count == 1 else {
            throw MCPToolError("Pass exactly one SELECT query.")
        }
        let body = SQLStatementKind.of(statement) == .explain ? statement : ((args.bool("costs") ?? false) ? "EXPLAIN COSTS " : "EXPLAIN ") + statement
        if let reason = ReadOnlySQLGuard.check(body) { throw MCPToolError(reason) }
        context.statement = body
        let results = try await runInSession(client, sql: body, args: args, limits: RowLimits(maxRows: 20_000, maxBytes: 16 * 1024 * 1024))
        let lines = results.last { $0.hasRowSet }?.rows.map { $0.compactMap { $0 }.joined(separator: "\t") } ?? []
        var plan = lines.joined(separator: "\n")
        if plan.utf8.count > MCPResultEncoder.defaultMaxBytes { plan = String(plan.prefix(MCPResultEncoder.defaultMaxBytes)) + "\n… (truncated)" }
        context.rows = lines.count
        return ["statement": .string(body), "plan": .string(plan)]
    }

    /// The one statement `execute_statement` may run. Cluster setting changes are refused: the SQL editor asks the
    /// user to confirm them, and an MCP call cannot be confirmed.
    static func executableStatement(_ sql: String) throws -> String {
        let statements = SQLStatementSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first?.text else {
            throw MCPToolError("Pass exactly one statement per call.")
        }
        if let change = ClusterSettingChange.of(statement) {
            throw MCPToolError("Changing \(change.displayName) is not allowed over MCP. Cluster settings can only be changed in the CcinnStarRocks SQL editor, where every change must be confirmed by the user.")
        }
        return statement
    }

    private func execute(_ client: StarRocksClient, _ args: Arguments, _ context: CallContext) async throws -> JSONValue {
        let statement = try Self.executableStatement(try args.required("sql"))
        context.statement = statement
        let results = try await runInSession(client, sql: statement, args: args, limits: RowLimits(maxRows: Self.maxRowLimit, drainRows: 10_000))
        var payload = Self.encode(results: results, limitRows: Self.maxRowLimit)
        payload["statement"] = .string(statement)
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        return .object(payload)
    }

    /// Runs on a short-lived session in the requested catalog/database, bounded by a deadline.
    /// Cancelling the calling task (client cancellation or timeout) kills the query on the server.
    private func runInSession(_ client: StarRocksClient, sql: String, args: Arguments, limits: RowLimits) async throws -> [ResultSet] {
        let timeout = min(max(args.double("timeout_seconds") ?? Self.defaultTimeout, 1), Self.maxTimeout)
        let session = client.openSession(database: args.string("database"), catalog: args.string("catalog"))
        do {
            let results = try await Deadline.run(seconds: timeout, timeoutError: {
                StarRocksError(.timeout, "The statement did not finish within \(Int(timeout)) s and was cancelled; narrow the query or raise timeout_seconds (max \(Int(Self.maxTimeout))).")
            }) {
                try await session.run(sql, limits: limits)
            }
            await session.close()
            return results
        } catch {
            await session.cancel(graceSeconds: 1)
            await session.close()
            throw error
        }
    }

    // MARK: Encoding

    static func encode(results: [ResultSet], limitRows: Int) -> [String: JSONValue] {
        guard let rowSet = results.last(where: \.hasRowSet) else {
            let affected = results.reduce(UInt64(0)) { $0 &+ $1.affectedRows }
            return ["affected_rows": .int(Int64(clamping: affected)), "row_count": 0,
                    "info": .string(results.map(\.info).filter { !$0.isEmpty }.joined(separator: "\n"))]
        }
        let columns = rowSet.columns.map { ColumnInfoLite(name: $0.name, kind: $0.type.kind) }
        let encoded = MCPResultEncoder.rows(columns: columns, rows: Array(rowSet.rows.prefix(limitRows)),
                                            truncatedByServer: rowSet.isTruncated || rowSet.rows.count > limitRows)
        return encoded.objectValue ?? [:]
    }

    static func kindName(_ kind: ObjectKind) -> String {
        switch kind {
        case .table: "table"
        case .asyncMaterializedView: "async_materialized_view"
        case .syncMaterializedView: "sync_materialized_view"
        case .view: "view"
        case .externalTable: "external_table"
        case .systemView: "system_view"
        }
    }

    static func encode(object: DatabaseObject) -> JSONValue {
        var result: [String: JSONValue] = [
            "name": .string(object.name), "kind": .string(kindName(object.kind)),
            "model": JSONValue(object.model?.badge), "rows": JSONValue(object.rowCount), "data_bytes": JSONValue(object.dataLength),
            "comment": JSONValue(object.comment), "partition_key": JSONValue(object.partitionKey),
            "distribution_key": JSONValue(object.distributionKey), "buckets": JSONValue(object.buckets),
            "sort_key": JSONValue(object.sortKey), "primary_key": JSONValue(object.primaryKey),
        ]
        if let base = object.baseTable { result["base_table"] = .string(base) }
        if let status = object.materializedView, object.kind == .asyncMaterializedView {
            result["mv_health"] = .string(healthName(status.health))
            result["mv_last_refresh_state"] = JSONValue(status.lastRefreshState)
        }
        return .object(result.filter { $0.value != .null })
    }

    static func healthName(_ health: MaterializedViewStatus.Health) -> String {
        switch health {
        case .healthy: "up_to_date"
        case .refreshing: "refreshing"
        case .failed: "last_refresh_failed"
        case .inactive: "inactive"
        case .neverRefreshed: "not_refreshed"
        case .maintainedSynchronously: "synchronous"
        }
    }

    static func encode(status: MaterializedViewStatus) -> JSONValue {
        [
            "refresh_type": .string(status.refreshType), "active": .bool(status.isActive), "health": .string(healthName(status.health)),
            "inactive_reason": JSONValue(status.inactiveReason), "partition_type": JSONValue(status.partitionType),
            "task_name": JSONValue(status.taskName), "last_refresh_state": JSONValue(status.lastRefreshState),
            "last_refresh_start": JSONValue(status.lastRefreshStart), "last_refresh_finish": JSONValue(status.lastRefreshFinish),
            "last_refresh_seconds": JSONValue(status.lastRefreshDurationSeconds), "last_refresh_error": JSONValue(status.lastRefreshError),
            "rows": JSONValue(status.rowCount), "query_rewrite": JSONValue(status.rewriteStatus), "schedule": JSONValue(status.refreshPolicy),
            "definition": JSONValue(status.definition),
        ]
    }

    static func encode(run: TaskRun) -> JSONValue {
        [
            "task_name": .string(run.taskName), "state": .string(run.state), "database": JSONValue(run.database),
            "created": JSONValue(run.createTime), "finished": JSONValue(run.finishTime), "progress": JSONValue(run.progress),
            "duration_seconds": JSONValue(run.duration().map { ($0 * 10).rounded() / 10 }), "error": JSONValue(run.errorMessage),
            "query_id": .string(run.queryID),
        ]
    }

    static func encode(node: ClusterNode) -> JSONValue {
        [
            "role": .string(node.role.rawValue), "id": .string(node.nodeID), "host": .string(node.host), "alive": .bool(node.isAlive),
            "version": JSONValue(node.version), "fe_role": JSONValue(node.feRole), "tablets": JSONValue(node.tabletCount),
            "data_used_bytes": JSONValue(node.dataUsed), "total_capacity_bytes": JSONValue(node.totalCapacity),
            "disk_used_percent": JSONValue(node.usedPercent), "cpu_used_percent": JSONValue(node.cpuUsedPercent),
            "memory_used_percent": JSONValue(node.memoryUsedPercent), "running_queries": JSONValue(node.runningQueries),
            "last_heartbeat": JSONValue(node.lastHeartbeat), "error": JSONValue(node.errorMessage),
        ]
    }
}

/// Typed access to tool arguments with clear error messages.
struct Arguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        let text: String? = switch value {
        case let .string(string): string
        case let .int(number): String(number)
        default: nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw MCPToolError("Missing required argument `\(key)`.") }
        return value
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let value = values[key]?.intValue else { return fallback }
        return Int(clamping: min(max(value, Int64(range.lowerBound)), Int64(range.upperBound)))
    }

    func double(_ key: String) -> Double? {
        values[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }
}
