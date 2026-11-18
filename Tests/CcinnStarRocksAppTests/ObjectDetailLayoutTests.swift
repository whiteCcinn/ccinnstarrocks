import AppKit
import CcinnStarRocksKit
@testable import StarRocksKit
import SwiftUI
import Testing
@testable import CcinnStarRocks

/// The Tablets tab inside an ordinary window. A view whose minimum height grows with the cluster pushes that minimum up
/// to the window: the whole app stretched past the screen once a table's replicas were spread over a few dozen BEs.
@Suite("Object detail layout", .serialized)
@MainActor
struct ObjectDetailLayoutTests {
    static let window = CGSize(width: 1100, height: 640)

    private func tabletReport(backends: Int) -> some View {
        let replicas = (0..<16).map { TabletReplica(tabletID: "\(10_000 + $0)", dataSize: 1_000_000 + Int64($0) * 1_000, rowCount: 10_000) }
        let shares = (0..<backends).map {
            ReplicaShare(backendID: "\(10_001 + $0)", replicaCount: 48, percent: 100 / Double(backends))
        }
        return TabletReport(report: SkewAnalyzer.analyze(replicas), replicas: replicas, distribution: .loaded(shares))
    }

    /// The size SwiftUI asks for when offered `Self.window`; taller than offered means the window gets stretched.
    private func requiredSize(_ view: some View) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: Self.window)
    }

    @Test func manyBackendsDoNotStretchTheWindow() {
        for backends in [3, 24, 80, 300] {
            let size = requiredSize(tabletReport(backends: backends))
            #expect(size.height <= Self.window.height, "\(backends) BEs need \(size.height) pt")
        }
    }

    @Test func theRequiredHeightDoesNotDependOnTheNumberOfBackends() {
        #expect(requiredSize(tabletReport(backends: 300)).height == requiredSize(tabletReport(backends: 3)).height)
    }
}
