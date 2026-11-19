import Foundation
import MySQLWire
import Testing
@testable import CcinnStarRocksKit
import StarRocksKit

private func column(_ name: String, _ type: ColumnType) -> ColumnDefinition {
    ColumnDefinition(name: name, type: type)
}

@Suite("Profiles")
struct ProfileTests {
    @Test func secretsNeverReachTheProfileFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnsr-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let repository = ProfileRepository(directory: directory, secrets: secrets)
        var profile = ConnectionProfile(name: "Prod", host: "fe.example.com", username: "analyst")
        profile.ssh = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: .password)
        try repository.storeSecrets(for: profile, password: "p@ss-w0rd-Σ", sshSecret: "ssh-secret-value")
        try repository.save([profile])

        let file = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!file.contains("p@ss-w0rd"))
        #expect(!file.contains("ssh-secret-value"))
        #expect(try repository.load() == [profile])
        #expect(repository.password(for: profile) == "p@ss-w0rd-Σ")
        #expect(repository.sshSecret(for: profile) == "ssh-secret-value")

        try repository.delete(profile)
        #expect(repository.password(for: profile) == nil)
    }

    @Test func configurationAndValidation() {
        var profile = ConnectionProfile(host: " 10.0.0.5 ", port: 9030, username: "root", defaultDatabase: " ", defaultCatalog: "hive")
        let configuration = profile.configuration(password: "x")
        #expect(configuration.endpoint == Endpoint(host: "10.0.0.5", port: 9030))
        #expect(configuration.database == nil)
        #expect(configuration.catalog == "hive")
        #expect(profile.validationErrors.isEmpty)
        profile.port = 0
        profile.host = ""
        #expect(profile.validationErrors.count == 2)
    }
}

@Suite("Charts")
struct ChartTests {
    @Test func timeSeriesBecomesLine() throws {
        let columns = [column("day", .date), column("revenue", .newDecimal)]
        let rows: [[String?]] = [["2024-01-02", "20.5"], ["2024-01-01", "10"]]
        let spec = try #require(ChartSuggester.suggest(columns: columns, rows: rows))
        #expect(spec.kind == .line)
        #expect(spec.xColumn == 0)
        #expect(spec.yColumns == [1])
        let data = ChartDataBuilder.build(columns: columns, rows: rows, spec: spec, roles: ChartSuggester.roles(columns: columns, rows: rows))
        #expect(data.points.map(\.y) == [10, 20.5], "sorted by time")
        #expect(data.xRole == .temporal)
    }

    @Test func textAndNumberBecomesBar() throws {
        let columns = [column("city", .varString), column("orders", .longLong)]
        let spec = try #require(ChartSuggester.suggest(columns: columns, rows: [["Penang", "3"]]))
        #expect(spec.kind == .bar)
        #expect(spec.seriesColumn == nil)
    }

    @Test func twoTextColumnsAndNumberBecomesGroupedBar() throws {
        let columns = [column("city", .varString), column("channel", .varString), column("orders", .longLong)]
        let spec = try #require(ChartSuggester.suggest(columns: columns, rows: [["Penang", "web", "3"]]))
        #expect(spec.kind == .bar)
        #expect(spec.xColumn == 0)
        #expect(spec.seriesColumn == 1)
    }

    @Test func twoNumbersBecomePoints() throws {
        let columns = [column("qty", .long), column("total", .double)]
        let spec = try #require(ChartSuggester.suggest(columns: columns, rows: [["1", "2"]]))
        #expect(spec.kind == .point)
    }

    @Test func textColumnsThatLookLikeDatesOrNumbersAreDetected() {
        let columns = [column("d", .varString), column("big", .varString), column("name", .varString)]
        let roles = ChartSuggester.roles(columns: columns, rows: [["2024-05-01 10:00:00", "170141183460469231731687303715884105727", "x"]])
        #expect(roles == [.temporal, .numeric, .categorical])
        #expect(ChartSuggester.suggest(columns: [column("name", .varString)], rows: [["a"]]) == nil)
    }

