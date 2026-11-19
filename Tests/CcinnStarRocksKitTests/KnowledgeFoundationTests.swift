import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

// Phase 1 of add-database-knowledge: private atomic files, a lock shared by the app and `mcp`, table references with
// per-subquery scopes, and the profile fields knowledge and backups rely on.

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-\(UUID().uuidString)", isDirectory: true)
}

private func permissions(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite("Secure files")
struct SecureFileTests {
    @Test func filesArePrivateFromTheFirstByteAndReplacedAtomically() throws {
        let directory = temporaryDirectory().appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = directory.appendingPathComponent("index.json")
        try SecureFile.write(Data("one".utf8), to: url)
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(directory) == 0o700, "missing directories are created private")
        try SecureFile.write(Data("two".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "two")
        #expect(try permissions(url) == 0o600, "replacing keeps the file private")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "index.json" }
        #expect(leftovers.isEmpty, "no temporary files are left behind: \(leftovers)")
    }

    @Test func anExistingDirectoryIsTightened() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try SecureFile.createDirectory(directory)
        #expect(try permissions(directory) == 0o700)
    }
}

@Suite("File lock", .serialized)
struct FileLockTests {
    // Each attempt opens the lock file itself, as the app and the `mcp` process do: flock serializes them.
    @Test func concurrentWritersLoseNoUpdate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SecureFile.createDirectory(directory)
        let lock = directory.appendingPathComponent(".lock")
        let counter = directory.appendingPathComponent("counter")
        try SecureFile.write(Data("0".utf8), to: counter)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            try? FileLock.withLock(at: lock, timeout: .seconds(10)) {
                let value = Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? -1000
                try SecureFile.write(Data("\(value + 1)".utf8), to: counter)
            }
        }
        #expect(try String(contentsOf: counter, encoding: .utf8) == "40")
    }

    @Test func aHeldLockTimesOut() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SecureFile.createDirectory(directory)
        let lock = directory.appendingPathComponent(".lock")
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Thread {
            try? FileLock.withLock(at: lock, timeout: .seconds(5)) {
                held.signal()
                release.wait()
            }
        }
        holder.start()
        held.wait()
        let started = ContinuousClock.now
        #expect(throws: FileLock.Failure.busy(lock.path)) {
            try FileLock.withLock(at: lock, timeout: .milliseconds(200)) {}
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        release.signal()
    }
}

@Suite("Table references")
struct TableReferenceTests {
    private func scopes(_ sql: String) -> [SQLTableReferences.Scope] {
        let lexer = SQLLexer(sql)
        return SQLTableReferences.scopes(tokens: lexer.tokens().filter { $0.kind != .comment }, lexer: lexer)
    }

    private func names(_ scope: SQLTableReferences.Scope) -> [String] {
        scope.references.map { [$0.catalog, $0.database, $0.table].compactMap { $0 }.joined(separator: ".") + ($0.alias.map { " " + $0 } ?? "") }
    }

    @Test func eachSubqueryHasItsOwnScope() {
        let result = scopes("SELECT * FROM shop.orders o WHERE o.id IN (SELECT i.order_id FROM items i JOIN products p ON i.sku = p.sku)")
        #expect(result.count == 2)
        #expect(names(result[0]) == ["shop.orders o"])
        #expect(names(result[1]) == ["items i", "products p"])
        #expect(result[1].parent == 0)
        #expect(result[0].parent == nil)
    }

    @Test func derivedTablesAndCTEsCarryTheirColumns() {
        let result = scopes("""
        WITH top AS (SELECT city, SUM(total) AS revenue FROM orders GROUP BY city)
        SELECT * FROM top t JOIN (SELECT id AS customer_id FROM customers) c ON t.city = c.customer_id
        """)
        let outer = result[0]
        #expect(outer.references.first { $0.alias == "t" }?.derivedColumns == ["city", "revenue"])
        #expect(outer.references.first { $0.alias == "c" }?.derivedColumns == ["customer_id"])
        #expect(result.count == 3, "the CTE body and the derived table are scopes of their own")
        #expect(result.dropFirst().allSatisfy { $0.parent == 0 })
    }

    @Test func threePartNamesKeepTheCatalog() {
        let reference = scopes("select * from default_catalog.shop.orders").first?.references.first
        #expect(reference?.catalog == "default_catalog")
        #expect(reference?.database == "shop")
        #expect(reference?.table == "orders")
    }

    // Completion keeps its flat view: every table of the statement, at any depth.
    @Test func flatReferencesStillSeeEverything() {
        let lexer = SQLLexer("SELECT * FROM a WHERE x IN (SELECT y FROM b)")
        let flat = SQLTableReferences.references(tokens: lexer.tokens(), lexer: lexer)
        #expect(flat.map(\.table) == ["a", "b"])
    }
}

@Suite("Profile fields for knowledge and backups")
struct KnowledgeProfileFieldTests {
    @Test func legacyProfilesDecodeWithDefaults() throws {
        let legacy = #"{"id":"0F9C2F34-6B1C-4C55-9E77-1B8C2E0A9D11","name":"prod","host":"fe","port":9030,"username":"u","createdAt":0}"#
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(legacy.utf8))
        #expect(profile.updatedAt == nil)
        #expect(profile.mcpKnowledgeWrites == true, "AI knowledge writes default on (owner's decision)")
    }

    @Test func newFieldsRoundTrip() throws {
        var profile = ConnectionProfile(name: "prod", host: "fe", port: 9030)
        profile.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        profile.mcpKnowledgeWrites = false
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.updatedAt == profile.updatedAt)
        #expect(decoded.mcpKnowledgeWrites == false)
    }

    @Test func historyDirectoryIsSharedWithTheMCPProcess() {
        #expect(QueryHistoryStore.defaultDirectory == ProfileRepository.defaultDirectory.appendingPathComponent("History", isDirectory: true))
    }
}

@Suite("Table reference depth")
struct TableReferenceDepthTests {
    @Test func deepNestingStopsInsteadOfOverflowing() {
        let sql = String(repeating: "SELECT * FROM (", count: 5_000) + "SELECT 1" + String(repeating: ") t", count: 5_000)
        let lexer = SQLLexer(sql)
        let scopes = SQLTableReferences.scopes(tokens: lexer.tokens(), lexer: lexer)
        #expect(scopes.count == SQLTableReferences.maxScopeDepth + 1)
    }
}
