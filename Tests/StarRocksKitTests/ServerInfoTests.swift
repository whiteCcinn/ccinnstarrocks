import Foundation
import MySQLWire
import Testing
@testable import StarRocksKit

@Suite("Server info")
struct ServerInfoTests {
    private func load(_ handler: @escaping @Sendable (String) -> FakeMySQLServer.Reply) async throws -> ServerInfo {
        let server = FakeMySQLServer(handler: handler)
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake", port: 9030), username: "ccinn", password: "x", connectTimeout: 2)
        let connection = try await MySQLConnection.connect(configuration) { _, _ in server }
        return try await ServerInfo.load(from: connection)
    }

    /// The release from `current_version()` is trusted for version-dependent behaviour.
    @Test func theReleaseComesFromCurrentVersion() async throws {
        let info = try await load { sql in
            guard sql.contains("current_version()") else { return .packets([FakeMySQLServer.ok()]) }
            return .packets(FakeMySQLServer.resultSet([("v", .varString), ("u", .varString)], [["4.1.7-ee1a", "'root'@'%'"]]))
        }
        #expect(info.releaseVersion.map { [$0.major, $0.minor, $0.patch] } == [4, 1, 7])
        #expect(info.version == info.releaseVersion)
    }

    /// The `$$` gate trusts a release only when the text starts with `[v]major.minor[.patch][-suffix]`: a vendor-prefixed
    /// string would otherwise yield its first number run (`EMR-5.14.0-starrocks-3.2.8` → 5.14) and pass `>= 4.1` on an
    /// older server.
    @Test(arguments: [("4.1.7", [4, 1, 7]), ("v4.1.0-rc1", [4, 1, 0]), ("3.3.5-ee", [3, 3, 5]), ("3.3.22-753696f", [3, 3, 22]),
                      ("4.1.7-b81ff9c", [4, 1, 7]), ("4.1", [4, 1, 0])])
    func strictReleasesParse(text: String, expected: [Int]) {
        #expect(StarRocksVersion.strictRelease(text).map { [$0.major, $0.minor, $0.patch] } == expected, "\(text)")
    }

    @Test(arguments: ["EMR-5.14.0-starrocks-3.2.8", "2024.10-starrocks-3.3", "", "  ", "garbage", "starrocks-4.1.7", "4", "4.",
                      ".4.1", "4.1.7.9", "4.1.7 extra", "4.1.7-ee-3.3", "v", "V4.1.7", "4.1.7-", "4.1.x", "５.1"])
    func anythingElseIsUnknown(text: String) {
        #expect(StarRocksVersion.strictRelease(text) == nil, "\(text)")
        let info = ServerInfo(versionString: text, protocolVersion: "8.0.33", currentUser: nil, runMode: nil, fromCurrentVersion: true)
        #expect(info.releaseVersion == nil, "\(text)")
    }

    @Test func otherFeaturesKeepTheLooseParse() {
        let vendor = ServerInfo(versionString: "EMR-5.14.0-starrocks-3.2.8", protocolVersion: "8.0.33", currentUser: nil, runMode: nil)
        #expect(vendor.version.map { [$0.major, $0.minor] } == [5, 14], "labels unchanged")
        #expect(vendor.releaseVersion == nil)
    }

    /// When `current_version()` fails, the version falls back to `@@version_comment` or to the handshake's
    /// MySQL-compatible version (3.3 announces 5.1.0, 4.1 announces 8.0.33): a label, never a release that
    /// version-dependent behaviour (`$$` blocks) may rely on.
    @Test func fallbackVersionsAreNoRelease() async throws {
        let handshake = try await load { _ in .packets([FakeMySQLServer.error(code: 1064, message: "not supported")]) }
        #expect(handshake.versionString == "8.0.33")
        #expect(handshake.version != nil, "the label still parses")
        #expect(handshake.releaseVersion == nil)
        let commented = try await load { sql in
            guard sql.contains("version_comment") else { return .packets([FakeMySQLServer.error(code: 1064, message: "not supported")]) }
            return .packets(FakeMySQLServer.resultSet([("v", .varString)], [["4.1.7"]]))
        }
        #expect(commented.versionString == "4.1.7")
        #expect(commented.releaseVersion == nil)
    }
}
