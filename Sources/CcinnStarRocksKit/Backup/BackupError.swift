import Foundation

/// Why a backup could not be written or read. Descriptions never include secrets or the passphrase.
public enum BackupError: Error, Equatable, LocalizedError {
    /// Larger than `BackupFormat.maximumFileBytes`.
    case tooLarge
    /// Not a CcinnStarRocks backup (no header line, or a different `format`).
    case notABackup
    /// Written by a newer CcinnStarRocks in a format this version cannot read.
    case newerFormat(Int)
    /// The payload's length or SHA-256 differs from the header's.
    case corrupted
    /// The content does not decode.
    case malformed(String)
    /// The content decodes but breaks a rule (ports, ids, control characters, paths).
    case invalid(String)
    /// Backups with secrets need a passphrase of at least `BackupFormat.minimumPassphraseLength` characters.
    case passphraseTooShort
    /// The passphrase does not open the secrets; nothing was decrypted.
    case wrongPassphrase
    /// The passphrase is right but the file was changed after it was made, so its secrets are refused.
    case modified
    case unsupportedEncryption(String)
    /// The system's random generator or key derivation failed.
    case cryptographyUnavailable

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The backup is larger than 256 MB."
        case .notABackup: "This file is not a CcinnStarRocks backup."
        case let .newerFormat(version): "This backup was made by a newer CcinnStarRocks (format \(version)). Update the app to import it."
        case .corrupted: "The backup is damaged: its content does not match its checksum."
        case let .malformed(detail): "The backup cannot be read: \(detail)"
        case let .invalid(detail): "The backup contains invalid data: \(detail)"
        case .passphraseTooShort: "The passphrase must be at least \(BackupFormat.minimumPassphraseLength) characters."
        case .wrongPassphrase: "The passphrase is incorrect."
        case .modified: "The backup was modified after it was made. Its passwords cannot be imported."
        case let .unsupportedEncryption(name): "The backup's passwords use an unsupported encryption (\(name))."
        case .cryptographyUnavailable: "The system could not encrypt or decrypt the passwords. Try again."
        }
    }
}

/// Something worth telling the user that did not stop the export or import.
public enum BackupWarning: Sendable, Hashable, CustomStringConvertible {
    // Reading
    case unknownSection(String)
    case newerKnowledgeSchema(Int)
    case newerDatabaseSchema(DatabaseKey)
    /// The file has secrets but no passphrase was given.
    case secretsNotImported
    /// A passphrase was given but the file has no secrets.
    case noSecretsInBackup
    case secretsForUnknownProfile(UUID)
    case historyForUnknownProfile(UUID)
    // Planning
    case unsupportedSetting(String)
    case invalidSetting(String)
    case localKnowledgeNotWritable
    case localDatabaseNotWritable(DatabaseKey)
    case secretsNotChecked
    // Exporting
    case knowledgeNotExported(String)
    case databaseNotExported(DatabaseKey)
    case secretNotExported(String)
    case historyNotExported(String)
    // Restoring
    /// The snapshot does not hold this part (knowledge, settings or one database), so it was left as the import made it.
    case notRestored(String)
    /// The profile was edited after the import, so the restore left it as it is.
    case changedSinceImport(String)
    /// The import replaced this profile's password; the earlier one cannot be put back.
    case passwordNotRestored(String)
    /// The password the import stored was removed because the profile went back to its earlier server or SSH route.
    case passwordRemoved(String)

    public var description: String {
        switch self {
        case let .unknownSection(name): "The section “\(name)” is not known to this version and was ignored."
        case let .newerKnowledgeSchema(version):
            "Knowledge was skipped: it was written by a newer CcinnStarRocks (schema \(version)). Everything else imports."
        case let .newerDatabaseSchema(key): "Knowledge for \(key) was skipped: it was written by a newer CcinnStarRocks."
        case .secretsNotImported: "Passwords not imported: the backup's passphrase was not entered."
        case .noSecretsInBackup: "This backup contains no passwords."
        case let .secretsForUnknownProfile(id): "Passwords for an unknown connection (\(id.uuidString)) were ignored."
        case let .historyForUnknownProfile(id): "History for an unknown connection (\(id.uuidString)) was ignored."
        case let .unsupportedSetting(key): "The setting “\(key)” is not imported."
        case let .invalidSetting(key): "The setting “\(key)” has an invalid value and was ignored."
        case .localKnowledgeNotWritable: "Knowledge was skipped: this Mac's knowledge base was written by a newer CcinnStarRocks."
        case let .localDatabaseNotWritable(key): "Knowledge for \(key) was skipped: this Mac's copy cannot be changed by this version."
        case .secretsNotChecked: "Some passwords on this Mac could not be read; they are replaced only where you choose Use imported."
        case let .knowledgeNotExported(reason): "Knowledge was not included: \(reason)"
        case let .databaseNotExported(key): "Knowledge for \(key) could not be read and was not included."
        case let .secretNotExported(name): "The passwords of “\(name)” could not be read from the Keychain and were not included."
        case let .historyNotExported(name): "The history of “\(name)” could not be read and was not included."
        case let .notRestored(part): "The pre-import snapshot does not include \(part); it was left as the import made it."
        case let .changedSinceImport(name): "“\(name)” was changed after the import, so it was left as it is."
        case let .passwordNotRestored(name): "The import replaced the password of “\(name)”; the earlier one cannot be put back."
        case let .passwordRemoved(name):
            "“\(name)” is back on its earlier server, so the password the import stored for it was removed. Enter its password again."
        }
    }
}