    @Test func duplicatesAreAggregated() {
        let columns = [column("city", .varString), column("total", .double)]
        let rows: [[String?]] = [["A", "1"], ["B", "2"], ["A", "3"], ["A", nil]]
        let roles = ChartSuggester.roles(columns: columns, rows: rows)
        let sum = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .bar, xColumn: 0, yColumns: [1]), roles: roles)
        #expect(sum.points.map(\.y) == [4, 2])
        #expect(sum.skippedRows == 1)
        let average = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .bar, xColumn: 0, yColumns: [1], aggregation: .average), roles: roles)
        #expect(average.points.map(\.y) == [2, 2])
        let count = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .bar, xColumn: 0, yColumns: [1], aggregation: .count), roles: roles)
        #expect(count.points.map(\.y) == [3, 1])
    }

    @Test func switchingToPieGivesOneSectorPerCategory() {
        let columns = [column("city", .varString), column("orders", .longLong)]
        let rows: [[String?]] = [["Penang", "3"], ["Ipoh", "5"], ["Johor", "0"]]
        let data = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .pie, xColumn: 0, yColumns: [1]),
                                          roles: ChartSuggester.roles(columns: columns, rows: rows))
        #expect(data.points.map(\.x.label) == ["Penang", "Ipoh"], "non-positive sectors are dropped")
    }

    @Test func seriesSplitAndCap() {
        let columns = [column("day", .date), column("city", .varString), column("orders", .longLong)]
        var rows: [[String?]] = []
        for city in 0..<20 { rows.append(["2024-01-01", "city\(city)", String(city + 1)]) }
        let data = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .line, xColumn: 0, yColumns: [2], seriesColumn: 1),
                                          roles: ChartSuggester.roles(columns: columns, rows: rows))
        #expect(data.series.count == ChartDataBuilder.maxSeries)
        #expect(data.series.last == "Other")
        #expect(data.notice != nil)
    }

    @Test func largeResultsAreReducedToTheBudget() {
        let columns = [column("ts", .datetime), column("value", .double)]
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let rows: [[String?]] = (0..<50_000).map { index in
            let stamp = formatter.string(from: start.addingTimeInterval(Double(index) * 60)).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
            return [stamp, "1"]
        }
        let roles = ChartSuggester.roles(columns: columns, rows: rows)
        let data = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .line, xColumn: 0, yColumns: [1]), roles: roles)
        #expect(data.points.count <= 2_000)
        #expect(data.points.reduce(0) { $0 + $1.y } == 50_000, "bucketing with sum preserves the total")
        #expect(data.notice?.contains("50,000") == true || data.notice?.contains("50000") == true)

        let categories = (0..<5_000).map { ["c\($0)", String($0)] as [String?] }
        let bar = ChartDataBuilder.build(columns: [column("c", .varString), column("v", .long)], rows: categories,
                                         spec: ChartSpec(kind: .bar, xColumn: 0, yColumns: [1]), roles: [.categorical, .numeric])
        #expect(bar.points.count <= 2_000)
        let labels = Set(bar.points.map(\.x.label))
        #expect(labels.contains("c4999") && !labels.contains("c0"), "largest categories are kept, in result order")
    }

    @Test func invalidSpecsYieldEmptyData() {
        let data = ChartDataBuilder.build(columns: [column("a", .long)], rows: [["1"]], spec: ChartSpec(kind: .bar, xColumn: 5, yColumns: [9]), roles: [.numeric])
        #expect(data.points.isEmpty)
    }
}

@Suite("Export, skew and history")
struct ExportSkewHistoryTests {
    @Test func csvEscapesAndNeutralizesFormulas() {
        let columns = [column("name", .varString), column("delta", .longLong), column("note", .varString)]
        let rows: [[String?]] = [["=HYPERLINK(\"x\")", "-5", "a,b"], [nil, "3", "line\nbreak"]]
        let csv = ResultExport.csv(columns: columns, rows: rows)
        #expect(csv == "name,delta,note\r\n\"'=HYPERLINK(\"\"x\"\")\",-5,\"a,b\"\r\n,3,\"line\nbreak\"\r\n")
    }

