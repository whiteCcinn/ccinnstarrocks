import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private typealias F = BackupFixtures

private func samplePayload() -> (BackupPayload, ConnectionProfile) {
    var profile = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(100))
    profile.mcpAccess = .readOnly
    profile.lastConnectedAt = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
    var knowledge = F.knowledge(notes: [F.note("n1", text: "line one\nline two", at: 10)], tables: [F.table("report")], refreshedAt: F.date(5))
    knowledge.relationships = [Relationship(from: .init(table: "report", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]),
                                            kind: .manyToOne, evidence: [Evidence(source: .naming, score: 55, at: F.date(1))])]
    let payload = BackupPayload(
        profiles: [profile],
        knowledge: BackupKnowledge(index: F.index(projects: [F.project("p1", path: "~/code/adx", remote: "github.com/org/adx")]),
                                   databases: [knowledge]),
        settings: ["appearance": .string("Dark"), "autoLimit": .int(5000), "updates.automaticallyCheck": .bool(false)],
        history: [BackupHistory(profile: profile.id, entries: [F.historyEntry("SELECT 1", at: 3)])])
    return (payload, profile)
}

private func encode(_ payload: BackupPayload, secrets: [UUID: BackupProfileSecrets] = [:], passphrase: String? = nil) throws -> Data {
    try BackupFormat.encode(payload, secrets: secrets, passphrase: passphrase, appVersion: "1.4.0", createdAt: F.referenceDate,
                            iterations: F.testIterations)
}

private func expectError(_ expected: BackupError, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected \(expected)")
    } catch let error as BackupError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Suite("Backup file format")
struct BackupFormatTests {
    @Test func everySectionSurvivesARoundTrip() throws {
        let (payload, _) = samplePayload()
        let data = try encode(payload)
        let bundle = try BackupFormat.decode(data)
        #expect(bundle.payload == payload, "dates, knowledge, settings and history come back exactly")
        #expect(bundle.header.format == "ccinnstarrocks-backup")
        #expect(bundle.header.formatVersion == 1)
        #expect(bundle.header.appVersion == "1.4.0")
        #expect(bundle.header.sections == ["profiles", "knowledge", "settings", "history"])
        #expect(bundle.header.secrets == nil)
        #expect(bundle.isAuthenticated == false)
        #expect(bundle.secrets.isEmpty)
        #expect(bundle.warnings.isEmpty)
    }

    @Test func fileIsAHeaderLineAndAPayloadLineWithItsHash() throws {
        let (payload, _) = samplePayload()
        let data = try encode(payload)
        let parts = try F.requireLines(data)
        let header = try #require(try JSONSerialization.jsonObject(with: parts.header) as? [String: Any])
        #expect(header["format"] as? String == "ccinnstarrocks-backup")
        #expect(header["format_version"] as? Int == 1)
        #expect(header["payload_bytes"] as? Int == parts.payload.count)
        #expect(header["payload_sha256"] as? String == F.sha256Hex(parts.payload))
        #expect(header["created_at"] as? String == "2027-01-15T08:00:00Z")
        #expect(!parts.payload.contains(0x0A), "the payload is one line")
        #expect(data.last == 0x0A)
    }

    @Test func secretsComeBackOnlyWithThePassphrase() throws {
        let (payload, profile) = samplePayload()
        let secrets = [profile.id: BackupProfileSecrets(password: F.password, sshSecret: F.sshSecret)]
        let data = try encode(payload, secrets: secrets, passphrase: F.passphrase)

        let opened = try BackupFormat.decode(data, passphrase: F.passphrase)
        #expect(opened.secrets == secrets)
        #expect(opened.isAuthenticated)
        #expect(opened.payload == payload)

        let skipped = try BackupFormat.decode(data)
        #expect(skipped.secrets.isEmpty)
        #expect(skipped.isAuthenticated == false)
        #expect(skipped.warnings.contains(.secretsNotImported))
    }

    @Test func secretsAreNeverWrittenInClearText() throws {
        let (payload, profile) = samplePayload()
        let secrets = [profile.id: BackupProfileSecrets(password: F.password, sshSecret: F.sshSecret)]
        for passphrase in [nil, F.passphrase] {
            let data = try encode(payload, secrets: secrets, passphrase: passphrase)
            #expect(!data.contains(F.password))
            #expect(!data.contains(F.sshSecret))
            #expect(!data.contains(F.passphrase))
        }
        let unencrypted = try BackupFormat.decode(try encode(payload, secrets: secrets))
        #expect(unencrypted.header.secrets == nil, "without a passphrase secrets are left out")
        #expect(!String(describing: secrets).contains(F.password), "descriptions never show secrets")
        #expect(!String(reflecting: secrets).contains(F.password))
    }

