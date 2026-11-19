import Foundation

/// Paths in backups: stored `~/…` when under the home directory, so they survive a move to a Mac with another user name.
/// Prefixes always match whole path components (`/Users/old` never matches `/Users/older`).
public enum BackupPaths {
    /// Longer paths are refused (`PATH_MAX` is 1024 on macOS).
    static let maximumLength = 1024

    /// `path` as `~` or `~/…` when it is under `home`; otherwise unchanged.
    public static func collapsingHome(_ path: String, home: String) -> String {
        let home = trimmingTrailingSlashes(home)
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// `~` and `~/…` under `home`; other paths (including `~user/…`) unchanged.
    public static func expandingHome(_ path: String, home: String) -> String {
        let home = trimmingTrailingSlashes(home)
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        return home + path.dropFirst(1)
    }

    /// `path` with its leading `prefix` replaced by `replacement`, written `~/…` under `home`; `nil` when the prefix does
    /// not match. The prefix may be written either way (`~/code` or `/Users/old/code`) and is tried against the path as
    /// stored and as expanded under `home`.
    public static func replacingPrefix(_ prefix: String, with replacement: String, in path: String, home: String) -> String? {
        let prefix = trimmingTrailingSlashes(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
        let replacement = trimmingTrailingSlashes(replacement.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !prefix.isEmpty, !replacement.isEmpty else { return nil }
        let candidates = [path, expandingHome(path, home: home)]
        let prefixes = [prefix, expandingHome(prefix, home: home)]
        for candidate in candidates {
            for form in prefixes {
                guard let rest = remainder(of: candidate, after: form) else { continue }
                let expanded = expandingHome(replacement, home: home) + rest
                return collapsingHome(expanded, home: home)
            }
        }
        return nil
    }

    /// Absolute or `~`-relative, without control characters or `..` components, at most 1024 bytes.
    public static func isAcceptable(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= maximumLength else { return false }
        guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else { return false }
        guard !BackupValidation.containsControlCharacter(path) else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// What follows `prefix` in `path` (empty, or starting with `/`), or `nil` when `prefix` is not a component prefix.
    private static func remainder(of path: String, after prefix: String) -> String? {
        let path = trimmingTrailingSlashes(path)
        if path == prefix { return "" }
        guard path.hasPrefix(prefix + "/") else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
