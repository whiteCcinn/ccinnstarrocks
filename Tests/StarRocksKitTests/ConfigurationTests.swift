import Foundation
import Testing
@testable import StarRocksKit

private func records(_ columns: [String], _ rows: [[String?]]) -> [Record] {
    let lookup = ColumnLookup(names: columns)
    return rows.map { Record(values: $0, lookup: lookup) }
}

@Suite("Configuration values")
struct ConfigValueTests {
    @Test(arguments: [("1", "1.0", true), ("true", "TRUE", true), (" 300 ", "300", true), ("1e3", "1000", true), ("-0", "0", true),
                      ("300", "301", false), ("abc", "ABC", false), ("", "", true), ("0x10", "16", false), ("inf", "inf", true),
                      ("1.5", "1.50", true), ("9223372036854775807", "9223372036854775807", true)])
    func equivalence(lhs: String, rhs: String, equal: Bool) {
        #expect(ConfigValue.equivalent(lhs, rhs) == equal)
    }
}

@Suite("Configuration items")
struct ConfigItemTests {
    @Test func variablesCombineGlobalValuesWithDefaults() {
        let global = records(["VARIABLE_NAME", "VARIABLE_VALUE"], [["query_timeout", "600"], ["SQL_AUTO_IS_NULL", "false"], ["init_connect", ""]])
        let verbose = records(["VARIABLE_NAME", "VARIABLE_VALUE", "DEFAULT_VALUE", "IS_CHANGED"],
                              [["query_timeout", "600", "300", "1"], ["SQL_AUTO_IS_NULL", "false", "false", "0"],
                               ["new_planner_optimize_timeout", "30000", "3000", "1"]])
        let items = ConfigItem.variables(global: global, verbose: verbose)
        #expect(items.map(\.name) == ["init_connect", "new_planner_optimize_timeout", "query_timeout", "SQL_AUTO_IS_NULL"])
        let timeout = items.first { $0.name == "query_timeout" }
        #expect(timeout?.value == "600")
        #expect(timeout?.defaultValue == "300")
        #expect(timeout?.isModified == true)
        #expect(timeout?.scope == .variables)
        #expect(timeout?.isMutable == nil, "StarRocks does not report read-only variables")
        #expect(items.first { $0.name == "SQL_AUTO_IS_NULL" }?.isModified == false)
        #expect(items.first { $0.name == "init_connect" }?.value == "", "empty values are values, not NULL")
        #expect(items.first { $0.name == "init_connect" }?.isModified == nil, "no default known")
        // Only in the (app connection's) session view: shown with the session value but no modified flag of its own making.
        let planner = items.first { $0.name == "new_planner_optimize_timeout" }
        #expect(planner?.value == "30000")
    }

    @Test func encodedDefaultsAreNotReportedAsChanges() {
        // `sql_mode` reports its default as a bitmask; StarRocks itself says it is unchanged.
        let verbose = records(["VARIABLE_NAME", "VARIABLE_VALUE", "DEFAULT_VALUE", "IS_CHANGED"],
                              [["sql_mode", "ONLY_FULL_GROUP_BY", "32", "0"], ["time_zone", "UTC", "Asia/Shanghai", "1"]])
        let global = records(["VARIABLE_NAME", "VARIABLE_VALUE"], [["sql_mode", "ONLY_FULL_GROUP_BY"], ["time_zone", "UTC"]])
        let items = ConfigItem.variables(global: global, verbose: verbose)
        #expect(items.first { $0.name == "sql_mode" }?.isModified == false)
        #expect(items.first { $0.name == "time_zone" }?.isModified == true)
    }

    @Test func listSpacingAndPathPlaceholdersAreNotChanges() {
        let rows = records(["BE_ID", "NAME", "VALUE", "TYPE", "DEFAULT", "MUTABLE"], [
            ["1", "s3_compatible_fs_list", "s3n://, s3a://, s3://", "string", "s3n://,s3a://,s3://", "0"],
            ["1", "storage_root_path", "/opt/starrocks/be/storage", "string", "${STARROCKS_HOME}/storage", "0"],
            ["1", "sys_log_level", "WARN", "string", "INFO", "1"],
        ])
        let items = ConfigItem.backend(rows, hosts: [:])
        #expect(items.first { $0.name == "s3_compatible_fs_list" }?.isModified == false)
        #expect(items.first { $0.name == "storage_root_path" }?.isModified == nil, "the default is a placeholder")
        #expect(items.first { $0.name == "sys_log_level" }?.isModified == true)
    }

