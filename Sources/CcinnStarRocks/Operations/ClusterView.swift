import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

/// FE / BE / CN nodes with health, capacity and load.
struct ClusterView: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.nodes, retry: { model.refresh() }) { nodes in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let alive = nodes.filter(\.isAlive).count
                    HStack(spacing: 12) {
                        StatTile(title: "Frontends", value: "\(nodes.filter { $0.role == .frontend }.count)", systemImage: "cpu")
                        StatTile(title: "Backends", value: "\(nodes.filter { $0.role == .backend }.count)", systemImage: "internaldrive")
                        StatTile(title: "Compute nodes", value: "\(nodes.filter { $0.role == .computeNode }.count)", systemImage: "bolt")
                        StatTile(title: "Alive", value: "\(alive) / \(nodes.count)", systemImage: alive == nodes.count ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                                 tint: alive == nodes.count ? .green : .red)
                    }
                    ForEach(ClusterNode.Role.allCases, id: \.self) { role in
                        let group = nodes.filter { $0.role == role }
                        if !group.isEmpty {
                            Text(title(for: role)).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                                ForEach(group) { NodeCard(node: $0) }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func title(for role: ClusterNode.Role) -> String {
        switch role {
        case .frontend: "Frontends (FE)"
        case .backend: "Backends (BE)"
        case .computeNode: "Compute nodes (CN)"
        }
    }
}

private struct NodeCard: View {
    let node: ClusterNode
    @State private var showDetails = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(node.isAlive ? Color.green : Color.red).frame(width: 9, height: 9)
                    Text(node.host).font(.headline).textSelection(.enabled)
                    if let feRole = node.feRole { Badge(text: feRole, color: feRole == "LEADER" ? Theme.accent : .secondary) }
                    Spacer()
                    Button {
                        showDetails = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showDetails) {
                        ScrollView {
                            KeyValueList(items: node.fields.map { ($0.name, $0.value) }, monospacedValues: true)
                                .padding(14)
                        }
                        .frame(width: 520, height: 420)
                    }
                }
                Text("\(node.role.rawValue) \(node.nodeID) · \(node.version ?? "unknown version")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let total = node.totalCapacity, total > 0 {
                    meter("Disk", value: node.usedPercent ?? 0, caption: "\(Format.bytes(node.dataUsed)) data · \(Format.bytes(total)) total")
                }
                if let cpu = node.cpuUsedPercent { meter("CPU", value: cpu, caption: node.cpuCores.map { "\($0) cores" } ?? "") }
                if let memory = node.memoryUsedPercent { meter("Memory", value: memory, caption: "") }
                HStack(spacing: 14) {
                    if let tablets = node.tabletCount { Label(Format.count(tablets) + " tablets", systemImage: "square.grid.3x3") }
                    if let queries = node.runningQueries { Label("\(queries) queries", systemImage: "play.circle") }
                    if let heartbeat = node.lastHeartbeat { Label(heartbeat, systemImage: "heart") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = node.errorMessage, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
        }
    }

    private func meter(_ title: String, value: Double, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(Format.percent(value)).font(.caption.monospacedDigit())
                if !caption.isEmpty { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            ProgressView(value: min(100, max(0, value)), total: 100)
                .tint(value > 85 ? .red : value > 70 ? .orange : Theme.accent)
        }
    }
}
