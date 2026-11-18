import Foundation
import MySQLWire
import Testing
@testable import StarRocksKit

@Suite("Connection pool")
struct PoolTests {
    private static func makePool(size: Int, counter: Counter) -> ConnectionPool {
        ConnectionPool(maxSize: size) {
            let id = counter.next()
            let server = FakeMySQLServer(connectionID: id) { _ in .packets(FakeMySQLServer.resultSet([("id", .longLong)], [[String(id)]])) }
            let config = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "u")
            return try await MySQLConnection.connect(config) { _, _ in server }
        }
    }

    @Test func reusesIdleConnectionsAndRespectsTheBound() async throws {
        let counter = Counter()
        let pool = Self.makePool(size: 2, counter: counter)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try await pool.withConnection { try await $0.execute("SELECT id") }
                }
            }
            try await group.waitForAll()
        }
        let stats = await pool.statistics
        #expect(stats.open <= 2)
        #expect(counter.value <= 2)
        #expect(stats.waiting == 0)
    }

    @Test func brokenConnectionsAreReplaced() async throws {
        let counter = Counter()
        let pool = Self.makePool(size: 1, counter: counter)
        let first = try await pool.checkout()
        first.forceClose()
        _ = try? await first.execute("SELECT id")
        await pool.checkin(first)
        let second = try await pool.checkout()
        #expect(second.connectionID != first.connectionID)
        await pool.checkin(second)
        #expect(await pool.statistics.open == 1)
    }

    @Test func closingFailsWaiters() async throws {
        let pool = Self.makePool(size: 1, counter: Counter())
        let held = try await pool.checkout()
        let waiter = Task { try await pool.checkout() }
        try await Task.sleep(for: .milliseconds(50))
        await pool.close()
        await #expect(throws: StarRocksError.self) { _ = try await waiter.value }
        await pool.checkin(held)
        #expect(await pool.statistics.open == 0)
    }

    @Test func cancelledWaiterLeavesNoTrace() async throws {
        let pool = Self.makePool(size: 1, counter: Counter())
        let held = try await pool.checkout()
        let waiter = Task { try await pool.checkout() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: StarRocksError.self) { _ = try await waiter.value }
        #expect(await pool.statistics.waiting == 0)
        await pool.checkin(held)
    }
}

final class Counter: Sendable {
    private let storage = OSAllocatedUnfairLockBox()
    func next() -> UInt32 { storage.increment() }
    var value: UInt32 { storage.current }
}

import os
final class OSAllocatedUnfairLockBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: UInt32(0))
    func increment() -> UInt32 { lock.withLock { $0 += 1; return $0 } }
    var current: UInt32 { lock.withLock { $0 } }
}

@Suite("Text helpers")
struct TextHelperTests {
    @Test func quotesIdentifiersAndLiterals() {
        #expect(SQLText.quoteIdentifier("a`b") == "`a``b`")
        #expect(SQLText.qualified("default_catalog", "shop", nil, "orders") == "`default_catalog`.`shop`.`orders`")
        #expect(SQLText.literal("it's \\ ok") == "'it''s \\\\ ok'")
    }

    /// 1.3.2 review: with `sql_dialect = trino` (the account's or the cluster's) a `\'` escape ends the string, so a quote
    /// in a name from the AI or from server metadata broke out of the app's own statements. A doubled quote ends nothing
    /// in either dialect; backslash escapes read as two characters under trino (a wrong value at worst, never a way out).
    /// NUL never goes out raw (and names holding one are refused before this: on connect and by the AI tools).
    @Test(arguments: [
        ("x'", "'x'''"), ("x\\", "'x\\\\'"), ("\\'", "'\\\\'''"),
        ("x\\' UNION SELECT 'i' --", "'x\\\\'' UNION SELECT ''i'' --'"),
        ("a\0b", "'a\\0b'"), ("line\nbreak\r\u{1A}", "'line\\nbreak\\r\\Z'"), ("plain", "'plain'"),
    ])
    func literalsAreSafeInBothDialects(value: String, expected: String) {
        let literal = SQLText.literal(value)
        #expect(literal == expected)
        #expect(!literal.contains("\0"), "never a raw NUL")
        #expect(Self.trinoStringEnd(literal) == literal.utf16.count, "trino reads one string: \(literal)")
        #expect(Self.starRocksStringEnd(literal) == literal.utf16.count, "StarRocks reads one string: \(literal)")
    }

