import Foundation

/// Cluster settings: variables, frontend configuration and backend configuration (design D7).
extension StarRocksClient {
    /// Every system variable with its global value and, where the server reports it, its default.
    public func variables() async throws -> [ConfigItem] {
        let global: ResultSet
        if let view = try await tolerant("SELECT * FROM information_schema.global_variables") {
            global = view
        } else {
            global = try await execute("SHOW GLOBAL VARIABLES")
        }
        // Defaults only come from the verbose view (StarRocks 3.x+); without it the list simply has no defaults.
        let verbose = try await tolerant("SELECT * FROM information_schema.verbose_session_variables")
        return ConfigItem.variables(global: global.records, verbose: verbose?.records ?? [])
    }

    /// Configuration of the frontend this client is connected to. Needs `OPERATE` on `SYSTEM`.
    public func frontendConfig() async throws -> [ConfigItem] {
        ConfigItem.frontend(try await execute("ADMIN SHOW FRONTEND CONFIG").records)
    }

    /// Configuration of every backend and compute node, grouped by name. Needs `OPERATE` on `SYSTEM`.
    public func backendConfig() async throws -> [ConfigItem] {
        // ~800 items per node: the metadata cap (100k rows) would cut large clusters short.
        let rows = try await query("SELECT * FROM information_schema.be_configs", limits: RowLimits(maxRows: 2_000_000, drainRows: 0),
                                   timeout: Self.metadataTimeout)
        let records = rows.last?.records ?? []
        async let backends = tolerant("SHOW BACKENDS")
        async let computeNodes = tolerant("SHOW COMPUTE NODES")
        var hosts: [String: String] = [:]
        for record in (try await backends)?.records ?? [] {
            if let id = record.text("BackendId"), let host = record.text("IP", "Host") { hosts[id] = host }
        }
        for record in (try await computeNodes)?.records ?? [] {
            if let id = record.text("ComputeNodeId"), let host = record.text("IP", "Host") { hosts[id] = host }
        }
        return ConfigItem.backend(records, hosts: hosts)
    }
}
