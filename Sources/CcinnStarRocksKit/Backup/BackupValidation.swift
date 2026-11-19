import Foundation

/// Step 6 of reading a backup: rules the decoded content must follow before anything is planned from it. A file that
/// breaks one is refused as a whole (`BackupError.invalid`); the message names the rule, never secret values.
enum BackupValidation {
    static let maximumProfiles = 10_000
    static let maximumDatabases = 10_000
    static let maximumProjects = 10_000
    static let maximumLinks = 100_000
    static let maximumHistoryEntries = 10_000
    static let maximumIdentifierLength = 1_024
    /// Generous multiples of the knowledge base's own limits; they bound the work a hostile file can cause.
    static let maximumClusters = 10_000
    static let maximumAliases = 256
    static let maximumTables = 50_000
    static let maximumRelationships = 100_000
    static let maximumEvidence = 100
    static let maximumCuratedItems = 50_000
    static let maximumTombstones = 500_000

    static func validate(_ payload: BackupPayload) throws {
        try validateProfiles(payload.profiles)
        if let knowledge = payload.knowledge { try validateKnowledge(knowledge) }
        for history in payload.history ?? [] {
            try require(history.entries.count <= maximumHistoryEntries, "too many history entries")
        }
    }

    static func validateHeader(_ header: BackupHeader) throws {
        try requireIdentifier(header.appVersion, "app version", maximumLength: 64)
        try require(header.sections.count <= 32, "too many sections")
        for section in header.sections { try requireIdentifier(section, "section name", maximumLength: 64) }
        try require(header.payloadBytes >= 0, "a negative payload length")
        let isHex = header.payloadSHA256.utf8.allSatisfy { (byte: UInt8) -> Bool in
            let isDigit: Bool = byte >= 0x30 && byte <= 0x39
            let isLetter: Bool = byte >= 0x61 && byte <= 0x66
            return isDigit || isLetter
        }
        let hasLength: Bool = header.payloadSHA256.utf8.count == 64
        try require(hasLength && isHex, "a malformed payload checksum")
    }

    // MARK: Profiles

    static func validateProfiles(_ profiles: [ConnectionProfile]) throws {
        try require(profiles.count <= maximumProfiles, "too many connections")
        var seen = Set<UUID>()
        for profile in profiles {
            try require(seen.insert(profile.id).inserted, "two connections share the id \(profile.id.uuidString)")
            try validate(profile)
        }
    }

    static func validate(_ profile: ConnectionProfile) throws {
        try requireHost(profile.host, "host")
        try require((1...65_535).contains(profile.port), "a port outside 1–65535")
        try requireIdentifier(profile.username, "user name")
        try requireIdentifier(profile.name, "connection name")
        try requireIdentifier(profile.defaultDatabase ?? "", "default database")
        try requireIdentifier(profile.defaultCatalog ?? "", "default catalog")
        let timeoutIsSane = profile.connectTimeout > 0 && profile.connectTimeout <= 3_600
        try require(timeoutIsSane, "a connect timeout outside 0–3600 seconds")
        guard let ssh = profile.ssh else { return }
        try requireHost(ssh.host, "SSH host")
        try require((1...65_535).contains(ssh.port), "an SSH port outside 1–65535")
        let user = ssh.username.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { try requireHost(user, "SSH user name") }
        if let path = ssh.privateKeyPath, !path.isEmpty {
            try require(BackupPaths.isAcceptable(path), "an SSH key path that is not absolute or ~-relative")
        }
    }

    // MARK: Knowledge

