import Foundation
import os
import Testing
@testable import CcinnStarRocksKit
import StarRocksKit

// MARK: - JSON and framing

@Suite("MCP JSON and framing")
struct MCPJSONTests {
    @Test func parsesAndSerializesOnOneLine() throws {
        let value = try JSONValue.parse(#"{"a":[1,2.5,"x\ny",true,null],"b":{"c":"é🙂"}}"#)
        #expect(value["a"]?[0] == .int(1))
        #expect(value["a"]?[1] == .double(2.5))
        #expect(value["a"]?[3] == .bool(true))
        #expect(value["a"]?[4] == .null)
        let text = value.serialized()
        #expect(!text.contains("\n"))
        #expect(try JSONValue.parse(text) == value)
    }

    @Test func escapesControlCharactersAndQuotes() {
        let text = JSONValue.string("a\"b\\c\u{01}\t").serialized()
        #expect(text == #""a\"b\\c\u0001\t""#)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: (any Error).self) { try JSONValue.parse("{nope") }
    }

    @Test func framerSplitsLinesAndBoundsLength() {
        var framer = LineFramer(maxLineBytes: 16)
        #expect(framer.append(Array("{\"a\":1}\n{\"b\"".utf8)) == [.line("{\"a\":1}")])
        #expect(framer.append(Array(":2}\r\n".utf8)) == [.line("{\"b\":2}")])
        // An oversized line is reported once and skipped up to the next newline.
        #expect(framer.append(Array(String(repeating: "x", count: 40).utf8)) == [.oversized])
        #expect(framer.append(Array("yyy\n{}\n".utf8)) == [.line("{}")])
        #expect(framer.append(Array("\n\n".utf8)).isEmpty)
    }
}

// MARK: - Protocol

private actor Transcript {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func messages() -> [JSONValue] { lines.compactMap { try? JSONValue.parse($0) } }
}

private struct FakeTools: MCPToolProvider {
    let calls = OSAllocatedUnfairLock(initialState: 0)

    func tools() async -> [MCPTool] {
        [MCPTool(name: "echo", title: "Echo", description: "Echoes", inputSchema: .object(["type": "object"]), readOnly: true),
         MCPTool(name: "slow", title: "Slow", description: "Sleeps", inputSchema: .object(["type": "object"]), readOnly: true)]
    }

    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        calls.withLock { $0 += 1 }
        switch name {
        case "echo": return .success(.object(["echo": arguments["text"] ?? .null]))
        case "slow":
            do {
                try await Task.sleep(for: .seconds(30))
                return .success(.string("done"))
            } catch {
                return .failure("cancelled")
            }
        default: return .failure("Unknown tool \(name)")
        }
    }
}

@Suite("MCP protocol")
struct MCPServerTests {
    private func makeServer() -> (MCPServer, Transcript) {
        let transcript = Transcript()
        let server = MCPServer(info: MCPServerInfo(name: "test", title: "Test", version: "1.0.0", instructions: "Test server"),
                               provider: FakeTools(), send: { await transcript.append($0) })
        return (server, transcript)
    }

    @Test func negotiatesKnownAndUnknownVersions() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":"two","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["id"] == .int(1))
        #expect(messages[0]["result"]?["protocolVersion"] == .string("2025-03-26"))
        #expect(messages[0]["result"]?["capabilities"]?["tools"] != nil)
        #expect(messages[0]["result"]?["serverInfo"]?["name"] == .string("test"))
        #expect(messages[1]["id"] == .string("two"))
        #expect(messages[1]["result"]?["protocolVersion"] == .string(MCPServer.latestProtocolVersion))
    }

    @Test func listsAndCallsTools() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        await server.waitForIdle()
        let messages = await transcript.messages()
        #expect(messages.count == 3, "notifications get no response")
        let tools = messages[1]["result"]?["tools"]
        #expect(tools?[0]?["name"] == .string("echo"))
        #expect(tools?[0]?["annotations"]?["readOnlyHint"] == .bool(true))
        let call = messages[2]["result"]
        #expect(call?["isError"] == .bool(false))
        #expect(call?["structuredContent"]?["echo"] == .string("hi"))
        let text = call?["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(try JSONValue.parse(text)["echo"] == .string("hi"))
    }

    @Test func toolFailuresAreResultsNotErrors() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"missing"}}"#)
        await server.waitForIdle()
        let message = try #require(await transcript.messages().first)
        #expect(message["result"]?["isError"] == .bool(true))
        #expect(message["error"] == nil)
    }

    @Test func protocolErrors() async throws {
        let (server, transcript) = makeServer()
        await server.receive("{not json")
        await server.receive(#"{"jsonrpc":"2.0","id":7,"method":"no/such"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"arguments":{}}}"#)
        await server.receive(#"[{"jsonrpc":"2.0","id":9,"method":"ping"}]"#)
        await server.receive(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":11,"method":"resources/list"}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["error"]?["code"] == .int(-32700))
        #expect(messages[0]["id"] == .null)
        #expect(messages[1]["error"]?["code"] == .int(-32601))
        #expect(messages[2]["error"]?["code"] == .int(-32602))
        #expect(messages[3]["error"]?["code"] == .int(-32600))
        #expect(messages[4]["result"] == .object([:]))
        #expect(messages[5]["result"]?["resources"] == .array([]))
    }

    @Test func cancelledCallsGetNoResponse() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#)
        try await Task.sleep(for: .milliseconds(50))
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"user"}}"#)
        await server.waitForIdle()
        #expect(await transcript.messages().isEmpty)
    }
}

