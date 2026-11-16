import Foundation

/// An update-check or download failure, explained for the user.
public struct UpdateError: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: Sendable, Equatable {
        case network
        case rateLimited
        case invalidResponse
        case noDiskImage
        case verificationFailed
        case fileSystem
        case cancelled
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A GitHub repository (`owner/name`). Only `[A-Za-z0-9._-]` is kept, so every derived URL is valid.
public struct GitHubRepository: Sendable, Hashable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = Self.sanitized(owner)
        self.name = Self.sanitized(name)
    }

    private static func sanitized(_ text: String) -> String {
        String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }.prefix(100))
    }

    /// `https://github.com/<owner>/<name>/releases/download/…`, nothing else (design D3).
    public func isReleaseDownload(_ url: URL) -> Bool {
        isGitHubURL(url, pathPrefix: "/\(owner)/\(name)/releases/download/")
    }

    /// A download from this repository's release `tag` (both assets of one release share this prefix).
    public func isReleaseDownload(_ url: URL, tag: String) -> Bool {
        !tag.isEmpty && !tag.contains("/") && isGitHubURL(url, pathPrefix: "/\(owner)/\(name)/releases/download/\(tag)/")
    }

    /// A release page of this repository.
    public func isReleasePage(_ url: URL) -> Bool {
        isGitHubURL(url, pathPrefix: "/\(owner)/\(name)/releases")
    }

    private func isGitHubURL(_ url: URL, pathPrefix: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil else { return false }
        let path = components.path
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0 == ".." || $0 == "." }) else { return false }
        return path.lowercased().hasPrefix(pathPrefix.lowercased())
    }
}

/// Links to the project on GitHub (design D8).
public struct ProjectLinks: Sendable, Equatable {
    public let repository: URL
    public let releases: URL
    public let latestRelease: URL
    public let newIssue: URL
    public let latestReleaseAPI: URL

    public init(_ repository: GitHubRepository) {
        let base = "https://github.com/\(repository.owner)/\(repository.name)"
        self.repository = Self.url(base)
        releases = Self.url(base + "/releases")
        latestRelease = Self.url(base + "/releases/latest")
        newIssue = Self.url(base + "/issues/new/choose")
        latestReleaseAPI = Self.url("https://api.github.com/repos/\(repository.owner)/\(repository.name)/releases/latest")
    }

    /// The inputs are sanitized, so parsing cannot fail; the fallback only keeps the code free of force-unwraps.
    private static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }
}

/// A downloadable file attached to a release.
public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let size: Int64
}

/// The latest published release, as far as the update check needs it.
public struct ReleaseInfo: Sendable, Equatable {
    public static let maxDiskImageBytes: Int64 = 1 << 30
    public static let maxChecksumBytes: Int64 = 64 * 1024

    public let version: SemanticVersion
    public let tag: String
    public let name: String
    /// Markdown release notes (bounded, see `ReleaseNotes`).
    public let notes: String
    public let pageURL: URL
    public let publishedAt: Date?
    /// The `.dmg` asset, if it passed the URL and size checks.
    public let diskImage: ReleaseAsset?
    /// `SHA256SUMS.txt`, if present and valid.
    public let checksums: ReleaseAsset?

    private struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let published_at: String?
        let assets: [Asset]?
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int64?
        let browser_download_url: String
    }

    /// Decodes GitHub's `releases/latest` response. Assets with a foreign URL (another repository or another
    /// release's tag) or an implausible size are dropped.
    public static func decode(_ data: Data, repository: GitHubRepository) throws -> ReleaseInfo {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError(.invalidResponse, "GitHub returned an unexpected response.")
        }
        guard let version = SemanticVersion(payload.tag_name) else {
            throw UpdateError(.invalidResponse, "The latest release tag “\(payload.tag_name.prefix(40))” is not a version number.")
        }
        let assets = (payload.assets ?? []).prefix(100).compactMap { asset -> ReleaseAsset? in
            guard let url = URL(string: asset.browser_download_url), repository.isReleaseDownload(url, tag: payload.tag_name) else { return nil }
            return ReleaseAsset(name: asset.name, url: url, size: asset.size ?? -1)
        }
        let diskImage = assets.first { $0.name.lowercased().hasSuffix(".dmg") && (1...maxDiskImageBytes).contains($0.size) }
        let checksums = assets.first { ["sha256sums.txt", "sha256sums"].contains($0.name.lowercased()) && $0.size <= maxChecksumBytes }
        let page = payload.html_url.flatMap(URL.init(string:)).flatMap { repository.isReleasePage($0) ? $0 : nil }
        let notes = String(decoding: Array((payload.body ?? "").utf8.prefix(ReleaseNotes.maxInputBytes)), as: UTF8.self)
        return ReleaseInfo(version: version, tag: String(payload.tag_name.prefix(100)), name: String((payload.name ?? payload.tag_name).prefix(200)),
                           notes: notes, pageURL: page ?? ProjectLinks(repository).releases,
                           publishedAt: payload.published_at.flatMap { ISO8601DateFormatter().date(from: $0) },
                           diskImage: diskImage, checksums: checksums)
    }
}

