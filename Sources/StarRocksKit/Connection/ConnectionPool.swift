import Foundation

/// Bounded pool of connections to one FE.
///
/// Invariants (all mutated only inside the actor):
/// - `openCount` counts idle + checked-out + being-created connections and never exceeds `maxSize`.
/// - A waiter is resumed exactly once: with a connection, with `nil` (permission to create), or with an error.
public actor ConnectionPool {
    public typealias Factory = @Sendable () async throws -> MySQLConnection

    public nonisolated let maxSize: Int
    private let factory: Factory

    private var idle: [MySQLConnection] = []
    private var openCount = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<MySQLConnection?, any Error>)] = []
    private var nextWaiterID: UInt64 = 0
    private var isClosed = false

    public init(maxSize: Int, factory: @escaping Factory) {
        self.maxSize = max(1, maxSize)
        self.factory = factory
    }

    public var statistics: (open: Int, idle: Int, waiting: Int) { (openCount, idle.count, waiters.count) }

    /// Runs `body` with an exclusively checked-out connection and always returns it to the pool.
    public nonisolated func withConnection<T: Sendable>(_ body: (MySQLConnection) async throws -> T) async throws -> T {
        let connection = try await checkout()
        do {
            let result = try await body(connection)
            await checkin(connection)
            return result
        } catch {
            await checkin(connection)
            throw error
        }
    }

    public func checkout() async throws -> MySQLConnection {
        guard !isClosed else { throw Self.closedError() }
        while let connection = idle.popLast() {
            if await !connection.isBroken { return connection }
            openCount -= 1
        }
        if openCount < maxSize {
            return try await createConnection()
        }
        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        let handedOver: MySQLConnection? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((waiterID, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        if let handedOver { return handedOver }
        // A slot was freed for us; `openCount` was already reserved by the releaser.
        return try await createConnection(slotReserved: true)
    }

    public func checkin(_ connection: MySQLConnection) async {
        let broken = await connection.isBroken
        if isClosed || broken {
            if !broken { await connection.close() }
            openCount -= 1
            handOffFreedSlot()
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: connection)
            return
        }
        idle.append(connection)
    }

    /// Closes idle connections now and checked-out ones when they are returned.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let toClose = idle
        idle.removeAll()
        openCount -= toClose.count
        for connection in toClose { await connection.close() }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: Self.closedError()) }
    }

    // MARK: Private

    private static func closedError() -> StarRocksError {
        StarRocksError(.connectionClosed, "The connection pool is closed")
    }

    private func createConnection(slotReserved: Bool = false) async throws -> MySQLConnection {
        if !slotReserved { openCount += 1 }
        let connection: MySQLConnection
        do {
            connection = try await factory()
        } catch {
            openCount -= 1
            handOffFreedSlot()
            throw error
        }
        if isClosed {
            await connection.close()
            openCount -= 1
            throw Self.closedError()
        }
        return connection
    }

    /// Gives a freed slot to the oldest waiter, which will then create its own connection.
    private func handOffFreedSlot() {
        guard !waiters.isEmpty, openCount < maxSize, !isClosed else { return }
        let waiter = waiters.removeFirst()
        openCount += 1
        waiter.continuation.resume(returning: nil)
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: StarRocksError.cancelled())
    }
}
