import Foundation

/// What identifies a cluster beyond the endpoint used to reach it: StarRocks' `ClusterId` and its frontends' hosts.
/// Two endpoints with the same id and overlapping frontends are probably one cluster (a load balancer and an FE);
/// knowledge only ever *suggests* merging them.
public struct ClusterHints: Sendable, Equatable {
    public var clusterID: String?
    public var frontendHosts: [String]

    public init(clusterID: String?, frontendHosts: [String]) {
        self.clusterID = clusterID
        self.frontendHosts = frontendHosts
    }

    /// From `SHOW FRONTENDS` rows (`ClusterId`, `IP` or `Host`); `nil` when the rows carry neither.
    public static func parse(_ records: [Record]) -> ClusterHints? {
        var clusterID: String?
        var hosts: Set<String> = []
        for record in records {
            if clusterID == nil, let id = record.text("ClusterId"), !id.isEmpty { clusterID = id }
            if let host = record.text("IP") ?? record.text("Host"), !host.isEmpty { hosts.insert(host.lowercased()) }
        }
        guard clusterID != nil || !hosts.isEmpty else { return nil }
        return ClusterHints(clusterID: clusterID, frontendHosts: hosts.sorted())
    }
}

extension StarRocksClient {
    /// `CREATE VIEW` bodies of a database's views, keyed by view name, from `information_schema.views`; empty when the
    /// server refuses (older versions, missing privilege). Used for lineage and the joins inside views, never stored.
    public func viewDefinitions(database: String) async throws -> [String: String] {
        let sql = "SELECT TABLE_NAME, VIEW_DEFINITION FROM information_schema.views WHERE TABLE_SCHEMA = \(SQLText.literal(database))"
        guard let result = try await tolerant(sql) else { return [:] }
        return Self.viewDefinitions(result.records)
    }

    static func viewDefinitions(_ records: [Record]) -> [String: String] {
        var definitions: [String: String] = [:]
        for record in records {
            guard let name = record.text("TABLE_NAME"), let definition = record.text("VIEW_DEFINITION"), !definition.isEmpty else { continue }
            definitions[name] = definition
        }
        return definitions
    }

    /// `ClusterId` and frontend hosts from `SHOW FRONTENDS`; `nil` when the server refuses (it needs the operate
    /// privilege) or reports neither.
    public func clusterHints() async throws -> ClusterHints? {
        guard let result = try await tolerant("SHOW FRONTENDS") else { return nil }
        return ClusterHints.parse(result.records)
    }
}
