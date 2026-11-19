import Foundation

/// The app settings a backup carries: a whitelist, each key with its type and range. Window state, the selected
/// settings tab and update bookkeeping (`updates.lastCheck`, `updates.skippedVersion`) belong to one Mac and are never
/// exported or imported.
public enum BackupSettings {
    enum Rule {
        case oneOf(Set<String>)
        case integer(ClosedRange<Int>)
        case boolean

        func accepts(_ value: BackupSettingValue) -> Bool {
            switch (self, value) {
            case let (.oneOf(allowed), .string(text)): allowed.contains(text)
            case let (.integer(range), .int(number)): range.contains(number)
            case (.boolean, .bool): true
            default: false
            }
        }
    }

    /// In the order the preview lists them.
    public static let keys = ["appearance", "autoLimit", "sqlFormatKeywordCase", "sqlFormatIndent", "updates.automaticallyCheck"]

    static let rules: [String: Rule] = [
        "appearance": .oneOf(["System", "Light", "Dark"]),
        "autoLimit": .integer(0...1_000_000),
        "sqlFormatKeywordCase": .oneOf(Set(SQLFormatOptions.KeywordCase.allCases.map(\.rawValue))),
        "sqlFormatIndent": .integer(1...8),
        "updates.automaticallyCheck": .boolean,
    ]

    /// The whitelisted settings that are set and valid, read through `value` (`UserDefaults.object(forKey:)` in the app).
    public static func snapshot(reading value: (String) -> Any?) -> [String: BackupSettingValue] {
        var settings: [String: BackupSettingValue] = [:]
        for key in keys {
            guard let rule = rules[key], let stored = value(key), let typed = typedValue(stored, for: rule), rule.accepts(typed) else { continue }
            settings[key] = typed
        }
        return settings
    }

    /// Whether `value` may be applied for `key`: the key is whitelisted and the value has its type and range.
    static func accepts(_ value: BackupSettingValue, forKey key: String) -> Bool {
        rules[key]?.accepts(value) ?? false
    }

    static func isWhitelisted(_ key: String) -> Bool {
        rules[key] != nil
    }

    /// Property-list values as stored by `UserDefaults` (`NSNumber` for numbers and booleans).
    private static func typedValue(_ stored: Any, for rule: Rule) -> BackupSettingValue? {
        switch rule {
        case .oneOf:
            return (stored as? String).map(BackupSettingValue.string)
        case .integer:
            guard let number = stored as? NSNumber, !isBoolean(number) else { return nil }
            let double = number.doubleValue
            guard double.rounded() == double, let integer = Int(exactly: double) else { return nil }
            return .int(integer)
        case .boolean:
            guard let number = stored as? NSNumber, isBoolean(number) else { return nil }
            return .bool(number.boolValue)
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
