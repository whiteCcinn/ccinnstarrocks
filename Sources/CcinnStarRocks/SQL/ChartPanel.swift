import Charts
import CcinnStarRocksKit
import SwiftUI

/// Chart of a query result with live configuration (type, x, y, series, aggregation).
struct ChartPanel: View {
    @Bindable var chart: ChartState

    var body: some View {
        HStack(spacing: 0) {
            configuration
                .frame(width: 230)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if chart.data.points.isEmpty {
                    ContentUnavailableView(chart.isPreparing ? "Preparing Chart…" : "No Plottable Values", systemImage: "chart.bar.xaxis",
                                           description: Text(chart.isPreparing ? "" : "Choose numeric columns for the Y axis."))
                } else {
                    ChartCanvas(data: chart.data, kind: chart.spec.kind, xName: chart.columnNames[safe: chart.spec.xColumn] ?? "x",
                                yName: chart.spec.yColumns.compactMap { chart.columnNames[safe: $0] }.joined(separator: ", "))
                        .padding(.top, 6)
                        .opacity(chart.isPreparing ? 0.5 : 1)
                    footer
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(Format.count(chart.data.points.count)) points")
            if chart.data.skippedRows > 0 {
                Text("· \(Format.count(chart.data.skippedRows)) values skipped (NULL or not numeric)")
            }
            if let notice = chart.data.notice {
                Label(notice, systemImage: "info.circle").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    private var configuration: some View {
        Form {
            Section("Chart") {
                Picker("Type", selection: $chart.spec.kind) {
                    ForEach(ChartKind.allCases) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                    }
                }
                Picker(chart.spec.kind == .pie ? "Category" : "X axis", selection: $chart.spec.xColumn) {
                    ForEach(chart.columnNames.indices, id: \.self) { index in
                        Text(chart.columnNames[index]).tag(index)
                    }
                }
            }
            Section(chart.spec.kind == .pie ? "Value" : "Y axis") {
                ForEach(chart.numericColumns, id: \.self) { index in
                    Toggle(chart.columnNames[index], isOn: Binding(
                        get: { chart.spec.yColumns.contains(index) },
                        set: { isOn in
                            var columns = chart.spec.yColumns.filter { $0 != index }
                            if isOn { columns.append(index) }
                            if chart.spec.kind == .pie, isOn { columns = [index] }
                            if !columns.isEmpty { chart.spec.yColumns = columns.sorted() }
                        }))
                }
                if chart.numericColumns.isEmpty {
                    Text("No numeric columns").foregroundStyle(.secondary)
                }
            }
            if chart.spec.kind != .pie {
                Section("Grouping") {
                    Picker("Series", selection: $chart.spec.seriesColumn) {
                        Text("None").tag(Int?.none)
                        ForEach(chart.roles.indices.filter { chart.roles[$0] == .categorical && $0 != chart.spec.xColumn }, id: \.self) { index in
                            Text(chart.columnNames[index]).tag(Int?.some(index))
                        }
                    }
                    if chart.spec.kind != .point {
                        Picker("Duplicates", selection: $chart.spec.aggregation) {
                            ForEach(ChartAggregation.allCases.filter { $0 != .none }) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}

/// Swift Charts rendering of prepared `ChartData`, with a hover read-out.
struct ChartCanvas: View {
    let data: ChartData
    let kind: ChartKind
    let xName: String
    let yName: String
    @State private var hovered: ChartX?

    var body: some View {
        Chart {
            ForEach(data.points) { point in
                mark(point)
            }
            if let hovered, kind != .pie {
                hoverRule(hovered)
            }
        }
        .chartLegend(data.series.count > 1 || kind == .pie ? .visible : .hidden)
        .chartLegend(position: kind == .pie ? .trailing : .bottom, alignment: .leading)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location): hovered = nearestX(to: location, proxy: proxy, geometry: geometry)
                        case .ended: hovered = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hovered, kind != .pie { HoverCard(x: hovered, points: data.points.filter { $0.x == hovered }) }
        }
        .animation(.easeInOut(duration: 0.25), value: data.points.count)
        // DATE/DATETIME values carry no zone and are parsed as UTC; label the axis in UTC too.
        .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
    }

    @ChartContentBuilder
    private func mark(_ point: ChartPoint) -> some ChartContent {
        switch kind {
        case .pie:
            SectorMark(angle: .value(yName, point.y), innerRadius: .ratio(0.52), angularInset: 1.2)
                .cornerRadius(3)
                .foregroundStyle(by: .value(xName, point.x.label))
        case .bar:
            barMark(point)
        case .line:
            lineMark(point)
        case .area:
            areaMark(point)
        case .point:
            pointMark(point)
        }
    }

    @ChartContentBuilder
    private func barMark(_ point: ChartPoint) -> some ChartContent {
        switch point.x {
        case let .date(date):
            BarMark(x: .value(xName, date), y: .value(yName, point.y)).foregroundStyle(by: .value("Series", point.series))
        case let .number(number):
            BarMark(x: .value(xName, number), y: .value(yName, point.y)).foregroundStyle(by: .value("Series", point.series))
        case let .category(category):
            BarMark(x: .value(xName, category), y: .value(yName, point.y))
                .foregroundStyle(by: .value("Series", point.series))
                .position(by: .value("Series", point.series))
        }
    }

    @ChartContentBuilder
    private func lineMark(_ point: ChartPoint) -> some ChartContent {
        switch point.x {
        case let .date(date):
            LineMark(x: .value(xName, date), y: .value(yName, point.y))
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.monotone)
        case let .number(number):
            LineMark(x: .value(xName, number), y: .value(yName, point.y))
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.monotone)
        case let .category(category):
            LineMark(x: .value(xName, category), y: .value(yName, point.y))
                .foregroundStyle(by: .value("Series", point.series))
                .symbol(by: .value("Series", point.series))
        }
    }

    @ChartContentBuilder
    private func areaMark(_ point: ChartPoint) -> some ChartContent {
        switch point.x {
        case let .date(date):
            AreaMark(x: .value(xName, date), y: .value(yName, point.y), stacking: .standard)
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.monotone)
        case let .number(number):
            AreaMark(x: .value(xName, number), y: .value(yName, point.y), stacking: .standard)
                .foregroundStyle(by: .value("Series", point.series))
        case let .category(category):
            AreaMark(x: .value(xName, category), y: .value(yName, point.y), stacking: .standard)
                .foregroundStyle(by: .value("Series", point.series))
        }
    }

    @ChartContentBuilder
    private func pointMark(_ point: ChartPoint) -> some ChartContent {
        switch point.x {
        case let .date(date):
            PointMark(x: .value(xName, date), y: .value(yName, point.y)).foregroundStyle(by: .value("Series", point.series))
        case let .number(number):
            PointMark(x: .value(xName, number), y: .value(yName, point.y)).foregroundStyle(by: .value("Series", point.series))
        case let .category(category):
            PointMark(x: .value(xName, category), y: .value(yName, point.y)).foregroundStyle(by: .value("Series", point.series))
        }
    }

    @ChartContentBuilder
    private func hoverRule(_ x: ChartX) -> some ChartContent {
        switch x {
        case let .date(date): RuleMark(x: .value(xName, date)).foregroundStyle(.secondary.opacity(0.5))
        case let .number(number): RuleMark(x: .value(xName, number)).foregroundStyle(.secondary.opacity(0.5))
        case let .category(category): RuleMark(x: .value(xName, category)).foregroundStyle(.secondary.opacity(0.3))
        }
    }

    private func nearestX(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> ChartX? {
        guard kind != .pie, let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let x = location.x - origin.x
        var best: (ChartX, CGFloat)?
        var seen = Set<ChartX>()
        for point in data.points where seen.insert(point.x).inserted {
            let position: CGFloat?
            switch point.x {
            case let .date(date): position = proxy.position(forX: date)
            case let .number(number): position = proxy.position(forX: number)
            case let .category(category): position = proxy.position(forX: category)
            }
            guard let position else { continue }
            let distance = abs(position - x)
            if let current = best, current.1 <= distance { continue }
            best = (point.x, distance)
        }
        return best?.0
    }
}

private struct HoverCard: View {
    let x: ChartX
    let points: [ChartPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label(x)).font(.caption.weight(.semibold))
            ForEach(points.prefix(8)) { point in
                HStack {
                    Text(point.series).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(point.y.formatted(.number.precision(.fractionLength(0...2)))).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.5)))
        .padding(6)
        .allowsHitTesting(false)
    }

    private func label(_ x: ChartX) -> String {
        if case let .date(date) = x {
            let calendar = Calendar(identifier: .gregorian)
            var utc = calendar
            utc.timeZone = TimeZone(identifier: "UTC") ?? .current
            let components = utc.dateComponents([.hour, .minute, .second], from: date)
            let style: Date.FormatStyle = (components.hour == 0 && components.minute == 0 && components.second == 0)
                ? Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current)
                : Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: TimeZone(identifier: "UTC") ?? .current)
            return date.formatted(style)
        }
        return x.label
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
