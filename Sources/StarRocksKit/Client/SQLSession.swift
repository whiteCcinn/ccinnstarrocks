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
    /// Increases with every statement, so a late cancel never touches a newer run on the same connection.
    private var runGeneration: UInt64 = 0
    private var cancelledGeneration: UInt64?
    /// A run is in progress (connecting or executing).
    public private(set) var isBusy = false
    /// Stop was pressed while the current run had not reached the server yet (still connecting). The run then
    /// stops before sending its statement instead of ignoring the request.
    private var cancelRequestedBeforeStart = false
    /// The current run's statement has reached the server (Stop then kills or closes it instead of preventing it).
    public var isStatementRunning: Bool { runningConnectionID != nil }
    /// Session-level `SET` statements replayed after a reconnect (bounded).
    private var sessionSettings: [String] = []
    private static let maxSessionSettings = 64

    init(client: StarRocksClient, database: String?, catalog: String?) {
        self.client = client
        self.database = database
        self.catalog = catalog
    }

    /// Runs one statement (or a server-side multi-statement batch) and returns all of its results.
    public func run(_ sql: String, limits: RowLimits = RowLimits()) async throws -> [ResultSet] {
        // One statement at a time; a rejected second run must not touch the running one's state.
        guard !isBusy else { throw StarRocksError(.busy, "This editor is already running a statement") }
        isBusy = true
        cancelRequestedBeforeStart = false
        defer { isBusy = false }
        let connection = try await ensureConnection()
        // No suspension between this check and `runningConnectionID`: a cancel sees either the flag or the statement.
        if cancelRequestedBeforeStart { throw StarRocksError.cancelled() }
        runGeneration &+= 1
        let generation = runGeneration
        runningConnectionID = connection.connectionID
        defer { if runGeneration == generation { runningConnectionID = nil } }
        do {
            let results = try await connection.query(sql, limits: limits)
            if await connection.isBroken {
                // An oversized result was abandoned: drop the socket and stop the server-side work.
                if self.connection === connection { self.connection = nil }
                client.killQueryInBackground(connectionID: connection.connectionID)
            }
            noteContextChange(sql)
            return results
        } catch let error as StarRocksError {
            if await connection.isBroken {
                if self.connection === connection { self.connection = nil }
                if error.kind == .cancelled { client.killQueryInBackground(connectionID: connection.connectionID) }
            }
            if cancelledGeneration == generation, error.isQueryInterrupted || error.kind == .connectionClosed || error.kind == .network {
                throw StarRocksError.cancelled()
            }
            throw error
        }
    }

    /// Asks the server to stop the running statement (`KILL QUERY`). If that statement is still
    /// running after `graceSeconds`, its socket is closed.
    public func cancel(graceSeconds: Double = 5) async {
        guard isBusy else { return }
        guard let id = runningConnectionID, let connection else {
            // The statement has not reached the server yet: stop it before it is sent.
            cancelRequestedBeforeStart = true
            return
        }
        let generation = runGeneration
        cancelledGeneration = generation
        do {
            try await client.killQuery(connectionID: id)
        } catch {
            connection.forceClose()
            return
        }
        let grace = graceSeconds.isFinite ? min(max(0, graceSeconds), 60) : 5
        try? await Task.sleep(for: .milliseconds(Int(grace * 1000)))
        if runGeneration == generation, runningConnectionID == id, self.connection === connection {
            connection.forceClose()
        }
    }

    public func close() async {
        await connection?.close()
        connection = nil
    }

    public var connectionID: UInt32? { connection?.connectionID }

    private func ensureConnection() async throws -> MySQLConnection {
        if let connection, await !connection.isBroken { return connection }
        let fresh = try await client.makeSessionConnection(database: database, catalog: catalog)
        // Restore session variables the user set before the reconnect (best effort).
        for setting in sessionSettings {
            _ = try? await fresh.execute(setting)
        }
        connection = fresh
        return fresh
    }

    /// Tracks `USE db`, `USE catalog.db`, `SET CATALOG c` and session `SET`s so a reconnect restores them.
    private func noteContextChange(_ sql: String) {
        guard let change = SessionContextChange.parse(sql) else { return }
        switch change {
        case let .use(newCatalog, newDatabase):
            if let newCatalog { catalog = newCatalog }
            database = newDatabase
        case let .setCatalog(newCatalog):
            catalog = newCatalog
            database = nil
        case let .sessionVariable(statement):
            sessionSettings.append(statement)
            if sessionSettings.count > Self.maxSessionSettings { sessionSettings.removeFirst(sessionSettings.count - Self.maxSessionSettings) }
        }
    }
}

/// Recognises statements that change the session's catalog or database.
public enum SessionContextChange: Equatable, Sendable {
    case use(catalog: String?, database: String)
    case setCatalog(String)
    /// A session-scoped `SET` (variables, `SET ROLE`) worth replaying after a reconnect.
    case sessionVariable(String)

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
        if lowered.hasPrefix("set ") {
            // Global and account-level settings persist on the server and must not be replayed.
            let words = lowered.split(whereSeparator: \.isWhitespace)
            let second = words.count > 1 ? String(words[1]) : ""
            let excluded = ["global", "password", "default", "property", "transaction"]
            if excluded.contains(second) || lowered.contains("@@global.") { return nil }
            return .sessionVariable(text)
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
