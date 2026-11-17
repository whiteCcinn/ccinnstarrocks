import CcinnStarRocksKit
import Foundation
import Testing
@testable import CcinnStarRocks

@MainActor
private final class Applied {
    var edits: [SQLFormatEdit?] = []
}

@Suite("Format SQL runs", .serialized)
@MainActor
struct SQLFormatRunsTests {
    nonisolated private static let edit = SQLFormatEdit(range: NSRange(location: 0, length: 8), replacement: "SELECT 1")

    /// Slow enough for the test to act while the run is in flight.
    nonisolated private static func slowWork() -> SQLFormatEdit? {
        Thread.sleep(forTimeInterval: 0.3)
        return edit
    }

    private func waitUntilIdle(_ runs: SQLFormatRuns) async throws {
        for _ in 0..<100 where runs.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Second review (5): re-assigning the same text (a deferred report of pending edits) is not an edit; it neither
    /// cancels a running format nor reports one as skipped.
    @Test func reassigningTheSameTextKeepsTheRun() async throws {
        let runs = SQLFormatRuns()
        let applied = Applied()
        runs.start({ Self.slowWork() }, apply: { applied.edits.append($0) })
        runs.textChanged(from: "select 1", to: "select 1")
        #expect(runs.isRunning)
        #expect(runs.notice == nil)
        try await waitUntilIdle(runs)
        #expect(applied.edits == [Self.edit])
    }

    @Test func aRealEditCancelsTheRunAndSaysSo() async throws {
        let runs = SQLFormatRuns()
        let applied = Applied()
        runs.start({ Self.slowWork() }, apply: { applied.edits.append($0) })
        runs.textChanged(from: "select 1", to: "select 12")
        #expect(!runs.isRunning)
        #expect(runs.notice == "Format SQL skipped: the text changed")
        try await Task.sleep(for: .milliseconds(500))
        #expect(applied.edits.isEmpty, "a cancelled run never applies")
    }

    @Test func aNewerRunReplacesTheOlderOne() async throws {
        let runs = SQLFormatRuns()
        let applied = Applied()
        runs.start({ Self.slowWork() }, apply: { _ in applied.edits.append(nil) })
        runs.start({ Self.edit }, apply: { applied.edits.append($0) })
        try await Task.sleep(for: .milliseconds(500))
        #expect(applied.edits == [Self.edit], "only the newer run applies")
        #expect(runs.notice == nil)
    }
}