    static func validateKnowledge(_ knowledge: BackupKnowledge) throws {
        let index = knowledge.index
        try require(index.format == KnowledgeIndex.formatName, "a knowledge index of another format")
        try require(knowledge.databases.count <= maximumDatabases && index.databases.count <= maximumDatabases, "too many databases")
        try require(index.projects.count <= maximumProjects, "too many projects")
        try require(index.links.count <= maximumLinks, "too many project links")
        try require(index.clusters.count <= maximumClusters, "too many clusters")
        try require(index.tombstones.count <= maximumTombstones, "too many deleted items")
        for cluster in index.clusters {
            try require(cluster.aliases.count <= maximumAliases, "a cluster with too many aliases")
            try requireClusterKey(cluster.key)
            for alias in cluster.aliases { try requireClusterKey(alias) }
            try requireIdentifier(cluster.label ?? "", "cluster label")
            try requireIdentifier(cluster.starrocksClusterID ?? "", "cluster id")
        }
        for entry in index.databases { try requireDatabaseKey(entry.key) }
        var projectIDs = Set<String>()
        for project in index.projects {
            try require(!project.id.isEmpty, "a project without an id")
            try requireIdentifier(project.id, "project id", maximumLength: 128)
            try require(projectIDs.insert(project.id).inserted, "two projects share an id")
            try require(BackupPaths.isAcceptable(project.path), "a project path that is not absolute or ~-relative")
            try requireIdentifier(project.name, "project name")
            try requireIdentifier(project.gitRemote ?? "", "git remote", maximumLength: 2_048)
            try requireIdentifier(project.addedBy, "project author")
        }
        for link in index.links {
            try requireIdentifier(link.project, "link project", maximumLength: 128)
            try requireIdentifier(link.database, "link database", maximumLength: 128)
        }
        var keys = Set<DatabaseKey>()
        for database in knowledge.databases {
            try require(database.format == DatabaseKnowledge.formatName, "knowledge of another format")
            try requireDatabaseKey(database.key)
            try require(keys.insert(database.key).inserted, "two knowledge files for \(database.key)")
            try validateLimits(database)
            for table in database.tables { try requireIdentifier(table.name, "table name") }
        }
    }

    private static func validateLimits(_ database: DatabaseKnowledge) throws {
        try require(database.tables.count <= maximumTables, "too many tables in \(database.key)")
        try require(database.relationships.count <= maximumRelationships, "too many relationships in \(database.key)")
        let curated: Int = database.notes.count + database.terms.count + database.areas.count
        try require(curated <= maximumCuratedItems, "too many notes, terms and areas in \(database.key)")
        try require(database.tombstones.count <= maximumTombstones, "too many deleted items in \(database.key)")
        let evidenceIsBounded = database.relationships.allSatisfy { $0.evidence.count <= maximumEvidence }
        try require(evidenceIsBounded, "a relationship with too much evidence in \(database.key)")
    }

    static func requireClusterKey(_ key: ClusterKey) throws {
        try requireIdentifier(key.rawValue, "cluster key")
        try require(!key.rawValue.contains(where: \.isWhitespace), "a cluster key with spaces")
    }

    static func requireDatabaseKey(_ key: DatabaseKey) throws {
        try requireClusterKey(key.cluster)
        try requireIdentifier(key.catalog, "catalog name")
        try requireIdentifier(key.database, "database name")
    }

    // MARK: Rules

    /// Hosts and SSH user names: not empty, no whitespace or control characters, never option-like (`-o…`).
    static func requireHost(_ value: String, _ what: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        try require(!trimmed.isEmpty, "an empty \(what)")
        try require(trimmed.utf8.count <= 255, "a \(what) longer than 255 bytes")
        try require(!trimmed.hasPrefix("-"), "a \(what) that looks like a command-line option")
        try require(!trimmed.contains(where: \.isWhitespace) && !containsControlCharacter(trimmed), "a \(what) with spaces or control characters")
        try require(!containsBidiControl(trimmed), "a \(what) with text-direction controls")
    }

