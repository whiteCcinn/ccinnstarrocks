import Foundation
import Testing
@testable import CcinnStarRocksKit
@testable import StarRocksKit

/// Real StarRocks error messages are located on the text the user wrote.
@Suite("Error diagnostics integration", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct DiagnosticsIntegrationTests {
    /// (statement as written, text expected to be marked)
    static let cases: [(String, String)] = [
        ("SELECT 1 FORM shop.orders", "shop"),
        ("SELECT '🇲🇾', 1 FORM shop.orders", "shop"),
        ("SELECT abs(1,2,3) FROM shop.orders", "abs(1,2,3)"),
        ("SELECT o.x FROM shop.orders o", "o.x"),
        ("SELECT\n  order_id,\n  nosuch\nFROM shop.orders", "nosuch"),
        ("SELECT * FROM shop.nosuch_table", "shop.nosuch_table"),
        ("SELECT `nosuch col` FROM shop.orders", "`nosuch col`"),
        ("SELECT 1 FROM shop.orders WHERE (1 = 1", "(1 = 1"),
        ("SELECT order_id, count(*) FROM shop.orders", "order_id"),
        ("SELECT * FROM nosuchdb.t", "nosuchdb"),
        // Review #1: StarRocks groups digits (`column 1,214`, `line 1,501`).
        ("SELECT " + String(repeating: " ", count: 1200) + "1 FORM shop.orders", "shop"),
        ("SELECT 1" + String(repeating: "\n", count: 1500) + "FORM shop.orders", "shop"),
        ("SELECT " + String(repeating: " ", count: 1200) + "abs(1,2,3) FROM shop.orders", "abs(1,2,3)"),
        // Review #4: an unterminated comment is a syntax error at the comment.
        ("SELECT 1 /* x", "/*"),
        ("SELECT * FROM shop.orders /* note", "/*"),
    ]

    private func failure(_ client: StarRocksClient, _ sql: String) async -> String? {
        do {
            _ = try await client.execute(sql)
            return nil
        } catch let error as StarRocksError {
            return error.message
        } catch {
            return nil
        }
    }

    private func marked(_ text: String, _ range: Range<Int>?) -> String? {
        guard let range else { return nil }
        return String(decoding: Array(text.utf16)[range], as: UTF16.self)
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func locatesRealErrors(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        for (sql, expected) in Self.cases {
            let message = try #require(await failure(client, sql), "\(sql) should fail")
            #expect(marked(sql, SQLErrorLocator.range(in: sql, message: message)) == expected, "\(sql.prefix(60)) → \(message)")
        }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func mapsExplainAndAutoLimitBack(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }

        let source = "SELECT 1 FORM shop.orders"
        let prefix = "EXPLAIN COSTS "
        let explained = try #require(await failure(client, prefix + source))
        let mapping = SQLExecutedTextMapping(prefixLength: prefix.utf16.count)
        #expect(marked(source, SQLErrorLocator.range(in: source, executed: prefix + source, mapping: mapping,
                                                     error: SQLServerError.parse(explained))) == "shop")

        // The LIMIT lands right after WHERE, where the server reports the error.
        let unfinished = "SELECT 1 FROM shop.orders WHERE -- todo"
        let limited = AutoLimit.apply(to: unfinished, limit: 10)
        let message = try #require(await failure(client, limited.sql))
        #expect(marked(unfinished, SQLErrorLocator.range(in: unfinished, executed: limited.sql,
                                                         mapping: SQLExecutedTextMapping(insertion: limited.insertion),
                                                         error: SQLServerError.parse(message))) == "WHERE")
    }
}
