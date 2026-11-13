import Foundation
import Network
import os

/// `ByteTransport` over Network.framework TCP.
final class NetworkTransport: ByteTransport, @unchecked Sendable {
    // NWConnection is thread-safe; the connect handshake guards its one-shot continuation with a lock.
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let endpoint: Endpoint

    private init(connection: NWConnection, queue: DispatchQueue, endpoint: Endpoint) {
        self.connection = connection
        self.queue = queue
        self.endpoint = endpoint
    }


    static func connect(to endpoint: Endpoint, options: TransportOptions) async throws -> NetworkTransport {
        guard (1...65_535).contains(endpoint.port), let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw StarRocksError(.invalidArgument, "Invalid port \(endpoint.port)")
        }
        let host = endpoint.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw StarRocksError(.invalidArgument, "Enter a host name") }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = Int(max(1, options.connectTimeout.rounded(.up)))
        let parameters = NWParameters(tls: nil, tcp: tcp)

        let queue = DispatchQueue(label: "ccinnstarrocks.transport.\(endpoint)", qos: .userInitiated)
        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: port), using: parameters)
        let transport = NetworkTransport(connection: connection, queue: queue, endpoint: endpoint)
        try await transport.start(timeout: options.connectTimeout)
        return transport
    }

    private func start(timeout: Double) async throws {
        let once = OSAllocatedUnfairLock(initialState: false)
        let endpoint = self.endpoint
        let connection = self.connection
        let queue = self.queue

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                @Sendable func finish(_ result: Result<Void, StarRocksError>) {
                    let first = once.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    connection.stateUpdateHandler = nil
                    switch result {
                    case .success: continuation.resume()
                    case let .failure(error):
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case let .failed(error): finish(.failure(Self.describe(error, endpoint: endpoint)))
                    // Network.framework would keep retrying (e.g. connection refused); fail fast instead.
                    case let .waiting(error): finish(.failure(Self.describe(error, endpoint: endpoint)))
                    case .cancelled: finish(.failure(StarRocksError(.cancelled, "Connection to \(endpoint) was cancelled")))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + max(0.5, timeout)) {
                    finish(.failure(StarRocksError(.timeout, "Timed out after \(Int(timeout))s connecting to \(endpoint)")))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        let connection = self.connection
        let endpoint = self.endpoint
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: StarRocksError(.network, "Failed to send to \(endpoint): \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> [UInt8] {
        let connection = self.connection
        let endpoint = self.endpoint
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if let error {
                    continuation.resume(throwing: StarRocksError(.network, "Connection to \(endpoint) failed: \(error.localizedDescription)"))
                } else if isComplete {
                    continuation.resume(throwing: StarRocksError(.connectionClosed, "\(endpoint) closed the connection"))
                } else {
                    continuation.resume(throwing: StarRocksError(.network, "Connection to \(endpoint) returned no data"))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }

    static func describe(_ error: NWError, endpoint: Endpoint) -> StarRocksError {
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED:
                StarRocksError(.network, "Connection refused by \(endpoint). Is the StarRocks FE running and is 9030 its query port?")
            case .ETIMEDOUT:
                StarRocksError(.timeout, "Timed out connecting to \(endpoint)")
            case .EHOSTUNREACH, .ENETUNREACH:
                StarRocksError(.network, "\(endpoint) is unreachable from this network")
            default:
                StarRocksError(.network, "Could not connect to \(endpoint): \(error.localizedDescription)")
            }
        case .dns:
            StarRocksError(.dns, "Could not resolve host \(endpoint.host)")
        default:
            StarRocksError(.network, "Could not connect to \(endpoint): \(error.localizedDescription)")
        }
    }
}