/// `SHA256SUMS.txt` (`<hex>  <name>` or `<hex> *<name>`), keyed by file name with lowercase hex.
public enum ChecksumList {
    public static func parse(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hash = trimmed[..<space]
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var name = trimmed[space...].drop { $0 == " " || $0 == "\t" }
            if name.first == "*" { name = name.dropFirst() }
            guard !name.isEmpty else { continue }
            sums[String(name)] = hash.lowercased()
        }
        return sums
    }
}

/// When to check automatically and whether to show a found version (design D5).
public enum UpdateSchedule {
    public static let interval: TimeInterval = 86_400

    /// Due when enabled and never checked, last checked a day or more ago, or the clock moved backwards.
    public static func isDue(now: Date, lastCheck: Date?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// A failed attempt (no network) is not a completed check: it is retried after this delay.
    public static let retryAfterFailure: TimeInterval = 3_600

    /// Due as above, and at least an hour after a failed attempt (review F4).
    public static func isDue(now: Date, lastCheck: Date?, lastFailure: Date?, enabled: Bool) -> Bool {
        guard isDue(now: now, lastCheck: lastCheck, enabled: enabled) else { return false }
        guard let lastFailure else { return true }
        let elapsed = now.timeIntervalSince(lastFailure)
        return elapsed < 0 || elapsed >= retryAfterFailure
    }

    /// A skipped version only silences automatic checks; a manual check always shows it.
    public static func shouldPresent(_ latest: SemanticVersion, skipped: String?, automatic: Bool) -> Bool {
        guard automatic, let skipped, let skippedVersion = SemanticVersion(skipped) else { return true }
        return latest != skippedVersion
    }
}

/// A block of release notes for display.
public enum ReleaseNoteBlock: Sendable, Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
}

/// Splits Markdown release notes into headings, bullets and paragraphs (design D7). Inline Markdown is left in
/// the text for `AttributedString` to render.
public enum ReleaseNotes {
    public static let maxInputBytes = 64 * 1024
    public static let maxBlocks = 400

    public static func blocks(from markdown: String) -> [ReleaseNoteBlock] {
        let text = String(decoding: Array(markdown.utf8.prefix(maxInputBytes)), as: UTF8.self)
        var blocks: [ReleaseNoteBlock] = []
        var paragraph: [String] = []
        var bullet: String?

        func flush() {
            if let current = bullet { blocks.append(.bullet(current)) }
            bullet = nil
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        // `\r\n` is a single Character, so split on every kind of line break (review F3).
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if blocks.count >= maxBlocks { break }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("```") {
                flush()
                continue
            }
            if isLinkReference(line) { continue }
            if line.hasPrefix("#") {
                flush()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                bullet = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                continue
            }
            let indented = rawLine.first == " " || rawLine.first == "\t"
            if let current = bullet, indented {
                bullet = current + " " + line
                continue
            }
            if bullet != nil { flush() }
            paragraph.append(line)
        }
        flush()
        return Array(blocks.prefix(maxBlocks))
    }

    /// `[label]: https://…` reference definitions (the CHANGELOG's compare links) are not shown.
    private static func isLinkReference(_ line: String) -> Bool {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return false }
        return line[line.index(after: close)...].hasPrefix(":")
    }
}
