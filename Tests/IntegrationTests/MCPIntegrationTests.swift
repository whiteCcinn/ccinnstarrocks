import Foundation
import Testing
@testable import CcinnStarRocksKit

/// Drives the real `CcinnStarRocks mcp` subprocess over stdio against the test containers.
/// Requires `swift build` first (the test uses `.build/debug/CcinnStarRocks`).
@Suite("MCP server subprocess", .enabled(if: IntegrationEnvironment.isEnabled && MCPProcess.binaryExists), .serialized)
struct MCPIntegrationTests {
    @Test(arguments: IntegrationEnvironment.targets)
    func fullSessionOverStdio(target: IntegrationEnvironment.Target) async throws {
        let process = try MCPProcess(target: target)
        defer { process.terminate() }

        let initialize = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        #expect(initialize["result"]?["serverInfo"]?["name"] == .string("ccinnstarrocks"))
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let tools = try await process.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("run_query") && names.contains("analyze_tablet_skew"))
        #expect(!names.contains("execute_statement"), "the test profile is read-only")

        let tables = try await process.call(id: 3, "list_tables", ["database": "shop"])
        let kinds = Dictionary(uniqueKeysWithValues: (tables["objects"]?.arrayValue ?? []).compactMap { object -> (String, String)? in
            guard let name = object["name"]?.stringValue, let kind = object["kind"]?.stringValue else { return nil }
            return (name, kind)
        })
        #expect(kinds["orders"] == "table")
        #expect(kinds["mv_city_daily"] == "async_materialized_view")
        #expect(kinds["mv_orders_by_channel"] == "sync_materialized_view")
        #expect(kinds["v_paid_orders"] == "view")

        let query = try await process.call(id: 4, "run_query", ["sql": "SELECT * FROM orders", "database": "shop", "limit": 25])
        #expect(query["row_count"] == .int(25))
        #expect(query["truncated"] == .bool(true))

        let rejected = try await process.request(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                                  "params": ["name": "run_query", "arguments": ["sql": "DROP TABLE shop.orders"]]])
        #expect(rejected["result"]?["isError"] == .bool(true))

        let partitions = try await process.call(id: 6, "get_partitions", ["database": "shop", "table": "orders"])
        #expect(partitions["partition_count"] == .int(13))

        let mv = try await process.call(id: 7, "get_materialized_view", ["database": "shop", "name": "mv_city_daily"])
        #expect(mv["refresh_type"] == .string("ASYNC"))

        // Cancelling a long query must stop it and produce no response for that id.
        try process.send(["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                          "params": ["name": "run_query", "arguments": ["sql": "SELECT COUNT(*) FROM TABLE(generate_series(1, 2000000000)) a", "timeout_seconds": 60]]])
        try await Task.sleep(for: .milliseconds(800))
        try process.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 8]])
        let ping = try await process.request(["jsonrpc": "2.0", "id": 9, "method": "ping"])
        #expect(ping["result"] == .object([:]))
        try await Task.sleep(for: .seconds(2))
        #expect(process.responses(for: 8).isEmpty)
    }
}

/// `$$` is a code block on StarRocks 4.1 and part of a name on 3.3, so `-- $$` hides a statement from one of them. The
/// MCP tools refuse every such text on every version, and nothing hidden runs.
@Suite("MCP and version-ambiguous $$", .serialized)
struct MCPDollarQuoteTests {
    @Test(arguments: IntegrationEnvironment.targets)
    func hiddenStatementsAreRefused(target: IntegrationEnvironment.Target) async throws {
        let process = try MCPProcess(target: target)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let hidden = [
            "SELECT 1 $$a; CREATE DATABASE ccinn_rv_ms -- $$",
            "SELECT 1 $$a INTO OUTFILE 'x' -- $$",
            "SELECT 1 $$a; ADMIN SET FRONTEND CONFIG (\"enable_udf\" = \"true\") -- $$",
        ]
        for (offset, sql) in hidden.enumerated() {
            for tool in ["run_query", "explain_query"] {
                let response = try await process.request(["jsonrpc": "2.0", "id": .int(Int64(10 + offset * 2 + (tool == "run_query" ? 0 : 1))),
                                                          "method": "tools/call", "params": ["name": .string(tool), "arguments": ["sql": .string(sql)]]])
                #expect(response["result"]?["isError"] == .bool(true), "\(tool): \(sql)")
            }
        }
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let databases = try await client.databases()
        #expect(!databases.contains("ccinn_rv_ms"), "the hidden CREATE DATABASE never ran")
    }
}

