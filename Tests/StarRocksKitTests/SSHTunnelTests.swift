import Foundation
import Testing
@testable import StarRocksKit

@Suite("SSH tunnel arguments")
struct SSHTunnelArgumentTests {
    /// The tunnel neither becomes nor uses a shared connection from ~/.ssh/config, for every authentication mode:
    /// `ControlMaster=no` and `ControlPath=none` are both required, and no other ControlPath may be set.
    @Test(arguments: SSHTunnelConfiguration.Authentication.allCases)
    func tunnelsNeverUseOrBecomeASharedControlMaster(authentication: SSHTunnelConfiguration.Authentication) throws {
        let configuration = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: authentication,
                                                   privateKeyPath: authentication == .privateKey ? "~/.ssh/id_ed25519" : nil)
        let arguments = try SSHTunnel.arguments(for: configuration, localPort: 40_000, remote: Endpoint(host: "10.0.0.5", port: 9030))
        let options = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
        #expect(options.contains("ControlMaster=no"))
        #expect(options.contains("ControlPath=none"))
        let controlOptions = options.filter { $0.lowercased().hasPrefix("controlpath") || $0.lowercased().hasPrefix("controlmaster") }
        #expect(controlOptions == ["ControlMaster=no", "ControlPath=none"], "no other ControlMaster / ControlPath")
        #expect(!arguments.contains("-S"), "no control socket given another way")
        #expect(arguments.last == "ops@bastion", "the destination stays last")
    }
}