    @Test func variablesFromShowStatementsFallback() {
        let global = records(["Variable_name", "Value"], [["query_timeout", "300"]])
        let items = ConfigItem.variables(global: global, verbose: [])
        #expect(items.map(\.value) == ["300"])
        #expect(items.first?.defaultValue == nil)
    }

    @Test func frontendConfigParsesAliasesAndMutability() {
        let rows = records(["Key", "AliasNames", "Value", "Type", "IsMutable", "Comment"], [
            ["label_keep_max_second", "[]", "259200", "int", "true", ""],
            ["meta_dir", "[]", "/opt/starrocks/fe/meta", "String", "false", "meta directory"],
            ["max_routine_load_task_num_per_be", "[max_routine_load_task_num, x]", "16", "int", "true", ""],
        ])
        let items = ConfigItem.frontend(rows)
        #expect(items.map(\.name) == ["label_keep_max_second", "max_routine_load_task_num_per_be", "meta_dir"])
        #expect(items[0].isMutable == true)
        #expect(items[0].isModified == nil, "FE config reports no defaults")
        #expect(items[1].aliases == ["max_routine_load_task_num", "x"])
        #expect(items[2].isMutable == false)
        #expect(items[2].comment == "meta directory")
        #expect(items[0].comment == nil)
    }

    @Test func backendConfigGroupsNodesAndFlagsDifferences() {
        let rows = records(["BE_ID", "NAME", "VALUE", "TYPE", "DEFAULT", "MUTABLE"], [
            ["10001", "alter_tablet_worker_count", "3", "int32", "3", "1"],
            ["10002", "alter_tablet_worker_count", "6", "int32", "3", "1"],
            ["10003", "alter_tablet_worker_count", "6", "int32", "3", "1"],
            ["10001", "agg_prefetch_l2_ratio", "1", "double", "1.0", "1"],
            ["10002", "agg_prefetch_l2_ratio", "1", "double", "1.0", "1"],
            // StarRocks 3.3 reports some names twice for the same backend.
            ["10001", "be_http_port", "8040", "int32", "8040", "0"],
            ["10001", "be_http_port", "8040", "int32", "8040", "0"],
        ])
        let items = ConfigItem.backend(rows, hosts: ["10001": "be-1", "10002": "be-2"])
        #expect(items.map(\.name) == ["agg_prefetch_l2_ratio", "alter_tablet_worker_count", "be_http_port"])
        let ratio = items[0]
        #expect(ratio.isModified == false, "1 and 1.0 are the same number")
        #expect(!ratio.differsAcrossNodes)
        let workers = items[1]
        #expect(workers.differsAcrossNodes)
        #expect(workers.value == "6", "most common value")
        #expect(workers.isModified == true)
        #expect(workers.nodes.map(\.nodeID) == ["10001", "10002", "10003"])
        #expect(workers.nodes.map(\.host) == ["be-1", "be-2", nil])
        #expect(workers.isMutable == true)
        let port = items[2]
        #expect(port.isMutable == false)
        #expect(port.nodes.count == 2)
        #expect(!port.differsAcrossNodes)
    }

    @Test func aTieBetweenNodeValuesPrefersTheDefault() {
        let rows = records(["BE_ID", "NAME", "VALUE", "DEFAULT"], [["1", "x", "5", "4"], ["2", "x", "4", "4"]])
        let item = ConfigItem.backend(rows, hosts: [:]).first
        #expect(item?.value == "4")
        #expect(item?.isModified == false)
        #expect(item?.differsAcrossNodes == true)
    }

    @Test func searchMatchesNameAliasValueAndComment() {
        let item = ConfigItem(scope: .frontend, name: "max_routine_load_task_num_per_be", value: "16", aliases: ["legacy_name"], comment: "Per backend")
        #expect(item.matches("ROUTINE"))
        #expect(item.matches("legacy"))
        #expect(item.matches("16"))
        #expect(item.matches("per backend"))
        #expect(item.matches("  "))
        #expect(!item.matches("timeout"))
    }
}