/// 1.3.1: `#` is not a comment for StarRocks over COM_QUERY and characters above U+FFFF are dropped, so up to 1.3.0 they
/// hid a second statement or an export from read-only mode. Every such text is refused, and nothing hidden runs.
@Suite("MCP and characters StarRocks drops", .serialized)
struct MCPDroppedCharacterTests {
    @Test(arguments: IntegrationEnvironment.targets)
    func hiddenStatementsAreRefused(target: IntegrationEnvironment.Target) async throws {
        let process = try MCPProcess(target: target)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let hidden = [
            "SELECT 1 # ; CREATE DATABASE ccinn_hash_rv -- ",
            "SELECT 1 # INTO OUTFILE 'nosuchscheme://ccinn/' -- ",
            "SELECT 1 # ; ADMIN SET FRONTEND CONFIG (\"enable_udf\" = \"true\")",
            "SELECT 1 LIMIT 1\u{E0020}INTO\u{E0020}OUTFILE\u{E0020}'nosuchscheme://ccinn/'",
        ]
        var id: Int64 = 10
        for sql in hidden {
            for tool in ["run_query", "explain_query"] {
                id += 1
                let response = try await process.request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                                          "params": ["name": .string(tool), "arguments": ["sql": .string(sql)]]])
                #expect(response["result"]?["isError"] == .bool(true), "\(tool): \(sql.debugDescription)")
            }
        }
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        #expect(!(try await client.databases()).contains("ccinn_hash_rv"), "the hidden CREATE DATABASE never ran")
        // The server really runs what follows `#`: the guard's refusal is not hypothetical.
        let session = client.openSession()
        let results = try await session.run("SELECT 1 AS a # ; SELECT 2 AS b")
        #expect(results.count == 2)
        await session.close()
    }
}

/// 1.3.2: read-only AI access refuses accounts with administrator privileges (roles followed transitively) on every
/// tool call, unless the connection allows it; ordinary accounts work as before.
@Suite("MCP and privileged accounts", .serialized)
struct MCPPrivilegedAccountTests {
    private func initialize(_ process: MCPProcess) async throws {
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func refusal(_ process: MCPProcess, id: Int64, _ tool: String, _ arguments: JSONValue) async throws -> String? {
        let response = try await process.request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                                  "params": ["name": .string(tool), "arguments": arguments]])
        guard response["result"]?["isError"] == .bool(true) else { return nil }
        return response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func administratorsAreRefusedAndReadersAreServed(target: IntegrationEnvironment.Target) async throws {
        let admin = try await IntegrationEnvironment.client(target)
        defer { Task { await admin.close() } }
        let suffix = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let reader = "ccinn_it_reader_\(suffix)", nested = "ccinn_it_nested_\(suffix)", wrapper = "ccinn_it_wrap_\(suffix)"
        for sql in ["CREATE USER '\(reader)'@'%'", "GRANT SELECT ON ALL TABLES IN DATABASE shop TO USER '\(reader)'@'%'",
                    "CREATE ROLE \(wrapper)", "GRANT cluster_admin TO ROLE \(wrapper)", "CREATE USER '\(nested)'@'%'",
                    "GRANT SELECT ON ALL TABLES IN DATABASE shop TO USER '\(nested)'@'%'", "GRANT \(wrapper) TO USER '\(nested)'@'%'"] {
            _ = try await admin.execute(sql)
        }
        // Awaited cleanup, on success and on failure: a detached task would be cut off when the test process exits.
        do {
            try await checkAccounts(target, reader: reader, nested: nested)
        } catch {
            for sql in ["DROP USER '\(reader)'@'%'", "DROP USER '\(nested)'@'%'", "DROP ROLE \(wrapper)"] { _ = try? await admin.execute(sql) }
            throw error
        }
        for sql in ["DROP USER '\(reader)'@'%'", "DROP USER '\(nested)'@'%'", "DROP ROLE \(wrapper)"] { _ = try? await admin.execute(sql) }
    }

