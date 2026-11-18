import Foundation
import StarRocksKit

/// What a connection's account may do, as far as AI read-only access is concerned.
///
/// Read-only checks on SQL text cannot stop an administrator: user-defined functions, file access and other users'
/// data are all reachable from a plain `SELECT`. So read-only AI access refuses privileged accounts unless the user
/// opts in per connection. The assessment follows every role the account holds (`SHOW GRANTS`, `CURRENT_ROLE()`,
/// `SHOW GRANTS FOR ROLE r`, transitively, active or not: an account can activate any role it holds) and fails closed.
public struct AccountPrivileges: Sendable, Equatable {
    /// Roles the account holds, directly or through other roles (`public` excluded).
    public let roles: [String]
    /// Why the account counts as privileged; empty when it does not.
    public let reasons: [String]

    public var isPrivileged: Bool { !reasons.isEmpty }

    /// Built-in administrator roles of StarRocks.
    public static let administratorRoles: Set<String> = ["root", "cluster_admin", "user_admin", "db_admin"]
    /// Privileges that do not administer anything when held on everything.
    static let readPrivileges: Set<String> = ["SELECT", "USAGE"]
    /// More roles than this cannot be verified in reasonable time: refused.
    static let maxRoles = 64

    struct Unverifiable: Error, CustomStringConvertible {
        let description: String
    }

    /// Assesses grant lines. `roleGrants` reads `SHOW GRANTS FOR ROLE r`; any error it throws propagates (fail closed).
    /// `public` is never read: StarRocks lets only accounts with the GRANT privilege read it.
    public static func assess(userGrants: [String], currentRoles: String?,
                              roleGrants: @Sendable (String) async throws -> [String]) async throws -> AccountPrivileges {
        var reasons: [String] = []
        var pending: [String] = []
        var seen = Set<String>()
        func enqueue(_ role: String) {
            let name = role.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.uppercased() != "NONE", name.lowercased() != "public", !seen.contains(name) else { return }
            seen.insert(name)
            pending.append(name)
        }
        func absorb(_ lines: [String]) {
            for line in lines {
                let grant = Grant.parse(line)
                grant.roles.forEach(enqueue)
                reasons += grant.reasons
            }
        }
        absorb(userGrants)
        for role in (currentRoles ?? "").split(separator: ",") {
            enqueue(role.trimmingCharacters(in: CharacterSet(charactersIn: " '`\"")))
        }
        var index = 0
        while index < pending.count {
            let role = pending[index]
            index += 1
            if administratorRoles.contains(role.lowercased()) {
                reasons.append("holds the built-in role \(role)")
                continue
            }
            guard seen.count <= maxRoles else {
                throw Unverifiable(description: "the account holds more than \(maxRoles) roles")
            }
            absorb(try await roleGrants(role))
        }
        var unique: [String] = []
        for reason in reasons where !unique.contains(reason) { unique.append(reason) }
        return AccountPrivileges(roles: pending, reasons: unique)
    }

    /// Reads the account's grants on `client` and assesses them.
    public static func inspect(_ client: StarRocksClient) async throws -> AccountPrivileges {
        @Sendable func lines(_ sql: String) async throws -> [String] {
            try await client.execute(sql).rows.compactMap { $0.last ?? nil }
        }
        let userGrants = try await lines("SHOW GRANTS")
        let current = try await client.execute("SELECT CURRENT_ROLE()").rows.first?.first ?? nil
        return try await assess(userGrants: userGrants, currentRoles: current) { role in
            try await lines(showGrantsForRole(role))
        }
    }

    static func showGrantsForRole(_ role: String) -> String {
        "SHOW GRANTS FOR ROLE `\(role.replacingOccurrences(of: "`", with: "``"))`"
    }

    /// One line of `SHOW GRANTS`: `GRANT 'role'[, …] TO …` or `GRANT priv[, …] ON object TO … [WITH GRANT OPTION]`.
    struct Grant {
        var roles: [String] = []
        var reasons: [String] = []

        static func parse(_ line: String) -> Grant {
            let lexer = SQLLexer(line)
            let tokens = lexer.tokens().filter { $0.kind != .comment }
            let words = tokens.map { lexer.text(of: $0).uppercased() }
            var grant = Grant()
            guard words.first == "GRANT", tokens.count > 1 else {
                grant.reasons.append("has a grant that could not be understood (\(line.prefix(120)))")
                return grant
            }
            // Role grants: GRANT 'a', 'b' TO …
            if tokens[1].kind == .string || tokens[1].kind == .quotedIdentifier {
                var index = 1
                while index < tokens.count, words[index] != "TO" {
                    if tokens[index].kind == .string || tokens[index].kind == .quotedIdentifier {
                        grant.roles.append(String(lexer.text(of: tokens[index]).dropFirst().dropLast()))
                    }
                    index += 1
                }
                return grant
            }
            guard let on = words.firstIndex(of: "ON"), let to = words[on...].firstIndex(of: "TO"), on > 1 else {
                grant.reasons.append("has a grant that could not be understood (\(line.prefix(120)))")
                return grant
            }
            let privileges = words[1..<on].split(separator: ",").map { $0.joined(separator: " ") }
            let object = words[(on + 1)..<to].joined(separator: " ")
            let withGrantOption = words[to...].joined(separator: " ").contains("WITH GRANT OPTION")
            let isGlobal = object.hasPrefix("ALL ") && (object.contains("IN ALL DATABASES") || !object.contains(" IN "))
            if object == "SYSTEM" {
                grant.reasons.append("has system privileges (\(privileges.joined(separator: ", ")))")
            }
            if privileges.contains("IMPERSONATE") {
                grant.reasons.append("may impersonate other users")
            }
            if withGrantOption {
                grant.reasons.append("may grant privileges to others (WITH GRANT OPTION)")
            }
            if isGlobal, privileges.contains(where: { !readPrivileges.contains($0) }) {
                grant.reasons.append("has \(privileges.joined(separator: ", ")) on \(object.lowercased())")
            }
            return grant
        }
    }
}

extension ConnectionProfile {
    /// This profile, keeping `previous`'s privileged-account opt-in only while it signs in to the same server as the
    /// same user: the opt-in was given for that account.
    public func keepingPrivilegedOptIn(from previous: ConnectionProfile) -> ConnectionProfile {
        var copy = self
        let sameAccount = endpoint == previous.endpoint && username.trimmingCharacters(in: .whitespaces) == previous.username.trimmingCharacters(in: .whitespaces)
        copy.mcpAllowPrivilegedAccount = sameAccount && previous.mcpAllowPrivilegedAccount
        return copy
    }
}