    @Test func csvFileMatchesInMemoryRendering() throws {
        let columns = [column("n", .longLong), column("s", .varString)]
        let rows: [[String?]] = (0..<30_000).map { [String($0), "value \($0), with comma"] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnsr-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try ResultExport.writeCSV(to: url, columns: columns, rows: rows)
        #expect(try String(contentsOf: url, encoding: .utf8) == ResultExport.csv(columns: columns, rows: rows))
    }

    @Test func tsvAndInserts() {
        let columns = [column("id", .longLong), column("city", .varString)]
        let rows: [[String?]] = [["1", "Kuala\tLumpur"], ["2", nil]]
        #expect(ResultExport.tsv(columns: columns, rows: rows) == "id\tcity\n1\tKuala Lumpur\n2\t")
        #expect(ResultExport.insertStatements(table: "`t`", columns: columns, rows: [["1", "O'Neil"]]) == "INSERT INTO `t` (`id`, `city`) VALUES (1, 'O''Neil');")
    }

    @Test func detectsSkewedTablets() {
        let tablets = [
            TabletReplica(tabletID: "1", dataSize: 100, rowCount: 10),
            TabletReplica(tabletID: "2", dataSize: 100, rowCount: 10),
            TabletReplica(tabletID: "3", dataSize: 100, rowCount: 10),
            TabletReplica(tabletID: "4", dataSize: 500, rowCount: 50),
            TabletReplica(tabletID: "4", replicaID: "2", backendID: "2", dataSize: 500, rowCount: 50),
        ]
        let report = SkewAnalyzer.analyze(tablets)
        #expect(report.entries.count == 4, "replicas are folded into one entry per tablet")
        #expect(report.skewedCount == 1)
        #expect(report.entries.first { $0.isSkewed }?.tabletID == "4")
        #expect(report.maxRatio == 2.5)
        #expect(report.metric == .dataSize)
    }

    @Test func skewFallsBackToRowsAndHandlesEmptyInput() {
        let rowsOnly = SkewAnalyzer.analyze([TabletReplica(tabletID: "1", dataSize: 0, rowCount: 10), TabletReplica(tabletID: "2", dataSize: 0, rowCount: 10)])
        #expect(rowsOnly.metric == .rowCount)
        #expect(!rowsOnly.isSkewed)
        let empty = SkewAnalyzer.analyze([])
        #expect(empty.entries.isEmpty)
        #expect(!empty.isSkewed)
    }

    @Test func historyIsBoundedSearchableAndPersistent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnsr-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = UUID()
        let store = QueryHistoryStore(directory: directory, profileID: profile, maxEntries: 3)
        for index in 0..<5 {
            await store.append(QueryHistoryEntry(sql: "SELECT \(index) FROM orders", database: "shop", durationMilliseconds: 12))
        }
        await store.append(QueryHistoryEntry(sql: "SELECT 4 FROM orders", database: "shop", durationMilliseconds: 5))
        let all = await store.all()
        #expect(all.map(\.sql) == ["SELECT 4 FROM orders", "SELECT 3 FROM orders", "SELECT 2 FROM orders"])
        #expect(await store.search("3 from").count == 1)

        let reopened = QueryHistoryStore(directory: directory, profileID: profile)
        #expect(await reopened.all().count == 3)
        await reopened.clear()
        #expect(await QueryHistoryStore(directory: directory, profileID: profile).all().isEmpty)
    }

    // An import (or a second window on the same connection) rewrites the file while a window holds its copy: the
    // window's next query must add to what is on disk, not put its stale copy back.
    @Test func historyWrittenElsewhereIsKeptByTheNextAppend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnsr-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = UUID()
        let window = QueryHistoryStore(directory: directory, profileID: profile)
        await window.append(QueryHistoryEntry(sql: "SELECT 1", database: nil, durationMilliseconds: 1))
        #expect(await window.all().count == 1, "the window has its copy cached")

        let other = QueryHistoryStore(directory: directory, profileID: profile)
        await other.append(QueryHistoryEntry(sql: "SELECT 2", database: nil, durationMilliseconds: 1))
        #expect(await window.all().map(\.sql) == ["SELECT 2", "SELECT 1"], "reading sees the other writer")

        await window.append(QueryHistoryEntry(sql: "SELECT 3", database: nil, durationMilliseconds: 1))
        #expect(await QueryHistoryStore(directory: directory, profileID: profile).all().map(\.sql) == ["SELECT 3", "SELECT 2", "SELECT 1"])
        let mode = try (FileManager.default.attributesOfItem(atPath: window.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }
}
