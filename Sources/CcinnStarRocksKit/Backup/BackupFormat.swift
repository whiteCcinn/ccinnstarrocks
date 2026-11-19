import CryptoKit
import Foundation

/// Writes and reads `.ccinnstarrocks-backup` files: UTF-8, line 1 the header JSON, line 2 the payload JSON. The header
/// carries the exact length and SHA-256 of the payload bytes, so old backups never depend on how today's encoder
/// serializes.
///
/// Reading checks, in order: size; the split at the first newline; the header's `format`, then `format_version`; the
/// payload's length and hash; strict decoding; validation (ids, ports, control characters, paths); then the secrets.
public enum BackupFormat {
    public static let fileExtension = "ccinnstarrocks-backup"
    public static let maximumFileBytes = 256 << 20
    public static let minimumPassphraseLength = 12
    /// The header holds the sealed secrets; anything longer is not a header.
    static let maximumHeaderBytes = 4 << 20

    public static func isAcceptablePassphrase(_ passphrase: String) -> Bool {
        passphrase.count >= minimumPassphraseLength
    }

    // MARK: Writing

    /// The file's bytes. Secrets are sealed only with a passphrase (at least 12 characters); without one they are left
    /// out. A passphrase without secrets still authenticates the whole file.
    public static func encode(_ payload: BackupPayload, secrets: [UUID: BackupProfileSecrets] = [:], passphrase: String? = nil,
                              appVersion: String = AppInfo.version, createdAt: Date = Date()) throws -> Data {
        try encode(payload, secrets: secrets, passphrase: passphrase, appVersion: appVersion, createdAt: createdAt,
                   iterations: BackupCrypto.defaultIterations)
    }

    /// `iterations` lets tests derive keys quickly; every other caller uses the default.
    static func encode(_ payload: BackupPayload, secrets: [UUID: BackupProfileSecrets], passphrase: String?, appVersion: String,
                       createdAt: Date, iterations: Int) throws -> Data {
        if let passphrase, !isAcceptablePassphrase(passphrase) { throw BackupError.passphraseTooShort }
        let payloadData: Data
        do {
            payloadData = try payloadEncoder.encode(payload)
        } catch {
            throw BackupError.malformed("the content cannot be encoded")
        }
        let digest = sha256Hex(payloadData)
        var envelope: BackupSecretsEnvelope?
        if let passphrase {
            var plaintext = try encodeSecrets(secrets)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            envelope = try BackupCrypto.seal(plaintext, passphrase: passphrase, payloadSHA256: digest, iterations: iterations)
        }
        let header = BackupHeader(createdAt: createdAt, appVersion: appVersion, sections: payload.sections.map(\.rawValue),
                                  payloadBytes: payloadData.count, payloadSHA256: digest, secrets: envelope)
        let headerData = try headerEncoder.encode(header)
        let total: Int = headerData.count + payloadData.count + 2
        guard total <= maximumFileBytes else { throw BackupError.tooLarge }
        var file = Data(capacity: total)
        file.append(headerData)
        file.append(0x0A)
        file.append(payloadData)
        file.append(0x0A)
        return file
    }

    /// Writes the file 0600, atomically (`SecureFile`).
    public static func write(_ data: Data, to url: URL) throws {
        try SecureFile.write(data, to: url)
    }

    // MARK: Reading

