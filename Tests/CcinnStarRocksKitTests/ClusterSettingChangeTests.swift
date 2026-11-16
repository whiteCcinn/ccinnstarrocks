import Foundation
import Testing
@testable import CcinnStarRocksKit
import StarRocksKit

@Suite("Cluster setting changes")
struct ClusterSettingChangeTests {
    @Test(arguments: [
        "SET GLOBAL query_timeout = 300",
        "set global query_timeout=300;",
        "-- from the Configuration view\nSET GLOBAL time_zone = 'Asia/Kuala_Lumpur';",
        "/* c */ SET @@global.query_timeout = 300",
        "SET @@GLOBAL.query_timeout = 300",
        "SET query_timeout = 300, GLOBAL exec_mem_limit = 1",
    ])
    func globalVariables(sql: String) {
        #expect(ClusterSettingChange.of(sql) == .globalVariable)
    }

    @Test(arguments: [
        "ADMIN SET FRONTEND CONFIG ('label_keep_max_num' = '1000')",
        "admin set all frontends config ('a' = '1')",
    ])
    func frontendConfig(sql: String) {
        #expect(ClusterSettingChange.of(sql) == .frontendConfig)
    }

    @Test(arguments: [
        "UPDATE information_schema.be_configs SET VALUE = '3' WHERE NAME = 'alter_tablet_worker_count'",
        "update `information_schema`.`be_configs` set value = 1 where name = 'x'",
        "UPDATE BE_CONFIGS SET VALUE = 1 WHERE NAME = 'x'",
    ])
    func backendConfig(sql: String) {
        #expect(ClusterSettingChange.of(sql) == .backendConfig)
    }

    @Test(arguments: [
        "SET query_timeout = 300",
        "SET @@session.query_timeout = 300",
        "SET @@query_timeout = 300",
        "SET x = 'GLOBAL'",
        "SET global_flag = 1",
        "SET PASSWORD = PASSWORD('x')",
        "SET ROLE ALL",
        "ADMIN SHOW FRONTEND CONFIG",
        "ADMIN SET REPLICA STATUS PROPERTIES('tablet_id' = '1', 'backend_id' = '2', 'status' = 'bad')",
        "SELECT * FROM information_schema.be_configs",
        "SELECT 'SET GLOBAL x = 1'",
        "UPDATE shop.orders SET status = 'be_configs'",
        "-- SET GLOBAL x = 1\nSELECT 1",
        "",
    ])
    func otherStatements(sql: String) {
        #expect(ClusterSettingChange.of(sql) == nil)
    }

    /// Every statement the Configuration view pre-fills must be caught.
    @Test(arguments: [(ConfigItem.Scope.variables, ClusterSettingChange.globalVariable),
                      (.frontend, .frontendConfig), (.backend, .backendConfig)])
    func editStatementsFromTheConfigurationView(scope: ConfigItem.Scope, expected: ClusterSettingChange) throws {
        let statement = try #require(ConfigStatement.edit(for: ConfigItem(scope: scope, name: "query_timeout", value: "300", isMutable: true)))
        #expect(ClusterSettingChange.of(statement) == expected)
    }
}