    private func checkAccounts(_ target: IntegrationEnvironment.Target, reader: String, nested: String) async throws {
        // root, not allowed: every tool that touches the server is refused.
        let root = try MCPProcess(target: target, allowPrivileged: false)
        try await initialize(root)
        for (offset, call) in [("run_query", ["sql": "SELECT 1"] as JSONValue), ("list_databases", [:]), ("list_tables", ["database": "shop"])].enumerated() {
            let message = try await refusal(root, id: Int64(10 + offset), call.0, call.1)
            #expect(message?.contains("privileges") == true, "\(call.0): \(message ?? "served")")
        }
        root.terminate()

        // A role that holds cluster_admin, granted but not active, is enough to refuse.
        let wrapped = try MCPProcess(target: target, username: nested, allowPrivileged: false)
        try await initialize(wrapped)
        #expect(try await refusal(wrapped, id: 20, "run_query", ["sql": "SELECT 1"])?.contains("cluster_admin") == true)
        wrapped.terminate()

        // A reader of one database is served.
        let plain = try MCPProcess(target: target, username: reader, allowPrivileged: false)
        try await initialize(plain)
        #expect(try await refusal(plain, id: 30, "run_query", ["sql": "SELECT COUNT(*) FROM orders", "database": "shop"]) == nil)
        #expect(try await refusal(plain, id: 31, "list_tables", ["database": "shop"]) == nil)
        plain.terminate()

        // root, allowed by the user: served.
        let allowed = try MCPProcess(target: target, allowPrivileged: true)
        try await initialize(allowed)
        #expect(try await refusal(allowed, id: 40, "run_query", ["sql": "SELECT 1"]) == nil)
        allowed.terminate()
    }
}

/// 1.3.2: what AI must not read, pinned on the servers: a plain account reads the backend's files through FILES() and
/// another user's task SQL (literals included) from information_schema.tasks. MCP refuses both; get_running_tasks shows
/// running statements only as digests.
@Suite("MCP and secret-bearing sources", .serialized)
struct MCPSecretSourceTests {
    @Test(arguments: IntegrationEnvironment.targets)
    func secretsAndServerFilesStayOutOfReach(target: IntegrationEnvironment.Target) async throws {
        let admin = try await IntegrationEnvironment.client(target)
        defer { Task { await admin.close() } }
        let suffix = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let reader = "ccinn_it_secret_\(suffix)", task = "ccinn_it_task_\(suffix)", marker = "CCINNSECRET\(suffix.uppercased())"
        _ = try await admin.execute("CREATE USER '\(reader)'@'%'")
        _ = try await admin.execute("GRANT SELECT ON ALL TABLES IN DATABASE shop TO USER '\(reader)'@'%'")
        let setup = admin.openSession(database: "shop")
        _ = try await setup.run("SUBMIT TASK \(task) SCHEDULE EVERY (INTERVAL 1 DAY) AS INSERT INTO shop.orders SELECT * FROM shop.orders WHERE city = '\(marker)'")
        await setup.close()
        do {
            try await checkSecrets(target, reader: reader, task: task, marker: marker)
        } catch {
            _ = try? await admin.execute("DROP TASK \(task)")
            _ = try? await admin.execute("DROP USER '\(reader)'@'%'")
            throw error
        }
        _ = try? await admin.execute("DROP TASK \(task)")
        _ = try? await admin.execute("DROP USER '\(reader)'@'%'")
    }

