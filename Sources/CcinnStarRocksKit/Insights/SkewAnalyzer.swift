import Foundation
import StarRocksKit

/// Data skew across tablets (buckets): a tablet is skewed when it holds more than `threshold` × the
/// average. Measured on data size, or on row count when sizes are not reported yet.
public struct SkewReport: Sendable {
    public struct Entry: Sendable, Identifiable, Hashable {
        public let tabletID: String
        public let dataSize: Int64
        public let rowCount: Int64
        /// Value relative to the average (1.0 = average).
        public let ratio: Double
        public let isSkewed: Bool

        public var id: String { tabletID }
    }

    public enum Metric: Sendable { case dataSize, rowCount }

    public let entries: [Entry]
    public let metric: Metric
    public let threshold: Double
    public let average: Double
    public let maxRatio: Double
    /// Standard deviation / mean.
    public let coefficientOfVariation: Double

    public var skewedCount: Int { entries.lazy.filter(\.isSkewed).count }
    public var isSkewed: Bool { skewedCount > 0 }
    public var totalBytes: Int64 { entries.reduce(0) { $0 &+ $1.dataSize } }
}

public enum SkewAnalyzer {
    public static func analyze(_ replicas: [TabletReplica], threshold: Double = 1.5) -> SkewReport {
        // One value per tablet: replicas carry the same data, take the largest report.
        var byTablet: [String: (size: Int64, rows: Int64)] = [:]
        var order: [String] = []
        for replica in replicas {
            let size = max(0, replica.dataSize ?? 0)
            let rows = max(0, replica.rowCount ?? 0)
            if let current = byTablet[replica.tabletID] {
                byTablet[replica.tabletID] = (max(current.size, size), max(current.rows, rows))
            } else {
                order.append(replica.tabletID)
                byTablet[replica.tabletID] = (size, rows)
            }
        }
        let totalSize = byTablet.values.reduce(0.0) { $0 + Double($1.size) }
        let metric: SkewReport.Metric = totalSize > 0 ? .dataSize : .rowCount
        let values = order.map { id -> Double in
            let value = byTablet[id] ?? (0, 0)
            return metric == .dataSize ? Double(value.size) : Double(value.rows)
        }
        let count = Double(max(1, values.count))
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let entries = order.enumerated().map { offset, id -> SkewReport.Entry in
            let value = byTablet[id] ?? (0, 0)
            let ratio = mean > 0 ? values[offset] / mean : 0
            return SkewReport.Entry(tabletID: id, dataSize: value.size, rowCount: value.rows, ratio: ratio,
                                    isSkewed: mean > 0 && ratio > threshold)
        }
        return SkewReport(entries: entries, metric: metric, threshold: threshold, average: mean,
                          maxRatio: entries.map(\.ratio).max() ?? 0,
                          coefficientOfVariation: mean > 0 ? variance.squareRoot() / mean : 0)
    }
}
