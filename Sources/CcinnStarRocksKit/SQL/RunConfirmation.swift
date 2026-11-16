import Foundation

/// The question the SQL editor asks before running statements. Cluster setting changes always need it; other
/// changes to data or schema only when the connection asks for it.
public struct RunConfirmation: Sendable, Equatable {
    /// The statements that change something, in run order.
    public let statements: [String]
    /// Kinds of cluster settings changed, each once, in order of first appearance.
    public let settingChanges: [ClusterSettingChange]

    public var changesSettings: Bool { !settingChanges.isEmpty }

    public var title: String { changesSettings ? "Change cluster settings?" : "Run statements that change data or schema?" }
    public var confirmLabel: String { changesSettings ? "Change Settings" : "Run" }

    /// A preview of the statements (at most five, each shortened), then what the setting changes affect.
    public var message: String {
        var preview = statements.prefix(Self.previewCount).map { $0.count > 160 ? String($0.prefix(160)) + "…" : $0 }
        if statements.count > Self.previewCount { preview.append("… and \(statements.count - Self.previewCount) more") }
        let notes = settingChanges.map { change in
            switch change {
            case .globalVariable: "Global variables change for new sessions of every user."
            case .frontendConfig: "Frontend configuration changes on the connected frontend at once and is lost when it restarts (fe.conf is not changed)."
            case .backendConfig: "Backend configuration changes on every backend and compute node at once and is lost when they restart (be.conf is not changed)."
            }
        }
        return (preview + notes).joined(separator: "\n\n")
    }

    private static let previewCount = 5

    /// `nil` when the statements may run without asking.
    public static func required(for statements: [String], confirmMutations: Bool) -> RunConfirmation? {
        let changing = statements.filter { SQLStatementKind.of($0).isMutation || ClusterSettingChange.of($0) != nil }
        var kinds: [ClusterSettingChange] = []
        for statement in changing {
            if let kind = ClusterSettingChange.of(statement), !kinds.contains(kind) { kinds.append(kind) }
        }
        guard !kinds.isEmpty || (confirmMutations && !changing.isEmpty) else { return nil }
        return RunConfirmation(statements: changing, settingChanges: kinds)
    }
}