    /// Reads a regular file (symbolic links resolved), refusing one larger than the limit before loading it. The read
    /// itself is bounded too, so a file that grows meanwhile is still refused.
    public static func read(contentsOf url: URL, passphrase: String? = nil) throws -> BackupBundle {
        let resolved = url.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw BackupError.notABackup }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        let size: UInt64 = try handle.seekToEnd()
        guard size <= UInt64(maximumFileBytes) else { throw BackupError.tooLarge }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw BackupError.tooLarge }
        return try decode(data, passphrase: passphrase)
    }

    /// Decodes and verifies a file. With a passphrase the secrets are opened (`wrongPassphrase`, `modified`); without
    /// one everything else is returned, unauthenticated.
    public static func decode(_ data: Data, passphrase: String? = nil) throws -> BackupBundle {
        try decode(data, passphrase: passphrase, maximumBytes: maximumFileBytes)
    }

    static func decode(_ data: Data, passphrase: String?, maximumBytes: Int) throws -> BackupBundle {
        // 1–2. Size, then the split at the first newline.
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        let searchEnd = data.index(data.startIndex, offsetBy: min(data.count, maximumHeaderBytes + 1))
        guard let newline = data[data.startIndex..<searchEnd].firstIndex(of: 0x0A) else { throw BackupError.notABackup }
        let headerData = data[data.startIndex..<newline]
        var payloadData = data[data.index(after: newline)..<data.endIndex]
        if payloadData.last == 0x0A { payloadData = payloadData.dropLast() }

        // 3. Format, then version, before the rest of the header (whose shape a newer format may change).
        guard let probe = try? JSONDecoder().decode(HeaderProbe.self, from: headerData), probe.format == BackupHeader.formatName,
              let version = probe.formatVersion else { throw BackupError.notABackup }
        guard version <= BackupHeader.currentFormatVersion else { throw BackupError.newerFormat(version) }
        guard version == BackupHeader.currentFormatVersion else { throw BackupError.notABackup }
        let header: BackupHeader
        do {
            header = try headerDecoder.decode(BackupHeader.self, from: headerData)
        } catch {
            throw BackupError.malformed("the header: " + describe(error))
        }
        try BackupValidation.validateHeader(header)

        // 4. The payload is exactly what the header describes.
        guard header.payloadBytes == payloadData.count, sha256Hex(payloadData) == header.payloadSHA256 else { throw BackupError.corrupted }

        // 5. Strict decoding.
        let decoded: DecodedPayload
        do {
            decoded = try payloadDecoder.decode(DecodedPayload.self, from: payloadData)
        } catch {
            throw BackupError.malformed(describe(error))
        }

        // 6. Validation.
        guard !BackupValidation.jsonContainsForbiddenControlCharacter(payloadData) else { throw BackupError.invalid("text with control characters") }
        try BackupValidation.validate(decoded.payload)
        var warnings = unknownSectionWarnings(header: header, decoded: decoded)
        let payload = droppingUnusable(decoded, warnings: &warnings)

        // 7. Secrets.
        var secrets: [UUID: BackupProfileSecrets] = [:]
        var isAuthenticated = false
        if let passphrase {
            if let envelope = header.secrets {
                var plaintext = try BackupCrypto.open(envelope, passphrase: passphrase, payloadSHA256: header.payloadSHA256)
                defer { plaintext.resetBytes(in: 0..<plaintext.count) }
                secrets = try decodeSecrets(plaintext, profiles: Set(payload.profiles.map(\.id)), warnings: &warnings)
                isAuthenticated = true
            } else {
                warnings.append(.noSecretsInBackup)
            }
        } else if header.secrets != nil {
            warnings.append(.secretsNotImported)
        }
        return BackupBundle(header: header, payload: payload, secrets: secrets, isAuthenticated: isAuthenticated, warnings: warnings)
    }

    // MARK: Sections

    private static func unknownSectionWarnings(header: BackupHeader, decoded: DecodedPayload) -> [BackupWarning] {
        var names: [String] = []
        for name in header.sections + decoded.unknownSections where BackupSection(rawValue: name) == nil && !names.contains(name) {
            names.append(name)
        }
        var warnings = names.map { (name: String) -> BackupWarning in .unknownSection(name) }
        if let version = decoded.newerKnowledgeSchema { warnings.append(.newerKnowledgeSchema(version)) }
        return warnings
    }

    /// Knowledge written by a newer schema and history of profiles not in the file are dropped with a warning.
    private static func droppingUnusable(_ decoded: DecodedPayload, warnings: inout [BackupWarning]) -> BackupPayload {
        var payload = decoded.payload
        let supported = KnowledgeStore.schemaVersion
        if let knowledge = payload.knowledge {
            let index = knowledge.index
            if index.schemaVersion > supported || index.minReaderVersion > supported {
                warnings.append(.newerKnowledgeSchema(index.schemaVersion))
                payload.knowledge = nil
            } else {
                var usable = knowledge
                usable.databases = knowledge.databases.filter { (database: DatabaseKnowledge) -> Bool in
                    let isNewer = database.schemaVersion > supported || database.minReaderVersion > supported
                    if isNewer { warnings.append(.newerDatabaseSchema(database.key)) }
                    return !isNewer
                }
                payload.knowledge = usable
            }
        }
        if let history = payload.history {
            let profiles = Set(payload.profiles.map(\.id))
            payload.history = history.filter { (group: BackupHistory) -> Bool in
                let isKnown = profiles.contains(group.profile)
                if !isKnown { warnings.append(.historyForUnknownProfile(group.profile)) }
                return isKnown
            }
        }
        return payload
    }

    // MARK: Secrets

    /// `{"items":[{"profile":"<uuid>","password":"…","ssh_secret":"…"}]}`, in profile id order.
    private static func encodeSecrets(_ secrets: [UUID: BackupProfileSecrets]) throws -> Data {
        let items = secrets.filter { !$0.value.isEmpty }
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { SecretsPlaintext.Item(profile: $0.key, password: $0.value.password, sshSecret: $0.value.sshSecret) }
        do {
            return try JSONEncoder().encode(SecretsPlaintext(items: items))
        } catch {
            throw BackupError.cryptographyUnavailable
        }
    }

    /// Errors never describe the plaintext.
    private static func decodeSecrets(_ plaintext: Data, profiles: Set<UUID>, warnings: inout [BackupWarning]) throws -> [UUID: BackupProfileSecrets] {
        guard let decoded = try? JSONDecoder().decode(SecretsPlaintext.self, from: plaintext) else {
            throw BackupError.invalid("the encrypted passwords do not decode")
        }
        var secrets: [UUID: BackupProfileSecrets] = [:]
        for item in decoded.items {
            guard profiles.contains(item.profile) else {
                warnings.append(.secretsForUnknownProfile(item.profile))
                continue
            }
            guard secrets[item.profile] == nil else { throw BackupError.invalid("passwords appear twice for one connection") }
            let value = BackupProfileSecrets(password: item.password, sshSecret: item.sshSecret)
            if !value.isEmpty { secrets[item.profile] = value }
        }
        return secrets
    }

    private struct SecretsPlaintext: Codable {
        struct Item: Codable {
            var profile: UUID
            var password: String?
            var sshSecret: String?

            enum CodingKeys: String, CodingKey {
                case profile, password
                case sshSecret = "ssh_secret"
            }
        }

        var items: [Item]
    }

    // MARK: Coding

    /// Dates as `Date`'s own value (as `connections.json` stores them), so they round-trip exactly; sorted keys keep the
    /// output deterministic. No raw newline can occur: JSON escapes it inside strings.
    static var payloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var payloadDecoder: JSONDecoder { JSONDecoder() }

    static var headerEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var headerDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func sha256Hex(_ data: some DataProtocol) -> String {
        let hexDigits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Where decoding failed, by field path; never the values.
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "not valid JSON" }
        switch decoding {
        case let .typeMismatch(_, context): return "“\(path(context.codingPath))” has the wrong type"
        case let .valueNotFound(_, context): return "“\(path(context.codingPath))” is missing"
        case let .keyNotFound(key, context): return "“\(path(context.codingPath + [key]))” is missing"
        case let .dataCorrupted(context): return context.codingPath.isEmpty ? "not valid JSON" : "“\(path(context.codingPath))” is invalid"
        @unknown default: return "not valid JSON"
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        var text = ""
        for key in keys {
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += text.isEmpty ? key.stringValue : "." + key.stringValue
            }
        }
        return text
    }
}

