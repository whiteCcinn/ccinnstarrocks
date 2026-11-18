import Foundation

/// The app's name, version and home on GitHub.
public enum AppInfo {
    public static let productName = "CcinnStarRocks"
    /// One line for the About window.
    public static let tagline = "A fast, native StarRocks client for macOS."
    /// Used when there is no app bundle (`swift run`); keep in step with `scripts/build-app.sh`.
    public static let fallbackVersion = "1.3.4"
    public static let repository = GitHubRepository(owner: "whiteCcinn", name: "ccinnstarrocks")

    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackVersion
    }

    /// The running version, or the fallback if the bundle's version is not a semantic version.
    public static var semanticVersion: SemanticVersion {
        SemanticVersion(version) ?? SemanticVersion(fallbackVersion) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    public static var links: ProjectLinks { ProjectLinks(repository) }
}