    /// Names and other one-line values: no control characters (not even tabs or newlines), no text-direction controls.
    static func requireIdentifier(_ value: String, _ what: String, maximumLength: Int = maximumIdentifierLength) throws {
        try require(value.utf8.count <= maximumLength, "a \(what) longer than \(maximumLength) bytes")
        try require(!containsControlCharacter(value), "a \(what) with control characters")
        try require(!containsBidiControl(value), "a \(what) with text-direction controls")
    }

    static func require(_ condition: Bool, _ rule: @autoclosure () -> String) throws {
        guard condition else { throw BackupError.invalid(rule()) }
    }

    /// C0 and C1 control characters, DEL included.
    static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }

    static func containsBidiControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
            (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
        }
    }

    /// Whether any JSON string in `json` holds a control character other than tab, line feed or carriage return, written
    /// raw (DEL, C1) or escaped (`\u0000`, `\b`, `\f`). One pass over the bytes, so even free text (notes, statements) is
    /// checked without decoding twice. `\` never occurs inside a UTF-8 multi-byte sequence, so a byte scan is exact.
    static func jsonContainsForbiddenControlCharacter(_ json: Data) -> Bool {
        json.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var index = 0
            let count = bytes.count
            while index < count {
                let byte = bytes[index]
                if byte == 0x5C { // backslash
                    guard index + 1 < count else { return true }
                    let escaped = bytes[index + 1]
                    if escaped == 0x62 || escaped == 0x66 { return true } // \b \f
                    if escaped == 0x75 { // \uXXXX
                        guard index + 5 < count, let value = hexValue(bytes, from: index + 2) else { return true }
                        if isForbiddenControl(value) { return true }
                        index += 6
                        continue
                    }
                    index += 2
                    continue
                }
                if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { return true }
                if byte == 0x7F { return true }
                if byte == 0xC2, index + 1 < count, (0x80...0x9F).contains(bytes[index + 1]) { return true } // U+0080–U+009F
                index += 1
            }
            return false
        }
    }

    /// `json` with every forbidden control character (as `jsonContainsForbiddenControlCharacter` defines them) replaced
    /// by U+FFFD, so the writer never produces free text the reader refuses (a stray ESC pasted into a statement).
    static func replacingForbiddenControlCharacters(in json: Data) -> Data {
        guard jsonContainsForbiddenControlCharacter(json) else { return json }
        let replacement = Array(#"\ufffd"#.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(json.count + 64)
        json.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Void in
            var index = 0
            let count = bytes.count
            while index < count {
                let byte = bytes[index]
                if byte == 0x5C, index + 1 < count {
                    let escaped = bytes[index + 1]
                    if escaped == 0x62 || escaped == 0x66 { // \b \f
                        output.append(contentsOf: replacement)
                        index += 2
                        continue
                    }
                    if escaped == 0x75, index + 5 < count, let value = hexValue(bytes, from: index + 2) {
                        if isForbiddenControl(value) {
                            output.append(contentsOf: replacement)
                        } else {
                            output.append(contentsOf: bytes[index..<(index + 6)])
                        }
                        index += 6
                        continue
                    }
                    output.append(byte)
                    output.append(escaped)
                    index += 2
                    continue
                }
                if byte == 0x7F {
                    output.append(contentsOf: replacement)
                    index += 1
                    continue
                }
                if byte == 0xC2, index + 1 < count, (0x80...0x9F).contains(bytes[index + 1]) {
                    output.append(contentsOf: replacement)
                    index += 2
                    continue
                }
                output.append(byte)
                index += 1
            }
        }
        return Data(output)
    }

    private static func isForbiddenControl(_ value: UInt32) -> Bool {
        let isAllowedWhitespace = value == 0x09 || value == 0x0A || value == 0x0D
        if value < 0x20 { return !isAllowedWhitespace }
        return (0x7F...0x9F).contains(value)
    }

    private static func hexValue(_ bytes: UnsafeRawBufferPointer, from start: Int) -> UInt32? {
        var value: UInt32 = 0
        for offset in 0..<4 {
            let byte = bytes[start + offset]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }
}
