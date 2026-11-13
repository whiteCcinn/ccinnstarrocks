import Foundation
import MySQLWire

/// Every failure surfaced by StarRocksKit. Messages are user-facing and never contain secrets.
public struct StarRocksError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case invalidArgument
        case network
        case timeout
        case dns
        case sshTunnel
        case authentication
        /// The server rejected a statement (ERR packet). The connection stays usable.
        case server
        case protocolViolation
        case cancelled
        case connectionClosed
        case busy
    }

    public let kind: Kind
    public let message: String
    /// MySQL error code from an ERR packet.
    public let code: Int?
    public let sqlState: String?

    public init(_ kind: Kind, _ message: String, code: Int? = nil, sqlState: String? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
        self.sqlState = sqlState
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    public static func cancelled() -> StarRocksError { StarRocksError(.cancelled, "The operation was cancelled") }

    static func server(_ packet: ErrorPacket) -> StarRocksError {
        let message = packet.message.isEmpty ? "Server error \(packet.code)" : packet.message
        let kind: Kind = Self.authenticationCodes.contains(Int(packet.code)) ? .authentication : .server
        return StarRocksError(kind, message, code: Int(packet.code), sqlState: packet.sqlState)
    }

    /// Access denied / bad handshake / password expired.
    static let authenticationCodes: Set<Int> = [1043, 1044, 1045, 1251, 1698, 1820, 1862]

    /// The statement was killed by `KILL QUERY` (or the query timed out server-side).
    public var isQueryInterrupted: Bool {
        guard kind == .server else { return false }
        if code == 1317 { return true }
        let lowered = message.lowercased()
        return lowered.contains("cancelled") || lowered.contains("canceled") || lowered.contains("killed")
    }

    /// Errors after which the connection must not be reused.
    public var breaksConnection: Bool {
        switch kind {
        case .server, .authentication, .invalidArgument, .busy: false
        default: true
        }
    }
}
