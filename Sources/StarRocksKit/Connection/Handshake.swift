import Foundation
import MySQLWire

/// Connection phase: greeting → HandshakeResponse41 → (auth switch)* → OK.
enum Handshake {
    static func perform(transport: any ByteTransport, configuration: ConnectionConfiguration) async throws -> MySQLConnection {
        var channel = PacketChannel(transport: transport)
        let greetingPayload = try await channel.read()
        if greetingPayload.first == 0xFF {
            // Refused before the handshake (host blocked, too many connections).
            throw StarRocksError.server(try ServerPacket.parseError(greetingPayload))
        }
        let greeting = try HandshakeV10(payload: greetingPayload)
        guard greeting.capabilities.contains(.protocol41) else {
            throw StarRocksError(.protocolViolation, "\(configuration.endpoint) does not speak MySQL protocol 4.1")
        }

        let usesHandshakeDatabase = configuration.catalog.map { $0.isEmpty || $0 == SQLText.defaultCatalog } ?? true
        let database = configuration.database?.trimmingCharacters(in: .whitespaces)
        var capabilities = Capabilities.client.intersection(greeting.capabilities).union(.protocol41)
        if !usesHandshakeDatabase || database?.isEmpty != false { capabilities.remove(.connectWithDB) }

        let requestedPlugin = greeting.authPluginName ?? AuthPlugin.nativePasswordName
        let (plugin, token) = try authResponse(plugin: requestedPlugin, data: greeting.scramble, configuration: configuration,
                                              isSwitchRequest: false)
        let response = HandshakeResponse41(capabilities: capabilities, username: configuration.username, authResponse: token,
                                           database: capabilities.contains(.connectWithDB) ? database : nil,
                                           authPluginName: plugin, attributes: attributes(configuration))
        try await channel.write(response.encode())

        // Bounded: a hostile server cannot keep us switching plugins forever.
        for _ in 0..<4 {
            let reply = try await channel.read()
            switch try ServerPacket.parse(reply, capabilities: capabilities) {
            case .ok:
                return MySQLConnection(endpoint: configuration.endpoint, greeting: greeting, capabilities: capabilities, channel: channel)
            case let .error(packet):
                throw StarRocksError.server(packet)
            case let .authSwitch(newPlugin, data):
                let (_, switched) = try authResponse(plugin: newPlugin, data: data.isEmpty ? greeting.scramble : data,
                                                     configuration: configuration, isSwitchRequest: true)
                try await channel.write(switched)
            case let .authMoreData(data):
                // caching_sha2_password: 3 = fast auth succeeded (OK follows), 4 = full auth needs TLS/RSA.
                if data.first == 4 {
                    throw StarRocksError(.authentication, "The server requires caching_sha2_password full authentication, which needs TLS. Use a mysql_native_password user.")
                }
            case .eof, .other:
                throw StarRocksError(.protocolViolation, "Unexpected packet during authentication")
            }
        }
        throw StarRocksError(.protocolViolation, "Authentication did not complete")
    }

    static func authResponse(plugin: String, data: [UInt8], configuration: ConnectionConfiguration,
                             isSwitchRequest: Bool) throws -> (plugin: String, token: [UInt8]) {
        switch plugin {
        case AuthPlugin.clearPasswordName:
            guard configuration.allowCleartextPassword else {
                throw StarRocksError(.authentication, "The server asked for the password in clear text (mysql_clear_password, used by LDAP users). Enable “Allow clear-text password” for this connection, preferably over an SSH tunnel.")
            }
            return (plugin, AuthPlugin.clearPassword(password: configuration.password))
        case AuthPlugin.nativePasswordName:
            return (plugin, AuthPlugin.nativePassword(password: configuration.password, scramble: data))
        default:
            if isSwitchRequest {
                throw StarRocksError(.authentication, "Unsupported authentication plugin \(plugin)")
            }
            // Offer native password; servers using other defaults answer with an auth switch.
            return (AuthPlugin.nativePasswordName, AuthPlugin.nativePassword(password: configuration.password, scramble: data))
        }
    }

    static func attributes(_ configuration: ConnectionConfiguration) -> [(String, String)] {
        [("_client_name", String(configuration.applicationName.prefix(64))), ("_client_version", "1.0.0"), ("_os", "macOS")]
    }
}