    private func checkSecrets(_ target: IntegrationEnvironment.Target, reader: String, task: String, marker: String) async throws {
        // The threats are real for an ordinary account.
        let plain = try await IntegrationEnvironment.client(target, user: reader)
        defer { Task { await plain.close() } }
        let passwd = try await plain.execute("SELECT * FROM FILES('path' = 'file:///etc/passwd', 'format' = 'csv', 'csv.column_separator' = ':') LIMIT 1")
        #expect(passwd.rows.first?.first == "root", "FILES() reads the backend's files")
        let definitions = try await plain.execute("SELECT DEFINITION FROM information_schema.tasks WHERE TASK_NAME = '\(task)'")
        #expect(definitions.rows.first?.first??.contains(marker) == true, "another user's task SQL is readable")

        // Through MCP, as that same account, both are refused.
        let process = try MCPProcess(target: target, username: reader, allowPrivileged: false)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let refused = [
            "SELECT * FROM FILES('path' = 'file:///etc/passwd', 'format' = 'csv', 'csv.column_separator' = ':')",
            "SELECT DEFINITION FROM information_schema.tasks",
            "SELECT * FROM information_schema . task_runs",
            "SHOW FULL PROCESSLIST",
            "ADMIN SHOW FRONTEND CONFIG",
        ]
        var id: Int64 = 10
        for sql in refused {
            for tool in ["run_query", "explain_query"] where tool == "run_query" || sql.hasPrefix("SELECT") {
                id += 1
                let response = try await process.request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                                          "params": ["name": .string(tool), "arguments": ["sql": .string(sql), "database": "shop"]]])
                #expect(response["result"]?["isError"] == .bool(true), "\(tool): \(sql)")
                #expect(!response.serialized().contains(marker))
            }
        }
        let tables = try await process.call(id: 90, "run_query", ["sql": "SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = 'shop'"])
        #expect((tables["row_count"]?.intValue ?? 0) > 0, "ordinary metadata stays readable")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func runningStatementsAreDigests(target: IntegrationEnvironment.Target) async throws {
        let admin = try await IntegrationEnvironment.client(target)
        defer { Task { await admin.close() } }
        let marker = "CCINNSECRET\(String(UInt32.random(in: 0...UInt32.max), radix: 36).uppercased())"
        let session = admin.openSession()
        let long = Task { try await session.run("SELECT sleep(8), '\(marker)' AS token") }
        defer { long.cancel() }
        try await Task.sleep(for: .seconds(2))
        let process = try MCPProcess(target: target)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let running = try await process.call(id: 2, "get_running_tasks", [:])
        let text = running.serialized()
        #expect(!text.contains(marker), "the running statement's literal is not shown")
        #expect(text.contains("sleep(?)"), "the running statement is shown as a digest: \(text.prefix(400))")
        _ = try? await long.value
        await session.close()
    }
}

/// A running MCP server subprocess with a temporary profile directory.
final class MCPProcess: @unchecked Sendable {
    static var binary: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CcinnStarRocks")
    }

    static var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let directory: URL
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [JSONValue] = []

    /// `allowPrivileged`: the root test account is an administrator, refused by read-only AI access unless allowed.
    init(target: IntegrationEnvironment.Target, username: String = "root", allowPrivileged: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnsr-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var profile = ConnectionProfile(name: "IT \(target.label)", host: target.endpoint.host, port: target.endpoint.port, username: username,
                                        defaultDatabase: "shop", connectTimeout: 30, mcpAccess: .readOnly)
        profile.mcpAllowPrivilegedAccount = allowPrivileged
        try ProfileRepository(directory: directory, secrets: InMemorySecretStore()).save([profile])

        process.executableURL = Self.binary
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["CCINNSTARROCKS_PROFILE_DIR"] = directory.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let message = try? JSONValue.parse(Data(line)) { self.messages.append(message) }
            }
            self.lock.unlock()
        }
        try process.run()
    }

    func send(_ message: JSONValue) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((message.serialized() + "\n").utf8))
    }

    func responses(for id: Int64) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0["id"] == .int(id) }
    }

    func request(_ message: JSONValue, timeout: Duration = .seconds(90)) async throws -> JSONValue {
        try send(message)
        guard let id = message["id"]?.intValue else { return .null }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let response = responses(for: id).first { return response }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MCPToolError("No response to request \(id)")
    }

    /// Calls a tool and returns its structured result, failing the test on tool errors.
    func call(id: Int64, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let response = try await request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]])
        let result = response["result"]
        if result?["isError"] == .bool(true) {
            throw MCPToolError("\(name) failed: \(result?["content"]?[0]?["text"]?.stringValue ?? "?")")
        }
        return result?["structuredContent"] ?? .null
    }

    func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
