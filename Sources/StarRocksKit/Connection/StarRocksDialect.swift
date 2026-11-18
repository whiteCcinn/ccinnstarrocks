import Foundation

/// StarRocks parses each statement in the session's `sql_dialect`. With `trino` (an account's `session.sql_dialect`
/// property, or the global default on clusters migrated from Trino) `"name"` is an identifier rather than a string, and
/// a `\'` escape ends a string, so the statement the server runs differs from what a MySQL-style reader sees: text
/// checks are bypassed and quoted literals can be broken out of. A `SET_VAR` hint does not change how the statement
/// is parsed. Connections that need StarRocks semantics (AI access) pin the dialect on connect and verify it.
enum StarRocksDialect {
    static let setStatement = "SET sql_dialect = 'StarRocks'"
    static let verifyStatement = "SELECT @@sql_dialect"
    /// MySQL's "Unknown system variable": a server without `sql_dialect` parses only its own dialect.
    static let unknownVariableCode = 1193

    /// Sets the session's dialect to StarRocks and reads it back. Fails closed: any error, or any other value, throws;
    /// only error 1193 on the SET (no such variable) is accepted, without a verification.
    static func pin(_ connection: MySQLConnection) async throws {
        do {
            _ = try await connection.execute(setStatement)
        } catch let error as StarRocksError where error.kind == .server && error.code == unknownVariableCode {
            return
        } catch let error as StarRocksError where error.kind == .server {
            throw refusal("setting it failed: \(error.message)")
        }
        let value: String?
        do {
            value = try await connection.execute(verifyStatement).rows.first?.first ?? nil
        } catch let error as StarRocksError where error.kind == .server {
            throw refusal("reading it back failed: \(error.message)")
        }
        guard let value, value.caseInsensitiveCompare("StarRocks") == .orderedSame else {
            throw refusal("the session reads \(value.map { "“\($0)”" } ?? "no dialect")")
        }
    }

    private static func refusal(_ reason: String) -> StarRocksError {
        StarRocksError(.server, "This connection must use the StarRocks SQL dialect, but \(reason). In another dialect (such as trino) quoted names and strings are read differently, so the checks on what AI may run would not see the statement the server runs.")
    }
}
