import Foundation

/// A dedicated connection for one SQL editor: keeps session state (`USE`, `SET CATALOG`, `SET var`),
/// reconnects lazily (restoring database and catalog) and supports cancelling the running statement
/// with `KILL QUERY` while keeping the connection.
public actor SQLSession {
    private let client: StarRocksClient
    private var connection: MySQLConnection?
    public private(set) var database: String?
    public private(set) var catalog: String?
    /// Server connection id of the statement currently running, if any.
    public private(set) var runningConnectionID: UInt32?
    private var cancelRequested = false

    init(client: StarRocksClient, database: String?, catalog: String?) {
        self.client = client
        self.database = database
        self.catalog = catalog
    }

    /// Runs one statement (or a server-side multi-statement batch) and returns all of its results.
    public func run(_ sql: String, limits: RowLimits = RowLimits()) async throws -> [ResultSet] {
        let connection = try await ensureConnection()
        runningConnectionID = connection.connectionID
        cancelRequested = false
        defer { runningConnectionID = nil }
        do {
            let results = try await connection.query(sql, limits: limits)
            if await connection.isBroken {
                // An oversized result was abandoned: drop the socket and stop the server-side work.
                self.connection = nil
                client.killQueryInBackground(connectionID: connection.connectionID)
            }
            noteContextChange(sql)
            return results
        } catch let error as StarRocksError {
            if await connection.isBroken {
                self.connection = nil
                if error.kind == .cancelled { client.killQueryInBackground(connectionID: connection.connectionID) }
            }
            if cancelRequested, error.isQueryInterrupted {
                throw StarRocksError.cancelled()
            }
            throw error
        }
    }

    /// Asks the server to stop the running statement (`KILL QUERY`). If the server does not stop it
    /// within `graceSeconds`, the socket is closed.
    public func cancel(graceSeconds: Double = 5) async {
        guard let id = runningConnectionID, let connection else { return }
        cancelRequested = true
        do {
            try await client.killQuery(connectionID: id)
        } catch {
            connection.forceClose()
            return
        }
        try? await Task.sleep(for: .milliseconds(Int(graceSeconds * 1000)))
        if runningConnectionID == id { connection.forceClose() }
    }

    public func close() async {
        await connection?.close()
        connection = nil
    }

    public var connectionID: UInt32? { connection?.connectionID }

    private func ensureConnection() async throws -> MySQLConnection {
        if let connection, await !connection.isBroken { return connection }
        let fresh = try await client.makeSessionConnection(database: database, catalog: catalog)
        connection = fresh
        return fresh
    }

    /// Tracks `USE db`, `USE catalog.db` and `SET CATALOG c` so a reconnect restores the context.
    private func noteContextChange(_ sql: String) {
        guard let change = SessionContextChange.parse(sql) else { return }
        switch change {
        case let .use(newCatalog, newDatabase):
            if let newCatalog { catalog = newCatalog }
            database = newDatabase
        case let .setCatalog(newCatalog):
            catalog = newCatalog
            database = nil
        }
    }
}

/// Recognises statements that change the session's catalog or database.
public enum SessionContextChange: Equatable, Sendable {
    case use(catalog: String?, database: String)
    case setCatalog(String)

    public static func parse(_ sql: String) -> SessionContextChange? {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text.removeLast() }
        let lowered = text.lowercased()
        if lowered.hasPrefix("use ") {
            let parts = identifierPath(String(text.dropFirst(4)))
            switch parts.count {
            case 1: return .use(catalog: nil, database: parts[0])
            case 2: return .use(catalog: parts[0], database: parts[1])
            default: return nil
            }
        }
        if lowered.hasPrefix("set catalog ") {
            let parts = identifierPath(String(text.dropFirst(12)))
            return parts.count == 1 ? .setCatalog(parts[0]) : nil
        }
        return nil
    }

    /// Splits `a.b`, `` `a`.`b` `` (with doubled back-quotes) into parts; empty on anything unexpected.
    static func identifierPath(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "`" {
                    if index + 1 < characters.count, characters[index + 1] == "`" {
                        current.append("`")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "`" {
                quoted = true
            } else if character == "." {
                parts.append(current)
                current = ""
            } else if character.isWhitespace {
                return []
            } else {
                current.append(character)
            }
            index += 1
        }
        guard !quoted else { return [] }
        parts.append(current)
        return parts.contains(where: \.isEmpty) ? [] : parts
    }
}
