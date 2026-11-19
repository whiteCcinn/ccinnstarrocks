import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

private func table(_ name: String, _ columns: [String]) -> TableFacts {
    TableFacts(name: name, kind: .table, columns: columns.map { ColumnFacts(name: $0, type: "bigint", isKey: $0 == "id") }, fingerprint: "fp-" + name,
               state: .fresh, firstSeen: now)
}

private func knowledge() -> DatabaseKnowledge {
    var knowledge = DatabaseKnowledge(key: DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe:9030"), catalog: "default_catalog", database: "adx"))
    knowledge.tables = [table("report", ["id", "dsp_id"]), table("dsp", ["id"]), table("secret_salary", ["id", "dsp_id"])]
    knowledge.relationships = [
        Relationship(from: .init(table: "report", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                     evidence: [Evidence(source: .naming, score: 55, at: now)]),
        Relationship(from: .init(table: "secret_salary", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                     evidence: [Evidence(source: .naming, score: 55, at: now)]),
        Relationship(from: .init(table: "report", columns: ["dsp_id"]), to: .init(database: "admin", table: "dsp", columns: ["id"]), kind: .manyToOne,
                     evidence: [Evidence(source: .ai, at: now)]),
    ]
    knowledge.notes = [Note(id: "n-user", table: "report", column: nil, kind: .description, text: "by the user", evidence: [], by: "user", at: now, fingerprint: "fp-report"),
                       Note(id: "n-hidden", table: "secret_salary", column: nil, kind: .caveat, text: "x", evidence: [], by: "ai:codex", at: now, fingerprint: nil)]
    knowledge.terms = [Term(id: "g1", term: "salary", synonyms: [], definition: "x", mapsTo: [.init(table: "secret_salary")], by: "user", at: now),
                       Term(id: "g2", term: "ADX", synonyms: [], definition: "ad exchange", mapsTo: [], by: "user", at: now)]
    knowledge.areas = [SubjectArea(id: "a1", name: "pay", tables: ["secret_salary"], description: nil, by: "user", at: now)]
    return knowledge
}

private func provider(profiles: [ConnectionProfile], writesDisabled: Bool = false) -> StarRocksMCPTools {
    StarRocksMCPTools(resolver: MCPProfileResolver(profiles: profiles, defaultProfile: nil, forceReadOnly: false),
                      registry: MCPClientRegistry { _ in throw MCPToolError("no server in unit tests") }, audit: nil,
                      knowledge: KnowledgeToolSettings(store: KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                                                       writesDisabled: writesDisabled))
}

private func profile(knowledgeWrites: Bool = true) -> ConnectionProfile {
    var profile = ConnectionProfile(name: "prod", host: "fe", port: 9030)
    profile.mcpAccess = .readOnly
    profile.mcpKnowledgeWrites = knowledgeWrites
    return profile
}

@Suite("Knowledge MCP tools")
struct KnowledgeMCPToolListTests {
    @Test func readToolsAlwaysWriteToolsOnlyWhereAllowed() async {
        let names = Set(await provider(profiles: [profile()]).tools().map(\.name))
        #expect(names.isSuperset(of: KnowledgeMCP.readTools.union(KnowledgeMCP.writeTools)))
        let readOnly = Set(await provider(profiles: [profile(knowledgeWrites: false)]).tools().map(\.name))
        #expect(readOnly.isSuperset(of: KnowledgeMCP.readTools) && readOnly.isDisjoint(with: KnowledgeMCP.writeTools))
        let flagged = Set(await provider(profiles: [profile()], writesDisabled: true).tools().map(\.name))
        #expect(flagged.isDisjoint(with: KnowledgeMCP.writeTools), "--no-knowledge-writes")
        #expect(!names.contains { $0.contains("export") || $0.contains("import") || $0.contains("backup") }, "migration is an app action, never MCP")
    }

    @Test func promptsThroughTheServer() async throws {
        let tools = provider(profiles: [profile()])
        let sent = SentMessages()
        let server = MCPServer(info: MCPServerInfo(name: "t", title: "t", version: "1", instructions: "i"), provider: tools, send: { await sent.append($0) })
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code"}}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":2,"method":"prompts/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"build_knowledge","arguments":{"database":"adx"}}}"#)
        let messages = await sent.all
        #expect(messages[0].contains(#""prompts":{"listChanged":false}"#))
        #expect(messages[1].contains("build_knowledge") && messages[1].contains("answer_with_knowledge"))
        #expect(messages[2].contains("link_project") && messages[2].contains("`adx`"))
    }
}

private actor SentMessages {
    var all: [String] = []
    func append(_ message: String) { all.append(message) }
}

@Suite("Knowledge visibility")
struct KnowledgeVisibilityTests {
    @Test func hiddenTablesTakeEverythingAboutThemAlong() {
        let filtered = KnowledgeMCP.filter(knowledge(), visible: ["report", "dsp"])
        #expect(filtered.tables.map(\.name) == ["report", "dsp"])
        #expect(filtered.relationships.count == 1, "the salary relationship and the unseen admin database are gone")
        #expect(filtered.notes.map(\.id) == ["n-user"])
        #expect(filtered.terms.map(\.term) == ["ADX"], "a term about hidden tables only would reveal them")
        #expect(filtered.areas.isEmpty)
        let withAdmin = KnowledgeMCP.filter(knowledge(), visible: ["report", "dsp"], visibleOther: ["admin": ["dsp"]])
        #expect(withAdmin.relationships.count == 2)
    }
}

@Suite("Knowledge writes")
struct KnowledgeWriteTests {
    private func items(_ json: String) throws -> [JSONValue] {
        try #require(try JSONValue.parse(json).arrayValue)
    }

    @Test func untrustedTextIsCleaned() {
        #expect(KnowledgeMCP.clean("  a\u{0}b\u{7}\nc\td  ", limit: 100) == "ab\nc\td")
        #expect(KnowledgeMCP.clean("e\u{301}", limit: 100) == "é", "NFC")
        #expect(KnowledgeMCP.clean(String(repeating: "x", count: 50), limit: 10).count == 10)
    }

    @Test func projectPathsAreRealDirectoriesStoredRelativeToHome() throws {
        let exists = { (path: String) -> Bool in path.hasPrefix("/Users/someone/code") || path.hasPrefix("/Volumes/work") }
        #expect(try KnowledgeMCP.projectPath("/Users/someone/code/adx/", home: home, isDirectory: exists) == "~/code/adx")
        #expect(try KnowledgeMCP.projectPath("~/code/adx", home: home, isDirectory: exists) == "~/code/adx")
        #expect(try KnowledgeMCP.projectPath("/Volumes/work/adx", home: home, isDirectory: exists) == "/Volumes/work/adx")
        for refused in ["code/adx", "/", "/Users/someone", "/Users/someone/missing"] {
            #expect(throws: MCPToolError.self, "\(refused)") { try KnowledgeMCP.projectPath(refused, home: home, isDirectory: exists) }
        }
    }

    @Test func gitRemoteWithoutCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://user:ghp_secret@github.com/org/adx-server.git\n".write(
            to: directory.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        #expect(KnowledgeMCP.gitRemote(of: directory.path) == "https://github.com/org/adx-server.git")
    }

    @Test func notesNeedRealTablesAndColumns() throws {
        var target = knowledge()
        let ids = try KnowledgeMCP.addNotes(try items(#"[{"table":"report","column":"DSP_ID","kind":"caveat","text":"0 = house ads\u0000"}]"#),
                                            to: &target, by: "ai:codex", now: now, projects: [], home: home)
        let note = try #require(target.notes.first { $0.id == ids.first })
        #expect(note.column == "dsp_id" && note.text == "0 = house ads" && note.fingerprint == "fp-report" && note.by == "ai:codex")
        #expect(throws: MCPToolError.self) {
            try KnowledgeMCP.addNotes(try items(#"[{"table":"nope","kind":"usage","text":"x"}]"#), to: &target, by: "ai:x", now: now, projects: [], home: home)
        }
        #expect(throws: MCPToolError.self) {
            try KnowledgeMCP.addNotes(try items(#"[{"table":"report","column":"nope","kind":"usage","text":"x"}]"#), to: &target, by: "ai:x", now: now, projects: [], home: home)
        }
    }

    @Test func relationshipsCarryEvidenceAndMergeByID() throws {
        var target = knowledge()
        let project = KnowledgeIndex.Project(id: "p1", path: "~/code/adx", name: "adx", gitRemote: nil, addedAt: now, addedBy: "user")
        let item = #"[{"from_table":"report","from_columns":["dsp_id"],"to_table":"dsp","to_columns":["id"],"verdict":"assert","#
            + #""evidence":[{"type":"code","project_path":"/Users/someone/code/adx/internal","path":"dao.go","line":12,"symbol":"ByDSP"}]}]"#
        let ids = try KnowledgeMCP.addRelationships(try items(item), to: &target, by: "ai:claude-code", now: now, projects: [project], home: home)
        let relationship = try #require(target.relationships.first { $0.id == ids.first })
        #expect(relationship.evidence.map(\.source) == [.naming, .code], "joins the inferred record with the same ends")
        #expect(relationship.evidence.last?.project == "p1")
        _ = try KnowledgeMCP.addRelationships(try items(item), to: &target, by: "ai:claude-code", now: now, projects: [project], home: home)
        #expect(target.relationships.first { $0.id == ids.first }?.evidence.count == 2, "repeating the same evidence does not count twice")
        #expect(throws: MCPToolError.self) {
            try KnowledgeMCP.addRelationships(try items(#"[{"from_table":"report","from_columns":["dsp_id"],"to_table":"dsp","to_columns":["id"],"verdict":"assert","evidence":[]}]"#),
                                              to: &target, by: "ai:x", now: now, projects: [], home: home)
        }
        #expect(throws: MCPToolError.self) {
            try KnowledgeMCP.addRelationships(try items(#"[{"from_table":"report","from_columns":["dsp_id","id"],"to_table":"dsp","to_columns":["id"],"verdict":"assert","rationale":"x"}]"#),
                                              to: &target, by: "ai:x", now: now, projects: [], home: home)
        }
    }

    @Test func aiCannotChangeOrRemoveWhatTheUserWrote() throws {
        var target = knowledge()
        #expect(throws: MCPToolError.self) {
            try KnowledgeMCP.defineTerms(try items(#"[{"term":"ADX","definition":"changed"}]"#), in: &target, by: "ai:x", now: now)
        }
        #expect(throws: MCPToolError.self) { try KnowledgeMCP.remove(ids: ["n-user"], from: &target, by: "ai:x", now: now) }
        #expect(throws: MCPToolError.self) {
            try KnowledgeMCP.defineArea(name: "pay", tables: ["report"], description: nil, remove: false, in: &target, by: "ai:x", now: now)
        }
        let removed = try KnowledgeMCP.remove(ids: ["n-hidden"], from: &target, by: "ai:x", now: now)
        #expect(removed == ["n-hidden"] && target.tombstones.map(\.id) == ["n-hidden"])
        let inferred = target.relationships[0].id
        _ = try KnowledgeMCP.remove(ids: [inferred], from: &target, by: "ai:x", now: now)
        #expect(target.tombstones.contains { $0.id == inferred }, "a removed inferred relationship stays removed on refresh")
    }
}
