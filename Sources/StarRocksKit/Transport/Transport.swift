import Foundation

/// Host and port of a StarRocks FE (MySQL protocol port, usually 9030).
public struct Endpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 9030) {
        self.host = host
        self.port = port
    }

    public var isIPv6: Bool { host.contains(":") }
    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// A bidirectional byte stream to one server. `close()` must be safe to call from any thread at any
/// time (it is used for cancellation) and must make pending calls fail promptly.
public protocol ByteTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// Returns the next chunk of bytes (at least one byte) or throws when the stream ends.
    func receive() async throws -> [UInt8]
    func close()
}

public struct TransportOptions: Sendable, Equatable {
    /// Seconds to establish the TCP connection.
    public var connectTimeout: Double

    public init(connectTimeout: Double = 10) {
        self.connectTimeout = connectTimeout
    }
}

public typealias TransportFactory = @Sendable (Endpoint, TransportOptions) async throws -> any ByteTransport

public enum Transports {
    /// TCP via Network.framework.
    public static let network: TransportFactory = { endpoint, options in
        try await NetworkTransport.connect(to: endpoint, options: options)
    }
}
