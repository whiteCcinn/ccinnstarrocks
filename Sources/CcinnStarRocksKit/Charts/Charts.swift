import Foundation
import MySQLWire
import StarRocksKit

public enum ChartKind: String, CaseIterable, Sendable, Identifiable, Hashable {
    case bar, line, area, point, pie

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bar: "Bar"
        case .line: "Line"
        case .area: "Area"
        case .point: "Scatter"
        case .pie: "Pie"
        }
    }

    public var symbolName: String {
        switch self {
        case .bar: "chart.bar.xaxis"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .point: "chart.dots.scatter"
        case .pie: "chart.pie"
        }
    }
}

/// How duplicate x values (per series) are combined.
public enum ChartAggregation: String, CaseIterable, Sendable, Identifiable, Hashable {
    case sum, average, count, min, max, none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sum: "Sum"
        case .average: "Average"
        case .count: "Count"
        case .min: "Minimum"
        case .max: "Maximum"
        case .none: "None"
        }
    }
}

public enum ColumnRole: Sendable, Hashable {
    case temporal, numeric, categorical
}

public struct ChartSpec: Sendable, Hashable {
    public var kind: ChartKind
    public var xColumn: Int
    public var yColumns: [Int]
    public var seriesColumn: Int?
    public var aggregation: ChartAggregation

    public init(kind: ChartKind, xColumn: Int, yColumns: [Int], seriesColumn: Int? = nil, aggregation: ChartAggregation = .sum) {
        self.kind = kind
        self.xColumn = xColumn
        self.yColumns = yColumns
        self.seriesColumn = seriesColumn
        self.aggregation = aggregation
    }
}

/// Infers column roles and a default chart from a result (design D7).
public enum ChartSuggester {
    /// Roles from the declared type, refined by sampling text columns (StarRocks returns LARGEINT and
    /// some expressions as strings).
    public static func roles(columns: [ColumnDefinition], rows: [[String?]], sampleSize: Int = 200) -> [ColumnRole] {
        columns.indices.map { index in
            switch columns[index].type.kind {
            case .integer, .float, .decimal: return .numeric
            case .date, .dateTime: return .temporal
            default:
                let sample = rows.lazy.prefix(sampleSize).compactMap { $0.indices.contains(index) ? $0[index] : nil }.filter { !$0.isEmpty }
                guard !sample.isEmpty else { return .categorical }
                if sample.allSatisfy({ TextValue.dateTime($0) != nil }) { return .temporal }
                if sample.allSatisfy({ TextValue.double($0) != nil }) { return .numeric }
                return .categorical
            }
        }
    }

    public static func suggest(columns: [ColumnDefinition], rows: [[String?]]) -> ChartSpec? {
        suggest(roles: roles(columns: columns, rows: rows), rows: rows)
    }

    public static func suggest(roles: [ColumnRole], rows: [[String?]]) -> ChartSpec? {
        let temporal = roles.indices.filter { roles[$0] == .temporal }
        let numeric = roles.indices.filter { roles[$0] == .numeric }
        let categorical = roles.indices.filter { roles[$0] == .categorical }
        guard !rows.isEmpty, !numeric.isEmpty else { return nil }

        if let x = temporal.first {
            let ys = Array(numeric.prefix(4))
            let series = ys.count == 1 ? categorical.first { distinctCount(rows, column: $0, limit: 25) <= 20 } : nil
            return ChartSpec(kind: .line, xColumn: x, yColumns: ys, seriesColumn: series)
        }
        if categorical.count >= 2 {
            return ChartSpec(kind: .bar, xColumn: categorical[0], yColumns: [numeric[0]], seriesColumn: categorical[1])
        }
        if let x = categorical.first {
            return ChartSpec(kind: .bar, xColumn: x, yColumns: Array(numeric.prefix(4)))
        }
        if numeric.count >= 2 {
            return ChartSpec(kind: .point, xColumn: numeric[0], yColumns: [numeric[1]], aggregation: .none)
        }
        return nil
    }

    static func distinctCount(_ rows: [[String?]], column: Int, limit: Int) -> Int {
        var seen = Set<String>()
        for row in rows where row.indices.contains(column) {
            seen.insert(row[column] ?? "")
            if seen.count >= limit { break }
        }
        return seen.count
    }
}

/// A plottable x value.
public enum ChartX: Sendable, Hashable, Comparable {
    case date(Date)
    case number(Double)
    case category(String)

    public static func < (lhs: ChartX, rhs: ChartX) -> Bool {
        switch (lhs, rhs) {
        case let (.date(a), .date(b)): a < b
        case let (.number(a), .number(b)): a < b
        case let (.category(a), .category(b)): a.localizedStandardCompare(b) == .orderedAscending
        case (.date, _): true
        case (.number, .category): true
        default: false
        }
    }

