import Foundation

/// Everything needed to open one authenticated MySQL-protocol session to a StarRocks FE.
public struct ConnectionConfiguration: Sendable, Equatable {
    public var endpoint: Endpoint
    public var username: String
    public var password: String
    /// Initial database (`USE`), optional.
    public var database: String?
    /// Initial catalog (`SET CATALOG`), optional; `nil` keeps `default_catalog`.
    public var catalog: String?
    public var connectTimeout: Double
    /// Allows answering a server request for `mysql_clear_password` (LDAP users). The password is
    /// sent in clear text, so this should only be enabled over an SSH tunnel or a trusted network.
    public var allowCleartextPassword: Bool
    public var applicationName: String

    public init(endpoint: Endpoint, username: String, password: String = "", database: String? = nil, catalog: String? = nil,
                connectTimeout: Double = 10, allowCleartextPassword: Bool = false, applicationName: String = "CcinnStarRocks") {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.database = database
        self.catalog = catalog
        self.connectTimeout = connectTimeout
        self.allowCleartextPassword = allowCleartextPassword
        self.applicationName = applicationName
    }

    /// Same configuration pointed at another endpoint (used for SSH tunnels).
    public func with(endpoint: Endpoint) -> ConnectionConfiguration {
        var copy = self
        copy.endpoint = endpoint
        return copy
    }
}