// MARK: - Read-only guard

@Suite("Read-only SQL guard")
struct ReadOnlySQLGuardTests {
    @Test(arguments: [
        "SELECT 1", "  select * from shop.orders -- comment", "WITH a AS (SELECT 1) SELECT * FROM a", "show partitions from shop.orders",
        "DESC shop.orders", "explain costs select * from t", "ADMIN SHOW REPLICA DISTRIBUTION FROM shop.orders", "(SELECT 1) UNION (SELECT 2)",
        "SELECT 'DELETE FROM t'", "select `insert` from t",
    ])
    func allowsReads(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    @Test(arguments: [
        "DELETE FROM t", "insert into t values (1)", "SELECT 1; DROP TABLE t", "UPDATE t SET a = 1", "SET global x = 1",
        "WITH a AS (SELECT 1) INSERT INTO t SELECT * FROM a", "SELECT * FROM t INTO OUTFILE 's3://bucket/x'",
        "EXPLAIN ANALYZE INSERT INTO t SELECT 1", "ADMIN SET FRONTEND CONFIG ('a' = 'b')", "KILL 5", "", "  -- only a comment",
        "REFRESH MATERIALIZED VIEW mv", "SUBMIT TASK AS INSERT INTO t SELECT 1", "CREATE TABLE t (a int)", "USE shop",
    ])
    func rejectsEverythingElse(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }
}

// MARK: - Profiles and results

@Suite("MCP profiles and results")
struct MCPProfileTests {
    private static let profiles = [
        ConnectionProfile(name: "Prod", host: "prod", mcpAccess: .readOnly),
        ConnectionProfile(name: "Dev", host: "dev", mcpAccess: .readWrite),
        ConnectionProfile(name: "Secret", host: "secret"),
    ]

    @Test func legacyProfilesDecodeWithMCPDisabled() throws {
        let json = #"[{"id":"7B0A9E6C-3C3A-4B8E-9C5B-1D6F2E0A4A11","name":"Old","color":"none","isFavorite":false,"host":"h","port":9030,"username":"root","allowCleartextPassword":false,"confirmMutations":false,"connectTimeout":10,"createdAt":0}]"#
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
        #expect(decoded.first?.mcpAccess == .disabled)
        #expect(decoded.first?.name == "Old")
    }

    @Test func resolvesExplicitDefaultAndSingleProfile() throws {
        let resolver = MCPProfileResolver(profiles: Self.profiles, defaultProfile: nil, forceReadOnly: false)
        #expect(try resolver.resolve("prod").profile.name == "Prod")
        #expect(try resolver.resolve(Self.profiles[1].id.uuidString).access == .readWrite)
        #expect(throws: MCPToolError.self) { try resolver.resolve(nil) } // two enabled → ambiguous
        #expect(throws: MCPToolError.self) { try resolver.resolve("Secret") } // disabled
        #expect(throws: MCPToolError.self) { try resolver.resolve("nope") }
        #expect(resolver.enabledProfiles.map(\.name) == ["Dev", "Prod"])

        let withDefault = MCPProfileResolver(profiles: Self.profiles, defaultProfile: "Dev", forceReadOnly: true)
        let resolved = try withDefault.resolve(nil)
        #expect(resolved.profile.name == "Dev")
        #expect(resolved.access == .readOnly, "--read-only caps write access")
        #expect(!withDefault.anyWritable)

        let single = MCPProfileResolver(profiles: [Self.profiles[0], Self.profiles[2]], defaultProfile: nil, forceReadOnly: false)
        #expect(try single.resolve(nil).profile.name == "Prod")
    }

    @Test func encodesRowsWithTypesAndTruncatesBySize() {
        let columns = [ColumnInfoLite(name: "id", kind: .integer), ColumnInfoLite(name: "total", kind: .decimal), ColumnInfoLite(name: "city", kind: .text)]
        let rows: [[String?]] = (0..<5_000).map { [String($0), "12.50", String(repeating: "k", count: 100)] }
        let encoded = MCPResultEncoder.rows(columns: columns, rows: rows, truncatedByServer: false, maxBytes: 64 * 1024)
        #expect(encoded["truncated"] == .bool(true))
        let returned = encoded["rows"]?.arrayValue ?? []
        #expect(returned.count < 5_000 && !returned.isEmpty)
        #expect(returned.first?[0] == .int(0))
        #expect(returned.first?[1] == .string("12.50"), "decimals stay exact strings")
        #expect(encoded.serialized().utf8.count <= 64 * 1024 + 512)
    }
}