    public var label: String {
        switch self {
        case let .date(date): date.formatted(.iso8601.year().month().day())
        case let .number(value): value.formatted()
        case let .category(text): text
        }
    }
}

public struct ChartPoint: Sendable, Identifiable, Hashable {
    public let id: Int
    public let x: ChartX
    public let y: Double
    public let series: String
}

public struct ChartData: Sendable {
    public var points: [ChartPoint]
    public var series: [String]
    public var xRole: ColumnRole
    /// Explains reduction (bucketing, top-N, sampling) when the input exceeded the point budget.
    public var notice: String?
    public var skippedRows: Int

    public static let empty = ChartData(points: [], series: [], xRole: .categorical, notice: nil, skippedRows: 0)
}

/// Converts rows into chart points: aggregation of duplicate x, series split, and reduction to a
/// point budget (design D7). Pure; run off the main actor.
public enum ChartDataBuilder {
    public static let defaultPointBudget = 2_000
    public static let maxSeries = 12
    static let otherLabel = "Other"
    static let nullLabel = "(null)"

    public static func build(columns: [ColumnDefinition], rows: [[String?]], spec: ChartSpec, roles: [ColumnRole],
                             pointBudget: Int = defaultPointBudget) -> ChartData {
        guard roles.indices.contains(spec.xColumn), !spec.yColumns.isEmpty,
              spec.yColumns.allSatisfy(roles.indices.contains) else { return .empty }
        let budget = max(10, pointBudget)
        let xRole: ColumnRole = spec.kind == .pie ? .categorical : roles[spec.xColumn]
        let yColumns = spec.kind == .pie ? [spec.yColumns[0]] : spec.yColumns
        let seriesColumn = spec.kind == .pie ? nil : spec.seriesColumn.flatMap { roles.indices.contains($0) ? $0 : nil }
        let aggregation = spec.kind == .point ? .none : spec.aggregation

        // 1. Parse rows into raw observations.
        var observations: [(x: ChartX, y: Double, series: String)] = []
        observations.reserveCapacity(rows.count * yColumns.count)
        var skipped = 0
        for row in rows {
            guard let x = parseX(row.indices.contains(spec.xColumn) ? row[spec.xColumn] : nil, role: xRole) else {
                skipped += 1
                continue
            }
            for yColumn in yColumns {
                let raw = row.indices.contains(yColumn) ? row[yColumn] : nil
                let y: Double
                if aggregation == .count {
                    y = 1
                } else if let value = raw.flatMap(TextValue.double) {
                    y = value
                } else {
                    skipped += 1
                    continue
                }
                let series: String
                if let seriesColumn {
                    let name = (row.indices.contains(seriesColumn) ? row[seriesColumn] : nil) ?? nullLabel
                    series = yColumns.count > 1 ? "\(name) · \(columns[yColumn].name)" : name
                } else {
                    series = columns.indices.contains(yColumn) ? columns[yColumn].name : "y"
                }
                observations.append((x, y, series))
            }
        }

        // 2. Limit the number of series (largest totals win, the rest become "Other").
        var notices: [String] = []
        var seriesTotals: [String: Double] = [:]
        var seriesOrder: [String] = []
        for observation in observations {
            if seriesTotals[observation.series] == nil { seriesOrder.append(observation.series) }
            seriesTotals[observation.series, default: 0] += abs(observation.y)
        }
        if seriesOrder.count > maxSeries {
            let keep = Set(seriesOrder.sorted { seriesTotals[$0, default: 0] > seriesTotals[$1, default: 0] }.prefix(maxSeries - 1))
            for index in observations.indices where !keep.contains(observations[index].series) {
                observations[index].series = otherLabel
            }
            seriesOrder = seriesOrder.filter(keep.contains) + [otherLabel]
            notices.append("Showing the \(maxSeries - 1) largest series; the rest are grouped as “\(otherLabel)”.")
        }

        // 3. Aggregate duplicate (series, x).
        var points = aggregation == .none ? observations : aggregate(observations, using: aggregation)

        // 4. Reduce to the point budget.
        if points.count > budget {
            switch xRole {
            case .categorical:
                (points, notices) = keepTopCategories(points, budget: budget, seriesCount: seriesOrder.count, pie: spec.kind == .pie, notices: notices)
            case .temporal, .numeric:
                if spec.kind == .point {
                    let stride = Int((Double(points.count) / Double(budget)).rounded(.up))
                    let original = points.count
                    points = points.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
                    notices.append("Showing \(points.count.formatted()) of \(original.formatted()) points (evenly sampled).")
                } else {
                    let original = points.count
                    points = bucket(points, budget: budget, seriesCount: max(1, seriesOrder.count), aggregation: aggregation)
                    notices.append("Reduced \(original.formatted()) points to \(points.count.formatted()) by combining neighbouring x values (\(aggregation == .average ? "average" : aggregation.displayName.lowercased())).")
                }
            }
        }

        if xRole != .categorical { points.sort { $0.x < $1.x } }
        if spec.kind == .pie { points = points.filter { $0.y > 0 } }
        let chartPoints = points.enumerated().map { ChartPoint(id: $0.offset, x: $0.element.x, y: $0.element.y, series: $0.element.series) }
        let presentSeries = Set(chartPoints.map(\.series))
        return ChartData(points: chartPoints, series: seriesOrder.filter(presentSeries.contains), xRole: xRole,
                         notice: notices.isEmpty ? nil : notices.joined(separator: " "), skippedRows: skipped)
    }

