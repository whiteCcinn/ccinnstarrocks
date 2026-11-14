import Foundation
import MySQLWire

/// Packet-level I/O over a transport. A value type so a single owner (the handshake, then the
/// connection actor) mutates it without locks.
struct PacketChannel: Sendable {
    let transport: any ByteTransport
    var framer = PacketFramer()
    /// Sequence id of the next packet to write.
    var sequence: UInt8 = 0
    /// Set when a result was abandoned mid-stream; the connection must then be dropped.
    var isAbandoned = false

    init(transport: any ByteTransport) {
        self.transport = transport
    }

    mutating func read() async throws -> [UInt8] {
        while true {
            if let packet = try framer.nextPacket() {
                sequence = packet.sequence &+ 1
                return packet.payload
            }
            framer.append(try await transport.receive())
        }
    }

    mutating func write(_ payload: [UInt8]) async throws {
        let bytes = PacketCodec.frame(payload, sequence: sequence)
        sequence &+= UInt8(truncatingIfNeeded: payload.count / PacketCodec.maxChunk + 1)
        try await transport.send(bytes)
    }

    /// Every client command starts a new sequence.
    mutating func sendCommand(_ payload: [UInt8]) async throws {
        sequence = 0
        try await write(payload)
    }
}

/// One authenticated MySQL-protocol session to a StarRocks FE.
///
/// The actor owns the socket; a command takes the packet channel out of the actor for its duration,
/// so overlapping commands fail fast with `.busy` instead of interleaving bytes. Any I/O or framing
/// failure marks the connection broken for good; a server ERR packet does not (the protocol stays aligned).
public actor MySQLConnection {
    public nonisolated let endpoint: Endpoint
    public nonisolated let connectionID: UInt32
    /// MySQL-compatible version reported in the handshake (e.g. `8.0.33`); see `ServerInfo` for the real one.
    public nonisolated let protocolVersion: String
    public nonisolated let capabilities: Capabilities
    private nonisolated let transport: any ByteTransport

    private var channel: PacketChannel?
    public private(set) var isBroken = false

    init(endpoint: Endpoint, greeting: HandshakeV10, capabilities: Capabilities, channel: PacketChannel) {
        self.endpoint = endpoint
        connectionID = greeting.connectionID
        protocolVersion = greeting.serverVersion
        self.capabilities = capabilities
        transport = channel.transport
        self.channel = channel
    }

    // MARK: Connect

    public static func connect(_ configuration: ConnectionConfiguration,
                               transportFactory: TransportFactory = Transports.network) async throws -> MySQLConnection {
        let endpoint = configuration.endpoint
        let timeout = max(1, configuration.connectTimeout)
        let transport = try await transportFactory(endpoint, TransportOptions(connectTimeout: timeout))
        // Handshake and session setup share one deadline; on timeout or cancellation the socket is closed.
        do {
            return try await Deadline.run(seconds: timeout, timeoutError: {
                StarRocksError(.timeout, "\(endpoint) did not complete the connection setup within \(Int(timeout))s")
            }) {
                try await withTaskCancellationHandler {
                    let connection = try await Handshake.perform(transport: transport, configuration: configuration)
                    do {
                        try await connection.applyInitialContext(configuration)
                    } catch {
                        await connection.close()
                        throw error
                    }
                    return connection
                } onCancel: {
                    transport.close()
                }
            }
        } catch {
            transport.close()
            if Task.isCancelled { throw StarRocksError.cancelled() }
            throw Self.mapError(error, endpoint: endpoint)
        }
    }

    private func applyInitialContext(_ configuration: ConnectionConfiguration) async throws {
        for variable in configuration.sessionVariables {
            let name = variable.name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { continue }
            do {
                _ = try await execute("SET \(name) = \(SQLText.literal(variable.value))")
            } catch let error as StarRocksError where error.kind == .server {
                continue // unknown variable on this server version
            }
        }
        guard let catalog = configuration.catalog?.trimmingCharacters(in: .whitespaces), !catalog.isEmpty,
              catalog != SQLText.defaultCatalog else { return }
        _ = try await execute("SET CATALOG \(SQLText.quoteIdentifier(catalog))")
        if let database = configuration.database?.trimmingCharacters(in: .whitespaces), !database.isEmpty {
            _ = try await execute("USE \(SQLText.quoteIdentifier(database))")
        }
    }

    // MARK: Commands

    /// Runs `sql` (COM_QUERY) and returns every result it produced (multi-statement aware).
    public func query(_ sql: String, limits: RowLimits = RowLimits()) async throws -> [ResultSet] {
        try await perform { channel in
            try await channel.sendCommand(Command.query(sql))
            return try await ResultReader.readResults(from: &channel, capabilities: self.capabilities, limits: limits)
        }
    }

    /// Runs `sql` and returns its last result.
    public func execute(_ sql: String, limits: RowLimits = .metadata) async throws -> ResultSet {
        guard let last = try await query(sql, limits: limits).last else {
            throw StarRocksError(.protocolViolation, "The server returned no result for the statement")
        }
        return last
    }

    public func ping() async throws {
        try await perform { channel in
            try await channel.sendCommand(Command.ping)
            let reply = try await channel.read()
            switch try ServerPacket.parse(reply, capabilities: self.capabilities) {
            case .ok: return
            case let .error(packet): throw StarRocksError.server(packet)
            default: throw StarRocksError(.protocolViolation, "Unexpected reply to COM_PING")
            }
        }
    }

    /// Sends COM_QUIT (best effort) and closes the socket.
    public func close() async {
        guard !isBroken else { return }
        isBroken = true
        if var channel = channel.take() {
            try? await channel.sendCommand(Command.quit)
        }
        transport.close()
    }

    /// Closes the socket from any context (cancellation, pool shutdown).
    public nonisolated func forceClose() {
        transport.close()
    }

    // MARK: Plumbing

    private func perform<T: Sendable>(_ operation: (inout PacketChannel) async throws -> T) async throws -> T {
        guard !isBroken else {
            throw StarRocksError(.connectionClosed, "The connection to \(endpoint) is closed")
        }
        guard var channel = channel.take() else {
            throw StarRocksError(.busy, "Connection \(connectionID) is already running a statement")
        }
        if Task.isCancelled {
            self.channel = channel
            throw StarRocksError.cancelled()
        }
        let transport = self.transport
        do {
            let result = try await withTaskCancellationHandler {
                try await operation(&channel)
            } onCancel: {
                transport.close()
            }
            if channel.isAbandoned {
                markBroken()
            } else {
                self.channel = channel
            }
            return result
        } catch {
            let mapped = Self.mapError(error, endpoint: endpoint)
            if Task.isCancelled || mapped.breaksConnection {
                markBroken()
                throw Task.isCancelled ? StarRocksError.cancelled() : mapped
            }
            self.channel = channel
            throw mapped
        }
    }

    private func markBroken() {
        isBroken = true
        channel = nil
        transport.close()
    }

    static func mapError(_ error: any Error, endpoint: Endpoint) -> StarRocksError {
        switch error {
        case let error as StarRocksError: error
        case let wire as MySQLWireError: StarRocksError(.protocolViolation, "\(endpoint): \(wire.description)")
        default: StarRocksError(.network, "Connection to \(endpoint) failed: \(error.localizedDescription)")
        }
    }
}