    /// Every value, however it mixes quotes, backslashes and control characters, is one string in both dialects.
    @Test func noValueBreaksOutOfALiteral() {
        let pieces: [String] = ["'", "\\", "''", "\\'", "x", " ", "\0", "\n", "\r", "\u{1A}", "\"", "--", "吉"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...12, using: &generator)
            let value: String = (0..<count).map { _ in pieces.randomElement(using: &generator) ?? "" }.joined()
            let literal = SQLText.literal(value)
            #expect(Self.trinoStringEnd(literal) == literal.utf16.count, "\(value.debugDescription) → \(literal)")
            #expect(Self.starRocksStringEnd(literal) == literal.utf16.count, "\(value.debugDescription) → \(literal)")
        }
    }

    /// Where the string literal starting `text` ends (UTF-16 offset after its closing quote) when only a doubled quote
    /// escapes, as in trino; `nil` when unterminated.
    static func trinoStringEnd(_ text: String) -> Int? {
        let units = Array(text.utf16)
        guard units.first == 0x27 else { return nil }
        var index = 1
        while index < units.count {
            if units[index] == 0x27 {
                if index + 1 < units.count, units[index + 1] == 0x27 {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return nil
    }

    /// The same with MySQL escapes as well (a backslash escapes the next character), as StarRocks reads strings.
    static func starRocksStringEnd(_ text: String) -> Int? {
        let units = Array(text.utf16)
        guard units.first == 0x27 else { return nil }
        var index = 1
        while index < units.count {
            if units[index] == 0x5C {
                index += 2
                continue
            }
            if units[index] == 0x27 {
                if index + 1 < units.count, units[index + 1] == 0x27 {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return nil
    }

    @Test func recognisesContextChanges() {
        #expect(SessionContextChange.parse("use shop;") == .use(catalog: nil, database: "shop"))
        #expect(SessionContextChange.parse("USE `hive_cat`.`my db`") == .use(catalog: "hive_cat", database: "my db"))
        #expect(SessionContextChange.parse("set catalog iceberg") == .setCatalog("iceberg"))
        #expect(SessionContextChange.parse("select 1") == nil)
        #expect(SessionContextChange.parse("use a b") == nil)
    }

    @Test func parsesVersions() throws {
        let version = try #require(StarRocksVersion("3.3.22-753696f"))
        #expect(version.major == 3 && version.minor == 3 && version.patch == 22)
        #expect(try #require(StarRocksVersion("v4.1.7-ee")) > version)
        #expect(StarRocksVersion("unknown") == nil)
    }

    @Test func decodesTypedValues() throws {
        #expect(TextValue.double("12.50") == 12.5)
        #expect(TextValue.double("-1e3") == -1000)
        #expect(TextValue.double("abc") == nil)
        #expect(TextValue.double("nan") == nil)
        let date = try #require(TextValue.dateTime("2024-02-29"))
        #expect(date.timeIntervalSince1970 == 1_709_164_800)
        let dateTime = try #require(TextValue.dateTime("2024-02-29 13:45:30.250"))
        #expect(dateTime.timeIntervalSince1970 == 1_709_214_330.25)
        #expect(TextValue.dateTime("2024-13-01") == nil)
        #expect(TextValue.dateTime("2024-01-01 25:00:00") == nil)
        #expect(TextValue.dateTime("hello") == nil)
    }
}