    static func parseX(_ raw: String?, role: ColumnRole) -> ChartX? {
        switch role {
        case .temporal: raw.flatMap(TextValue.dateTime).map(ChartX.date)
        case .numeric: raw.flatMap(TextValue.double).map(ChartX.number)
        case .categorical: .category(raw ?? nullLabel)
        }
    }

    typealias Observation = (x: ChartX, y: Double, series: String)

    static func aggregate(_ observations: [Observation], using aggregation: ChartAggregation) -> [Observation] {
        struct Key: Hashable { let x: ChartX; let series: String }
        var order: [Key] = []
        var sums: [Key: (sum: Double, count: Int, min: Double, max: Double)] = [:]
        for observation in observations {
            let key = Key(x: observation.x, series: observation.series)
            if let current = sums[key] {
                sums[key] = (current.sum + observation.y, current.count + 1, Swift.min(current.min, observation.y), Swift.max(current.max, observation.y))
            } else {
                order.append(key)
                sums[key] = (observation.y, 1, observation.y, observation.y)
            }
        }
        return order.compactMap { key in
            guard let value = sums[key] else { return nil }
            let y: Double
            switch aggregation {
            case .sum, .none: y = value.sum
            case .average: y = value.sum / Double(value.count)
            case .count: y = Double(value.count)
            case .min: y = value.min
            case .max: y = value.max
            }
            return (key.x, y, key.series)
        }
    }

    static func keepTopCategories(_ points: [Observation], budget: Int, seriesCount: Int, pie: Bool,
                                  notices: [String]) -> ([Observation], [String]) {
        var totals: [String: Double] = [:]
        var order: [String] = []
        for point in points {
            let label = point.x.label
            if totals[label] == nil { order.append(label) }
            totals[label, default: 0] += abs(point.y)
        }
        let perCategory = max(1, seriesCount)
        let keepCount = max(1, budget / perCategory - (pie ? 1 : 0))
        let keep = Set(order.sorted { totals[$0, default: 0] > totals[$1, default: 0] }.prefix(keepCount))
        var kept = points.filter { keep.contains($0.x.label) }
        var notices = notices
        if pie {
            let rest = points.filter { !keep.contains($0.x.label) }.reduce(0) { $0 + $1.y }
            if rest > 0 { kept.append((.category(otherLabel), rest, kept.first?.series ?? "")) }
            notices.append("Showing the \(keepCount) largest of \(order.count.formatted()) categories; the rest are combined as “\(otherLabel)”.")
        } else {
            notices.append("Showing the \(keepCount) largest of \(order.count.formatted()) categories.")
        }
        return (kept, notices)
    }

    /// Fixed-width buckets over the x range, per series.
    static func bucket(_ points: [Observation], budget: Int, seriesCount: Int, aggregation: ChartAggregation) -> [Observation] {
        func numeric(_ x: ChartX) -> Double? {
            switch x {
            case let .date(date): date.timeIntervalSince1970
            case let .number(value): value
            case .category: nil
            }
        }
        let values = points.compactMap { numeric($0.x) }
        guard let lower = values.min(), let upper = values.max(), upper > lower else { return Array(points.prefix(budget)) }
        let bucketCount = max(1, budget / seriesCount)
        let width = (upper - lower) / Double(bucketCount)
        let isDate: Bool = if case .date = points.first?.x { true } else { false }
        var bucketed: [Observation] = []
        bucketed.reserveCapacity(points.count)
        for point in points {
            guard let value = numeric(point.x) else { continue }
            let index = Swift.min(bucketCount - 1, Int((value - lower) / width))
            let start = lower + Double(index) * width
            bucketed.append((isDate ? .date(Date(timeIntervalSince1970: start)) : .number(start), point.y, point.series))
        }
        let combine: ChartAggregation = aggregation == .none || aggregation == .count ? .sum : aggregation
        return aggregate(bucketed, using: combine)
    }
}