// MARK: - Decoding helpers

/// `format` and `format_version` only, read before the header's full shape.
private struct HeaderProbe: Decodable {
    let format: String?
    let formatVersion: Int?

    enum CodingKeys: String, CodingKey {
        case format
        case formatVersion = "format_version"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try? container.decodeIfPresent(String.self, forKey: .format)
        formatVersion = try? container.decodeIfPresent(Int.self, forKey: .formatVersion)
    }
}

/// The payload with the names of sections this version does not know and a knowledge section of a newer schema, which
/// is not decoded at all (its shape may have changed).
private struct DecodedPayload: Decodable {
    let payload: BackupPayload
    let unknownSections: [String]
    let newerKnowledgeSchema: Int?

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ name: String) {
            stringValue = name
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    private struct KnowledgeVersion: Decodable {
        let schemaVersion: Int
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let known = Set(BackupSection.allCases.map(\.rawValue))
        unknownSections = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        let profiles = try container.decode([ConnectionProfile].self, forKey: Key(BackupSection.profiles.rawValue))
        let knowledgeKey = Key(BackupSection.knowledge.rawValue)
        var knowledge: BackupKnowledge?
        var newerSchema: Int?
        if container.contains(knowledgeKey), try !container.decodeNil(forKey: knowledgeKey) {
            let version = try container.decode(KnowledgeVersion.self, forKey: knowledgeKey).schemaVersion
            if version > KnowledgeStore.schemaVersion {
                newerSchema = version
            } else {
                knowledge = try container.decode(BackupKnowledge.self, forKey: knowledgeKey)
            }
        }
        newerKnowledgeSchema = newerSchema
        let settings = try container.decodeIfPresent([String: BackupSettingValue].self, forKey: Key(BackupSection.settings.rawValue))
        let history = try container.decodeIfPresent([BackupHistory].self, forKey: Key(BackupSection.history.rawValue))
        payload = BackupPayload(profiles: profiles, knowledge: knowledge, settings: settings, history: history)
    }
}
