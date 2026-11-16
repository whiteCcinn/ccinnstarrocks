import Foundation
import Testing
@testable import CcinnStarRocksKit

@Suite("Run confirmation")
struct RunConfirmationTests {
    @Test func settingChangesAlwaysNeedConfirmation() throws {
        let confirmation = try #require(RunConfirmation.required(for: ["SET GLOBAL query_timeout = 600"], confirmMutations: false))
        #expect(confirmation.changesSettings)
        #expect(confirmation.title == "Change cluster settings?")
        #expect(confirmation.confirmLabel == "Change Settings")
        #expect(confirmation.statements == ["SET GLOBAL query_timeout = 600"])
        #expect(confirmation.message.contains("new sessions"))
    }

    @Test func dataChangesFollowTheConnectionOption() throws {
        #expect(RunConfirmation.required(for: ["INSERT INTO t VALUES (1)"], confirmMutations: false) == nil)
        let asked = try #require(RunConfirmation.required(for: ["INSERT INTO t VALUES (1)"], confirmMutations: true))
        #expect(!asked.changesSettings)
        #expect(asked.title == "Run statements that change data or schema?")
        #expect(asked.confirmLabel == "Run")
    }

    @Test func readsNeverAsk() {
        #expect(RunConfirmation.required(for: ["SELECT 1", "SHOW VARIABLES", "SET query_timeout = 10"], confirmMutations: true) == nil)
        #expect(RunConfirmation.required(for: [], confirmMutations: true) == nil)
    }

    @Test func aBatchListsEveryChangeAndExplainsEachKindOnce() throws {
        let statements = ["SELECT 1", "SET GLOBAL a = 1", "INSERT INTO t VALUES (1)",
                          "UPDATE information_schema.be_configs SET VALUE = '1' WHERE NAME = 'x'", "SET GLOBAL b = 2"]
        let confirmation = try #require(RunConfirmation.required(for: statements, confirmMutations: false))
        #expect(confirmation.statements == Array(statements.dropFirst()), "every changing statement is shown, not only settings")
        #expect(confirmation.settingChanges == [.globalVariable, .backendConfig])
        #expect(confirmation.message.contains("be.conf"))
        #expect(confirmation.message.components(separatedBy: "new sessions").count == 2)
    }

    @Test func longBatchesArePreviewedCompactly() throws {
        let statements = (0..<8).map { "SET GLOBAL v\($0) = '\(String(repeating: "x", count: 400))'" }
        let confirmation = try #require(RunConfirmation.required(for: statements, confirmMutations: false))
        #expect(confirmation.message.contains("and 3 more"))
        #expect(confirmation.message.count < 2_000)
    }
}