@Suite("Configuration edit statements")
struct ConfigStatementTests {
    @Test func variableStatementsQuoteOnlyNonScalars() {
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .variables, name: "query_timeout", value: "300"))?.hasSuffix("SET GLOBAL query_timeout = 300;") == true)
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .variables, name: "enable_profile", value: "false"))?.hasSuffix("SET GLOBAL enable_profile = false;") == true)
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .variables, name: "time_zone", value: "Asia/Kuala_Lumpur"))?
            .hasSuffix("SET GLOBAL time_zone = 'Asia/Kuala_Lumpur';") == true)
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .variables, name: "sql_mode", value: "it's"))?.hasSuffix("SET GLOBAL sql_mode = 'it''s';") == true)
    }

    @Test func frontendAndBackendStatements() {
        let fe = ConfigStatement.edit(for: ConfigItem(scope: .frontend, name: "label_keep_max_num", value: "1000", isMutable: true))
        #expect(fe?.hasSuffix("ADMIN SET FRONTEND CONFIG ('label_keep_max_num' = '1000');") == true)
        #expect(fe?.hasPrefix("-- ") == true)
        let be = ConfigStatement.edit(for: ConfigItem(scope: .backend, name: "alter_tablet_worker_count", value: "3", isMutable: true))
        #expect(be?.hasSuffix("UPDATE information_schema.be_configs SET VALUE = '3' WHERE NAME = 'alter_tablet_worker_count';") == true)
    }

    @Test func immutableOrUnsafeNamesHaveNoStatement() {
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .frontend, name: "meta_dir", value: "/x", isMutable: false)) == nil)
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .backend, name: "x", value: "1", isMutable: nil)) == nil)
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .variables, name: "a; DROP TABLE t", value: "1")) == nil)
        #expect(ConfigStatement.edit(for: ConfigItem(scope: .variables, name: "1abc", value: "1")) == nil)
    }
}

@Suite("Configuration against a server")
struct ConfigurationClientTests {
    private func connect(_ cluster: FakeCluster) async throws -> StarRocksClient {
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", connectTimeout: 2)
        return try await StarRocksClient.connect(configuration, poolSize: 1, transportFactory: cluster.transportFactory)
    }

    private static func denied() -> FakeMySQLServer.Reply {
        .packets([FakeMySQLServer.error(code: 5203, state: "42000", message: "Access denied; you need (at least one of) the OPERATE privilege(s) on SYSTEM")])
    }

    @Test func variablesFallBackToShowStatements() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("information_schema") { return .packets([FakeMySQLServer.error(code: 1064, message: "Unknown table")]) }
            if sql == "SHOW GLOBAL VARIABLES" {
                return .packets(FakeMySQLServer.resultSet([("Variable_name", .varString), ("Value", .varString)], [["query_timeout", "300"]]))
            }
            return .packets([FakeMySQLServer.ok()])
        }
        let client = try await connect(cluster)
        let items = try await client.variables()
        #expect(items.map(\.name) == ["query_timeout"])
        await client.close()
    }

    @Test func privilegeErrorsSurfaceForConfiguration() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("FRONTEND CONFIG") || sql.contains("be_configs") || sql.hasPrefix("SHOW BACKENDS") || sql.hasPrefix("SHOW COMPUTE") {
                return Self.denied()
            }
            return .packets([FakeMySQLServer.ok()])
        }
        let client = try await connect(cluster)
        await #expect { _ = try await client.frontendConfig() } throws: { ($0 as? StarRocksError)?.message.contains("OPERATE") == true }
        await #expect { _ = try await client.backendConfig() } throws: { ($0 as? StarRocksError)?.message.contains("OPERATE") == true }
        await client.close()
    }

    @Test func backendConfigMapsNodeHosts() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("be_configs") {
                return .packets(FakeMySQLServer.resultSet([("BE_ID", .varString), ("NAME", .varString), ("VALUE", .varString)], [["10001", "x", "1"], ["10002", "x", "1"]]))
            }
            if sql == "SHOW BACKENDS" {
                return .packets(FakeMySQLServer.resultSet([("BackendId", .varString), ("IP", .varString)], [["10001", "10.0.0.1"]]))
            }
            if sql == "SHOW COMPUTE NODES" {
                return .packets(FakeMySQLServer.resultSet([("ComputeNodeId", .varString), ("IP", .varString)], [["10002", "10.0.0.2"]]))
            }
            return .packets([FakeMySQLServer.ok()])
        }
        let client = try await connect(cluster)
        let items = try await client.backendConfig()
        #expect(items.first?.nodes.map(\.host) == ["10.0.0.1", "10.0.0.2"])
        await client.close()
    }
}