    @Test func aWrongPassphraseIsToldApartWithoutDecrypting() throws {
        let (payload, profile) = samplePayload()
        let data = try encode(payload, secrets: [profile.id: BackupProfileSecrets(password: F.password)], passphrase: F.passphrase)
        expectError(.wrongPassphrase) { _ = try BackupFormat.decode(data, passphrase: "incorrect horse battery") }
        // Garbage in the sealed box would fail decryption; the key check answers first.
        let garbage = try F.replacingHeader(of: data) { header in
            var secrets = header["secrets"] as? [String: Any] ?? [:]
            secrets["sealed"] = Data(repeating: 7, count: 64).base64EncodedString()
            header["secrets"] = secrets
        }
        expectError(.wrongPassphrase) { _ = try BackupFormat.decode(garbage, passphrase: "incorrect horse battery") }
        expectError(.modified) { _ = try BackupFormat.decode(garbage, passphrase: F.passphrase) }
    }

    @Test func aFlippedPayloadByteIsCorruption() throws {
        let (payload, _) = samplePayload()
        var data = try encode(payload)
        let parts = try F.requireLines(data)
        let target = data.count - 1 - parts.payload.count / 2
        data[target] ^= 0x01
        expectError(.corrupted) { _ = try BackupFormat.decode(data) }

        var truncated = try encode(payload)
        truncated.removeLast(10)
        expectError(.corrupted) { _ = try BackupFormat.decode(truncated) }
    }

