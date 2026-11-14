import Foundation

/// Entry point for one StarRocks cluster: a bounded connection pool, server facts, and the
/// metadata / insight / operation APIs (see the `StarRocksClient+*.swift` extensions).
public final class StarRocksClient: Sendable {
    public let configuration: ConnectionConfiguration
    public let serverInfo: ServerInfo
    let pool: ConnectionPool
    /// Configuration actually dialled (points at the tunnel's local port when tunnelled).
    private let effectiveConfiguration: ConnectionConfiguration
    private let transportFactory: TransportFactory
    private let tunnel: SSHTunnel?

    /// Default per-statement budget for metadata queries issued by the app itself.
    public static let metadataTimeout: Double = 30

    private init(configuration: ConnectionConfiguration, effectiveConfiguration: ConnectionConfiguration, serverInfo: ServerInfo,
                 pool: ConnectionPool, transportFactory: @escaping TransportFactory, tunnel: SSHTunnel?) {
        self.configuration = configuration
        self.effectiveConfiguration = effectiveConfiguration
        self.serverInfo = serverInfo
        self.pool = pool
        self.transportFactory = transportFactory
        self.tunnel = tunnel
    }

    /// Opens the pool and validates the credentials with a first connection.
    /// The client takes ownership of `tunnel` and closes it in `close()`.
    public static func connect(_ configuration: ConnectionConfiguration, poolSize: Int = 4, tunnel: SSHTunnel? = nil,
                               transportFactory: @escaping TransportFactory = Transports.network) async throws -> StarRocksClient {
        let effective = tunnel.map { configuration.with(endpoint: $0.localAddress) } ?? configuration
        // Pool connections stay in default_catalog without a current database: app-issued statements
        // always qualify names, and a later DROP DATABASE must not break new pool connections.
        var poolConfiguration = effective
        poolConfiguration.catalog = nil
        poolConfiguration.database = nil
        let factory: ConnectionPool.Factory = { [poolConfiguration] in
            try await MySQLConnection.connect(poolConfiguration, transportFactory: transportFactory)
        }
        let pool = ConnectionPool(maxSize: poolSize, factory: factory)
        do {
            let info = try await pool.withConnection { connection in
                try await ServerInfo.load(from: connection)
            }
            return StarRocksClient(configuration: configuration, effectiveConfiguration: effective, serverInfo: info, pool: pool,
                                   transportFactory: transportFactory, tunnel: tunnel)
        } catch {
            await pool.close()
            tunnel?.close()
            throw error
        }
    }

    public func close() async {
        await pool.close()
        tunnel?.close()
    }

    public var isTunnelled: Bool { tunnel != nil }

    // MARK: Statements

    /// Runs `sql` on a pooled connection. On cancellation, timeout or an abandoned oversized result
    /// the connection is dropped and the server-side query is killed (design D5).
    public func query(_ sql: String, limits: RowLimits = RowLimits(), timeout: Double? = nil) async throws -> [ResultSet] {
        try await pool.withConnection { connection in
            do {
                let results: [ResultSet]
                if let timeout {
                    results = try await Deadline.run(seconds: timeout, timeoutError: {
                        StarRocksError(.timeout, "The statement did not finish within \(Int(timeout))s")
                    }) {
                        try await connection.query(sql, limits: limits)
                    }
                } else {
                    results = try await connection.query(sql, limits: limits)
                }
                if await connection.isBroken { killQueryInBackground(connectionID: connection.connectionID) }
                return results
            } catch let error as StarRocksError {
                // Only a statement that was actually sent and then abandoned leaves work on the server; a
                // connection that is still healthy goes back to the pool, so killing it would hit the
                // next caller's query.
                if error.kind == .cancelled || error.kind == .timeout, await connection.isBroken {
                    killQueryInBackground(connectionID: connection.connectionID)
                }
                throw error
            }
        }
    }

    /// Runs `sql` and returns its last result; metadata default limits and timeout.
    public func execute(_ sql: String, timeout: Double? = StarRocksClient.metadataTimeout) async throws -> ResultSet {
        guard let last = try await query(sql, limits: .metadata, timeout: timeout).last else {
            throw StarRocksError(.protocolViolation, "The server returned no result for the statement")
        }
        return last
    }

    /// Opens a dedicated session (keeps `USE`/`SET` state) for an editor tab. `nil` arguments start
    /// in the profile's default catalog and database; afterwards the session tracks its own context.
    public func openSession(database: String? = nil, catalog: String? = nil) -> SQLSession {
        let catalog = catalog ?? configuration.catalog
        let sameCatalog = (catalog ?? SQLText.defaultCatalog) == (configuration.catalog ?? SQLText.defaultCatalog)
        return SQLSession(client: self, database: database ?? (sameCatalog ? configuration.database : nil), catalog: catalog)
    }

    // MARK: Kill

    /// `KILL QUERY <id>`: stops the statement running on that connection; the connection survives.
    public func killQuery(connectionID: UInt32) async throws {
        try await runOnDedicatedConnection("KILL QUERY \(connectionID)")
    }

    /// `KILL <id>`: terminates the whole connection.
    public func killConnection(_ connectionID: UInt32) async throws {
        try await runOnDedicatedConnection("KILL \(connectionID)")
    }

    func killQueryInBackground(connectionID: UInt32) {
        Task.detached { [self] in try? await killQuery(connectionID: connectionID) }
    }

    /// Kill statements must not wait behind a saturated pool, so they use a short-lived connection.
    private func runOnDedicatedConnection(_ sql: String) async throws {
        var configuration = effectiveConfiguration
        configuration.database = nil
        configuration.catalog = nil
        let transportFactory = transportFactory
        try await Deadline.run(seconds: 10, timeoutError: { StarRocksError(.timeout, "The server did not answer \(sql) in time") }) { [configuration] in
            let connection = try await MySQLConnection.connect(configuration, transportFactory: transportFactory)
            do {
                _ = try await connection.execute(sql)
                await connection.close()
            } catch {
                await connection.close()
                throw error
            }
        }
    }

    /// Connects with exactly the session's context (no fallback to the profile's database, which may
    /// not exist in the session's current catalog).
    func makeSessionConnection(database: String?, catalog: String?) async throws -> MySQLConnection {
        var sessionConfiguration = effectiveConfiguration
        sessionConfiguration.database = database
        sessionConfiguration.catalog = catalog
        return try await MySQLConnection.connect(sessionConfiguration, transportFactory: transportFactory)
    }
}
