import Foundation
import Testing
@testable import CcinnStarRocksKit

/// Grant lines as StarRocks 3.3 and 4.1 print them (`SHOW GRANTS`, `SHOW GRANTS FOR ROLE r`, `CURRENT_ROLE()`).
@Suite("Account privileges")
struct AccountPrivilegesTests {
    private struct Missing: Error {}

    private func assess(_ userGrants: [String], current: String? = "NONE", roles: [String: [String]] = [:],
                        fetched: Recorder = Recorder()) async throws -> AccountPrivileges {
        try await AccountPrivileges.assess(userGrants: userGrants, currentRoles: current) { role in
            await fetched.add(role)
            guard let grants = roles[role] else { throw Missing() }
            return grants
        }
    }

    actor Recorder {
        var roles: [String] = []
        func add(_ role: String) { roles.append(role) }
    }

    @Test func rootIsPrivileged() async throws {
        let result = try await assess(["GRANT 'root' TO 'root'@'%'"], current: "root")
        #expect(result.isPrivileged)
        #expect(result.reasons.contains { $0.contains("root") })
    }

    @Test func builtInAdminRolesArePrivilegedWithoutReadingThem() async throws {
        for role in ["db_admin", "cluster_admin", "user_admin", "root"] {
            let fetched = Recorder()
            let result = try await assess(["GRANT '\(role)' TO 'u'@'%'"], current: role, fetched: fetched)
            #expect(result.isPrivileged, "\(role)")
            #expect(await fetched.roles.isEmpty)
        }
    }

    /// A role granted through another role counts even when it is not active: the account can activate it.
    @Test func nestedInactiveRolesCount() async throws {
        let result = try await assess(["GRANT 'ccinn_ai_wrapper' TO 'ccinn_ai_nested'@'%'"], current: "NONE",
                                      roles: ["ccinn_ai_wrapper": ["GRANT 'cluster_admin' TO  ROLE ccinn_ai_wrapper"]])
        #expect(result.isPrivileged)
        #expect(result.roles.contains("cluster_admin"))
    }

    @Test func aPlainReaderIsNotPrivileged() async throws {
        let fetched = Recorder()
        let result = try await assess(["GRANT SELECT ON ALL TABLES IN DATABASE shop TO USER 'ccinn_ai_plain'@'%'"], current: "NONE",
                                      fetched: fetched)
        #expect(!result.isPrivileged, "\(result.reasons)")
        #expect(await fetched.roles.isEmpty, "public is never read: ordinary accounts may not read it")
        let reader = try await assess(["GRANT SELECT ON ALL TABLES IN ALL DATABASES TO USER 'r'@'%'",
                                       "GRANT USAGE ON ALL CATALOGS TO USER 'r'@'%'", "GRANT SELECT ON ALL VIEWS IN ALL DATABASES TO USER 'r'@'%'"])
        #expect(!reader.isPrivileged, "reading everything is not administering: \(reader.reasons)")
        let writer = try await assess(["GRANT INSERT, UPDATE ON ALL TABLES IN DATABASE shop TO USER 'w'@'%'"])
        #expect(!writer.isPrivileged, "writing one database is not administering")
    }

    @Test(arguments: [
        "GRANT NODE ON SYSTEM TO ROLE 'ops'",
        "GRANT OPERATE ON SYSTEM TO ROLE 'ops'",
        "GRANT GRANT ON SYSTEM TO ROLE 'ops'",
        "GRANT FILE ON SYSTEM TO ROLE 'ops'",
        "GRANT IMPERSONATE ON USER 'root'@'%' TO ROLE 'ops'",
        "GRANT IMPERSONATE ON ALL USERS TO ROLE 'ops'",
        "GRANT SELECT ON ALL TABLES IN DATABASE shop TO ROLE 'ops' WITH GRANT OPTION",
        "GRANT DELETE, DROP, INSERT, SELECT ON ALL TABLES IN ALL DATABASES TO ROLE 'ops'",
        "GRANT CREATE TABLE, DROP ON ALL DATABASES TO ROLE 'ops'",
        "GRANT ALL ON ALL DATABASES TO ROLE 'ops'",
        "GRANT USAGE, CREATE DATABASE ON ALL CATALOGS TO ROLE 'ops'",
        "GRANT DROP, ALTER, USAGE ON ALL STORAGE VOLUMES TO ROLE 'ops'",
        "GRANT USAGE, DROP ON ALL GLOBAL FUNCTIONS TO ROLE 'ops'",
    ])
    func customRolesWithAdministrativePrivilegesArePrivileged(line: String) async throws {
        let result = try await assess(["GRANT 'ops' TO 'u'@'%'"], roles: ["ops": [line]])
        #expect(result.isPrivileged, "\(line)")
        let direct = try await assess([line.replacingOccurrences(of: "TO ROLE 'ops'", with: "TO USER 'u'@'%'")])
        #expect(direct.isPrivileged, "granted directly: \(line)")
    }

    @Test func activeRolesFromCurrentRoleAreRead() async throws {
        let fetched = Recorder()
        let result = try await assess([], current: "analyst, reporting", roles: ["analyst": [], "reporting": ["GRANT NODE ON SYSTEM TO ROLE 'reporting'"]],
                                      fetched: fetched)
        #expect(result.isPrivileged)
        #expect(Set(await fetched.roles) == ["analyst", "reporting"])
    }

    /// Failing closed: a role that cannot be read, a grant that cannot be understood, or a runaway role graph refuses.
    @Test func whatCannotBeVerifiedIsRefused() async throws {
        await #expect(throws: (any Error).self) { _ = try await assess(["GRANT 'unknown_role' TO 'u'@'%'"]) }
        let odd = try await assess(["GRANT SOMETHING NEW SOMEHOW"])
        #expect(odd.isPrivileged, "an unrecognised grant counts as privileged")
        var chain: [String: [String]] = [:]
        for index in 0..<200 { chain["r\(index)"] = ["GRANT 'r\(index + 1)' TO ROLE r\(index)"] }
        await #expect(throws: (any Error).self) { _ = try await assess(["GRANT 'r0' TO 'u'@'%'"], roles: chain) }
        let cycle = try await assess(["GRANT 'a' TO 'u'@'%'"], roles: ["a": ["GRANT 'b' TO ROLE a"], "b": ["GRANT 'a' TO ROLE b"]])
        #expect(!cycle.isPrivileged, "a cycle terminates")
    }

    @Test func roleNamesAreQuotedForTheServer() {
        #expect(AccountPrivileges.showGrantsForRole("db_admin") == "SHOW GRANTS FOR ROLE `db_admin`")
        #expect(AccountPrivileges.showGrantsForRole("we`ird") == "SHOW GRANTS FOR ROLE `we``ird`")
    }

    @Test func theOptInBelongsToOneAccount() {
        var profile = ConnectionProfile(host: "db", port: 9030, username: "root", mcpAccess: .readOnly)
        profile.mcpAllowPrivilegedAccount = true
        var renamed = profile
        renamed.name = "Prod"
        #expect(renamed.keepingPrivilegedOptIn(from: profile).mcpAllowPrivilegedAccount)
        var otherUser = profile
        otherUser.username = "admin"
        #expect(!otherUser.keepingPrivilegedOptIn(from: profile).mcpAllowPrivilegedAccount)
        var otherHost = profile
        otherHost.host = "db2"
        #expect(!otherHost.keepingPrivilegedOptIn(from: profile).mcpAllowPrivilegedAccount)
        let decoded = try? JSONDecoder().decode(ConnectionProfile.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        #expect(decoded?.mcpAllowPrivilegedAccount == false, "off unless the user opts in")
    }
}