    @Test func aChangedHostInAnEncryptedBackupRefusesTheSecrets() throws {
        let (payload, profile) = samplePayload()
        let data = try encode(payload, secrets: [profile.id: BackupProfileSecrets(password: F.password)], passphrase: F.passphrase)
        // The attacker redirects the host and recomputes the header's hash so the password would go to them.
        let redirected = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "\"fe.prod\"", with: "\"evil.example\"") }
        #expect(redirected != data)
        expectError(.modified) { _ = try BackupFormat.decode(redirected, passphrase: F.passphrase) }
        let untrusted = try BackupFormat.decode(redirected)
        #expect(untrusted.isAuthenticated == false, "without the passphrase it reads as unauthenticated")
        #expect(untrusted.secrets.isEmpty)
    }

    @Test func aChangedSealedBoxIsModification() throws {
        let (payload, profile) = samplePayload()
        let data = try encode(payload, secrets: [profile.id: BackupProfileSecrets(password: F.password)], passphrase: F.passphrase)
        let tampered = try F.replacingHeader(of: data) { header in
            var secrets = header["secrets"] as? [String: Any] ?? [:]
            var sealed = Data(base64Encoded: secrets["sealed"] as? String ?? "") ?? Data()
            sealed[sealed.count - 20] ^= 0x80
            secrets["sealed"] = sealed.base64EncodedString()
            header["secrets"] = secrets
        }
        expectError(.modified) { _ = try BackupFormat.decode(tampered, passphrase: F.passphrase) }
    }

    @Test func aPassphraseShorterThanTwelveCharactersIsRefused() throws {
        let (payload, _) = samplePayload()
        expectError(.passphraseTooShort) { _ = try encode(payload, passphrase: "short pass") }
        #expect(BackupFormat.isAcceptablePassphrase("twelve chars"))
        #expect(!BackupFormat.isAcceptablePassphrase("eleven char"))
    }

    @Test func aPassphraseWithoutSecretsStillAuthenticatesTheFile() throws {
        let (payload, _) = samplePayload()
        let data = try encode(payload, passphrase: F.passphrase)
        let bundle = try BackupFormat.decode(data, passphrase: F.passphrase)
        #expect(bundle.isAuthenticated && bundle.secrets.isEmpty)
        let plain = try BackupFormat.decode(try encode(payload), passphrase: F.passphrase)
        #expect(plain.isAuthenticated == false && plain.warnings.contains(.noSecretsInBackup))
    }

    @Test func theRealIterationCountDerivesAndOpens() async throws {
        let (payload, profile) = samplePayload()
        let secrets = [profile.id: BackupProfileSecrets(password: F.password)]
        let outcome = await onDedicatedThread { () -> Result<BackupBundle, BackupError> in
            do {
                let data = try BackupFormat.encode(payload, secrets: secrets, passphrase: F.passphrase)
                return .success(try BackupFormat.decode(data, passphrase: F.passphrase))
            } catch let error as BackupError {
                return .failure(error)
            } catch {
                return .failure(.malformed("unexpected"))
            }
        }
        let bundle = try outcome.get()
        #expect(bundle.header.secrets?.iterations == 600_000)
        #expect(bundle.header.secrets?.kdf == "pbkdf2-hmac-sha256")
        #expect(bundle.header.secrets?.cipher == "aes-256-gcm")
        #expect(bundle.secrets == secrets)
    }

    // MARK: Versions

    @Test func aNewerFormatIsRefusedAsSuch() throws {
        let data = F.file(payloadJSON: #"{"profiles":[],"layout":{"v":2}}"#, formatVersion: 2)
        expectError(.newerFormat(2)) { _ = try BackupFormat.decode(data) }
        // The version is checked before the rest of the header, whose shape may have changed.
        let reshaped = Data(#"{"format":"ccinnstarrocks-backup","format_version":3,"payload":"elsewhere"}"#.utf8) + Data("\n{}\n".utf8)
        expectError(.newerFormat(3)) { _ = try BackupFormat.decode(reshaped) }
    }

    @Test func aNewerKnowledgeSchemaIsSkippedWithAWarning() throws {
        let profile = F.profile(name: "prod", host: "fe.prod")
        let profileJSON = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        let json = #"{"profiles":[\#(profileJSON)],"knowledge":{"schemaVersion":2,"graph":{"nodes":[]}}}"#
        let bundle = try BackupFormat.decode(F.file(payloadJSON: json, sections: ["profiles", "knowledge"]))
        #expect(bundle.payload.knowledge == nil)
        #expect(bundle.payload.profiles.map(\.id) == [profile.id], "everything else still imports")
        #expect(bundle.warnings.contains(.newerKnowledgeSchema(2)))
    }

    @Test func aNewerDatabaseInsideTheKnowledgeSectionIsSkipped() throws {
        let (payload, _) = samplePayload()
        let data = try encode(payload)
        let newer = try F.replacingPayload(of: data) { text in
            text.replacingOccurrences(of: #""minReaderVersion":1,"notes""#, with: #""minReaderVersion":2,"notes""#)
        }
        let bundle = try BackupFormat.decode(newer)
        #expect(bundle.payload.knowledge?.databases.isEmpty == true)
        #expect(bundle.warnings.contains(.newerDatabaseSchema(F.databaseKey)))
    }

    @Test func unknownSectionsAreIgnoredWithAWarning() throws {
        let data = F.file(payloadJSON: #"{"profiles":[],"macros":[{"name":"x"}]}"#, sections: ["profiles", "macros"])
        let bundle = try BackupFormat.decode(data)
        #expect(bundle.payload.profiles.isEmpty)
        #expect(bundle.warnings == [.unknownSection("macros")])
    }

    // MARK: Hostile input

    @Test func oversizedInputIsRefusedBeforeReading() throws {
        let (payload, _) = samplePayload()
        let data = try encode(payload)
        expectError(.tooLarge) { _ = try BackupFormat.decode(data, passphrase: nil, maximumBytes: data.count - 1) }

        let url = F.temporaryDirectory().appendingPathComponent("huge.ccinnstarrocks-backup")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(BackupFormat.maximumFileBytes) + 1) // sparse: no disk space used
        try handle.close()
        expectError(.tooLarge) { _ = try BackupFormat.read(contentsOf: url) }
        // A link describes itself as small; its target is what gets read.
        let link = url.deletingLastPathComponent().appendingPathComponent("small-looking.ccinnstarrocks-backup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        expectError(.tooLarge) { _ = try BackupFormat.read(contentsOf: link) }
        expectError(.notABackup) { _ = try BackupFormat.read(contentsOf: url.deletingLastPathComponent()) }
    }

    @Test func malformedInputIsRefused() throws {
        expectError(.notABackup) { _ = try BackupFormat.decode(Data()) }
        expectError(.notABackup) { _ = try BackupFormat.decode(Data("no newline at all".utf8)) }
        expectError(.notABackup) { _ = try BackupFormat.decode(Data("{not json\n{}\n".utf8)) }
        expectError(.notABackup) { _ = try BackupFormat.decode(Data(#"{"format":"something-else","format_version":1}"#.utf8) + Data("\n{}\n".utf8)) }
        expectError(.notABackup) { _ = try BackupFormat.decode(Data([0xFF, 0xFE, 0x0A, 0x00])) }
        let notJSON = F.file(payloadJSON: "{\"profiles\": [")
        #expect(throws: BackupError.self) { try BackupFormat.decode(notJSON) }
        let wrongType = F.file(payloadJSON: #"{"profiles":{"id":"x"}}"#)
        #expect(throws: BackupError.self) { try BackupFormat.decode(wrongType) }
        let badHash = try F.replacingHeader(of: F.file(payloadJSON: #"{"profiles":[]}"#)) { $0["payload_sha256"] = "zz" }
        #expect(throws: BackupError.self) { try BackupFormat.decode(badHash) }
        let negative = try F.replacingHeader(of: F.file(payloadJSON: #"{"profiles":[]}"#)) { $0["payload_bytes"] = -5 }
        #expect(throws: BackupError.self) { try BackupFormat.decode(negative) }
        // Deep nesting in an unknown section must not exhaust the stack.
        let depth = 100_000
        let nested = #"{"profiles":[],"x":"# + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}"
        #expect(throws: BackupError.self) { try BackupFormat.decode(F.file(payloadJSON: nested)) }
    }

    @Test func controlCharactersAreRefused() throws {
        let (payload, _) = samplePayload()
        let data = try encode(payload)
        let bell = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "\"fe.prod\"", with: "\"fe\\u0007prod\"") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(bell) }
        let newlineInHost = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "\"fe.prod\"", with: "\"fe\\nprod\"") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(newlineInHost) }
        let nulInNote = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "line one", with: "line\\u0000one") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(nulInNote) }
        let c1InName = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "\"prod\"", with: "\"pr\u{85}od\"") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(c1InName) }
        // An escaped backslash before "u0000" is text, not a control character.
        let escapedBackslash = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "line one", with: "C:\\\\u0000 one") }
        _ = try BackupFormat.decode(escapedBackslash)
        // Notes may span lines.
        #expect(try BackupFormat.decode(data).payload.knowledge?.databases.first?.notes.first?.text == "line one\nline two")
    }

    @Test func invalidPortsHostsAndPathsAreRefused() throws {
        let (payload, _) = samplePayload()
        let data = try encode(payload)
        let port = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "\"port\":9030", with: "\"port\":70000") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(port) }
        let option = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "\"fe.prod\"", with: "\"-oProxyCommand=evil\"") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(option) }
        let relative = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "~/code/adx", with: "code/adx") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(relative) }
        let traversal = try F.replacingPayload(of: data) { $0.replacingOccurrences(of: "~/code/adx", with: "~/code/../../etc") }
        #expect(throws: BackupError.self) { try BackupFormat.decode(traversal) }
        let duplicate = try F.replacingPayload(of: data) { text in
            guard let start = text.range(of: "\"profiles\":[")?.upperBound, let end = text.range(of: "}],\"settings\"")?.lowerBound else { return text }
            let profile = String(text[start...end])
            return text.replacingCharacters(in: start...end, with: profile + "," + profile)
        }
        #expect(throws: BackupError.self) { try BackupFormat.decode(duplicate) }
    }

    @Test func historyForAProfileNotInTheBackupIsDropped() throws {
        let (payload, _) = samplePayload()
        var orphaned = payload
        let stranger = UUID()
        orphaned.history = [BackupHistory(profile: stranger, entries: [F.historyEntry("SELECT 2", at: 1)])]
        let bundle = try BackupFormat.decode(try encode(orphaned))
        #expect(bundle.payload.history?.isEmpty == true)
        #expect(bundle.warnings.contains(.historyForUnknownProfile(stranger)))
    }

    @Test func fileWritesArePrivate() throws {
        let (payload, _) = samplePayload()
        let url = F.temporaryDirectory().appendingPathComponent("settings.ccinnstarrocks-backup")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try BackupFormat.write(try encode(payload), to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try BackupFormat.read(contentsOf: url).payload == payload)
    }

    @Test func errorsDescribeThemselvesWithoutSecrets() {
        let errors: [BackupError] = [.tooLarge, .notABackup, .newerFormat(2), .corrupted, .malformed("x"), .invalid("y"), .passphraseTooShort,
                                     .wrongPassphrase, .modified, .unsupportedEncryption("rot13"), .cryptographyUnavailable]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
