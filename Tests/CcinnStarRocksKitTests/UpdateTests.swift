import CryptoKit
import Foundation
import Testing
@testable import CcinnStarRocksKit

private let repository = GitHubRepository(owner: "whiteCcinn", name: "ccinnstarrocks")

/// A `releases/latest` response shaped like GitHub's (trimmed to the fields that matter).
private func releaseJSON(tag: String = "v1.2.0", dmgURL: String? = nil, dmgSize: Int64 = 11, checksums: Bool = true,
                         body: String = "### Added\\n\\n- Check for updates") -> Data {
    let dmg = dmgURL ?? "https://github.com/whiteCcinn/ccinnstarrocks/releases/download/\(tag)/CcinnStarRocks-1.2.0.dmg"
    let sums = checksums ? """
        , {"name": "SHA256SUMS.txt", "size": 180,
           "browser_download_url": "https://github.com/whiteCcinn/ccinnstarrocks/releases/download/\(tag)/SHA256SUMS.txt"}
        """ : ""
    return Data("""
        {"tag_name": "\(tag)", "name": "CcinnStarRocks \(tag)", "draft": false, "prerelease": false,
         "html_url": "https://github.com/whiteCcinn/ccinnstarrocks/releases/tag/\(tag)",
         "published_at": "2026-11-20T08:00:00Z", "body": "\(body)",
         "assets": [
           {"name": "CcinnStarRocks-1.2.0-macOS.zip", "size": 9,
            "browser_download_url": "https://github.com/whiteCcinn/ccinnstarrocks/releases/download/\(tag)/CcinnStarRocks-1.2.0-macOS.zip"},
           {"name": "CcinnStarRocks-1.2.0.dmg", "size": \(dmgSize), "browser_download_url": "\(dmg)"}\(sums)
         ]}
        """.utf8)
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Serves canned responses by URL; downloads are written to a temporary file.
private final class FakeUpdateClient: UpdateHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (status: Int, body: Data)] = [:]
    private var downloads: [String: Data] = [:]
    private(set) var requests: [URLRequest] = []

    func respond(_ url: String, status: Int = 200, body: Data) {
        lock.withLock { responses[url] = (status, body) }
    }

    func serve(_ url: String, file: Data) {
        lock.withLock { downloads[url] = file }
    }

    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let canned = lock.withLock { () -> (status: Int, body: Data)? in
            requests.append(request)
            return responses[url]
        }
        guard let canned else { throw URLError(.cannotFindHost) }
        guard canned.body.count <= maxBytes else { throw UpdateError(.invalidResponse, "too large") }
        let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: canned.status, httpVersion: nil, headerFields: nil)
        return (canned.body, response ?? HTTPURLResponse())
    }

    func download(_ url: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let data = lock.withLock({ downloads[url.absoluteString] }) else { throw URLError(.fileDoesNotExist) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-download-\(UUID().uuidString)")
        try data.write(to: file)
        progress(1)
        return file
    }
}

@Suite("Semantic versions")
struct SemanticVersionTests {
    @Test(arguments: [
        ("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3"), ("V2", "2.0.0"), ("1.2", "1.2.0"), (" v1.0.1 ", "1.0.1"),
        ("1.2.3+build.7", "1.2.3"), ("2.0.0-beta.1", "2.0.0-beta.1"),
    ])
    func parses(text: String, expected: String) throws {
        #expect(try #require(SemanticVersion(text)).description == expected)
    }

    @Test(arguments: ["", "v", "latest", "1..2", "1.2.3.4", "1.x", "-1.0.0", "1.0.0-", "99999999999999999999.0.0", "1.2.3-beta..1", "1.0.0-be ta",
                       "1.0.0-beta.01", "1.0.0-00"])
    func rejects(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test func orders() throws {
        func v(_ text: String) throws -> SemanticVersion { try #require(SemanticVersion(text)) }
        #expect(try v("1.10.0") > v("1.9.9"))
        #expect(try v("2.0.0-beta.1") < v("2.0.0"))
        #expect(try v("2.0.0-alpha") < v("2.0.0-alpha.1"))
        #expect(try v("2.0.0-alpha.2") < v("2.0.0-alpha.10"))
        #expect(try v("2.0.0-1") < v("2.0.0-alpha"))
        #expect(try v("v1.2") == v("1.2.0"))
        #expect(try v("1.2.3+a") == v("1.2.3+b"))
    }
}

@Suite("Release information")
struct ReleaseInfoTests {
    @Test func decodesTheLatestRelease() throws {
        let release = try ReleaseInfo.decode(releaseJSON(), repository: repository)
        #expect(release.version.description == "1.2.0")
        #expect(release.tag == "v1.2.0")
        #expect(release.notes == "### Added\n\n- Check for updates")
        #expect(release.pageURL.absoluteString == "https://github.com/whiteCcinn/ccinnstarrocks/releases/tag/v1.2.0")
        #expect(release.diskImage?.name == "CcinnStarRocks-1.2.0.dmg")
        #expect(release.diskImage?.size == 11)
        #expect(release.checksums?.name == "SHA256SUMS.txt")
        #expect(release.publishedAt != nil)
    }

    @Test(arguments: [
        "http://github.com/whiteCcinn/ccinnstarrocks/releases/download/v1.2.0/CcinnStarRocks-1.2.0.dmg",
        "https://evil.example/whiteCcinn/ccinnstarrocks/releases/download/v1.2.0/CcinnStarRocks-1.2.0.dmg",
        "https://github.com/someone/ccinnstarrocks/releases/download/v1.2.0/CcinnStarRocks-1.2.0.dmg",
        "https://github.com.evil.example/whiteCcinn/ccinnstarrocks/releases/download/v1.2.0/x.dmg",
        "https://github.com/whiteCcinn/ccinnstarrocks/archive/refs/tags/v1.2.0.dmg",
        "https://user:pass@github.com/whiteCcinn/ccinnstarrocks/releases/download/v1.2.0/CcinnStarRocks-1.2.0.dmg",
    ])
    func refusesForeignDownloadURLs(url: String) throws {
        let release = try ReleaseInfo.decode(releaseJSON(dmgURL: url), repository: repository)
        #expect(release.diskImage == nil)
    }

    @Test func refusesOversizedDiskImages() throws {
        let release = try ReleaseInfo.decode(releaseJSON(dmgSize: ReleaseInfo.maxDiskImageBytes + 1), repository: repository)
        #expect(release.diskImage == nil)
    }

    /// Review F6: an asset from another tag (for example an older, vulnerable build) is not offered.
    @Test func assetsMustBelongToTheReleaseTag() throws {
        let other = "https://github.com/whiteCcinn/ccinnstarrocks/releases/download/v0.9.0/CcinnStarRocks-1.2.0.dmg"
        #expect(try ReleaseInfo.decode(releaseJSON(dmgURL: other), repository: repository).diskImage == nil)
        var text = String(decoding: releaseJSON(), as: UTF8.self)
        text = text.replacingOccurrences(of: "download/v1.2.0/SHA256SUMS.txt", with: "download/v0.9.0/SHA256SUMS.txt")
        #expect(try ReleaseInfo.decode(Data(text.utf8), repository: repository).checksums == nil)
    }

    @Test func foreignReleasePageFallsBackToTheRepository() throws {
        var text = String(decoding: releaseJSON(), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"html_url\": \"https://github.com/whiteCcinn/ccinnstarrocks/releases/tag/v1.2.0\"",
                                         with: "\"html_url\": \"https://evil.example/x\"")
        let release = try ReleaseInfo.decode(Data(text.utf8), repository: repository)
        #expect(release.pageURL == ProjectLinks(repository).releases)
    }

    @Test(arguments: ["", "{}", "[]", "{\"tag_name\": 5}", "{\"tag_name\": \"nightly\", \"html_url\": \"x\", \"assets\": []}", "\u{0}\u{1}"])
    func malformedInputThrows(text: String) {
        #expect(throws: UpdateError.self) { _ = try ReleaseInfo.decode(Data(text.utf8), repository: repository) }
    }

    @Test func projectLinks() {
        let links = ProjectLinks(repository)
        #expect(links.repository.absoluteString == "https://github.com/whiteCcinn/ccinnstarrocks")
        #expect(links.releases.absoluteString == "https://github.com/whiteCcinn/ccinnstarrocks/releases")
        #expect(links.newIssue.absoluteString == "https://github.com/whiteCcinn/ccinnstarrocks/issues/new/choose")
        #expect(links.latestReleaseAPI.absoluteString == "https://api.github.com/repos/whiteCcinn/ccinnstarrocks/releases/latest")
    }
}

@Suite("Checksum lists")
struct ChecksumListTests {
    @Test func parsesTextAndBinaryForms() {
        let upper = String(repeating: "AB", count: 32)
        let lower = String(repeating: "0f", count: 32)
        let list = ChecksumList.parse("""
            \(upper)  CcinnStarRocks-1.2.0.dmg
            \(lower) *CcinnStarRocks-1.2.0-macOS.zip
            not a checksum line
            1234  short.dmg

            """)
        #expect(list["CcinnStarRocks-1.2.0.dmg"] == upper.lowercased())
        #expect(list["CcinnStarRocks-1.2.0-macOS.zip"] == lower)
        #expect(list["short.dmg"] == nil)
        #expect(list.count == 2)
    }
}

@Suite("Update schedule")
struct UpdateScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dueRules() {
        #expect(UpdateSchedule.isDue(now: now, lastCheck: nil, enabled: true))
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-3_600), enabled: true))
        #expect(UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-86_401), enabled: true))
        #expect(UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(600), enabled: true), "clock moved backwards")
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: nil, enabled: false))
    }

    /// Review F4: a failed attempt (offline) does not count as a check; it is retried after an hour.
    @Test func failedAttemptsRetryHourly() {
        let failedMinutesAgo = now.addingTimeInterval(-600)
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: nil, lastFailure: failedMinutesAgo, enabled: true))
        #expect(UpdateSchedule.isDue(now: now, lastCheck: nil, lastFailure: now.addingTimeInterval(-3_601), enabled: true))
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-60), lastFailure: nil, enabled: true))
        #expect(UpdateSchedule.isDue(now: now, lastCheck: nil, lastFailure: now.addingTimeInterval(60), enabled: true), "clock moved backwards")
    }

    @Test func skippedVersionsOnlyMuteAutomaticChecks() throws {
        let latest = try #require(SemanticVersion("1.2.0"))
        #expect(!UpdateSchedule.shouldPresent(latest, skipped: "1.2.0", automatic: true))
        #expect(UpdateSchedule.shouldPresent(latest, skipped: "1.2.0", automatic: false))
        #expect(UpdateSchedule.shouldPresent(latest, skipped: "1.1.0", automatic: true))
        #expect(UpdateSchedule.shouldPresent(latest, skipped: nil, automatic: true))
    }
}

@Suite("Release notes")
struct ReleaseNotesTests {
    @Test func blocks() {
        let blocks = ReleaseNotes.blocks(from: """
            First public release.
            Second line.

            ### Added

            - **Check for updates** from the app menu
              continued here
            * Project links

            ```
            code
            ```
            [1.2.0]: https://github.com/whiteCcinn/ccinnstarrocks/releases/tag/v1.2.0
            """)
        #expect(blocks == [
            .paragraph("First public release. Second line."),
            .heading("Added"),
            .bullet("**Check for updates** from the app menu continued here"),
            .bullet("Project links"),
            .paragraph("code"),
        ])
    }

    @Test func hugeInputIsBounded() {
        let blocks = ReleaseNotes.blocks(from: String(repeating: "- item\n", count: 100_000))
        #expect(blocks.count <= ReleaseNotes.maxBlocks)
    }

    /// Review F3: GitHub returns CRLF line endings for notes edited in the web UI ("\r\n" is one Character).
    @Test func crlfLineEndings() {
        #expect(ReleaseNotes.blocks(from: "## Fixed\r\n\r\n- one\r\n- two\r\n") == [.heading("Fixed"), .bullet("one"), .bullet("two")])
    }
}

@Suite("Update checker")
struct UpdateCheckerTests {
    private let api = "https://api.github.com/repos/whiteCcinn/ccinnstarrocks/releases/latest"

    private func checker(_ client: FakeUpdateClient, current: String = "1.1.0") throws -> UpdateChecker {
        UpdateChecker(repository: repository, currentVersion: try #require(SemanticVersion(current)), client: client)
    }

    @Test func reportsANewerRelease() async throws {
        let client = FakeUpdateClient()
        client.respond(api, body: releaseJSON())
        guard case let .available(release) = try await checker(client).check() else { Issue.record("expected available"); return }
        #expect(release.version.description == "1.2.0")
        let request = try #require(client.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CcinnStarRocks/1.1.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func upToDateWhenEqualOrOlder() async throws {
        let client = FakeUpdateClient()
        client.respond(api, body: releaseJSON(tag: "v1.2.0"))
        guard case .upToDate = try await checker(client, current: "1.2.0").check() else { Issue.record("expected up to date"); return }
        guard case .upToDate = try await checker(client, current: "1.3.0").check() else { Issue.record("expected up to date"); return }
    }

    @Test func noReleasesYet() async throws {
        let client = FakeUpdateClient()
        client.respond(api, status: 404, body: Data("{\"message\":\"Not Found\"}".utf8))
        #expect(try await checker(client).check() == .noReleases)
    }

    @Test(arguments: [403, 429])
    func rateLimitIsExplained(status: Int) async throws {
        let client = FakeUpdateClient()
        client.respond(api, status: status, body: Data("{}".utf8))
        await #expect { _ = try await checker(client).check() } throws: { ($0 as? UpdateError)?.kind == .rateLimited }
    }

    @Test func serverErrorsAndGarbageFail() async throws {
        let client = FakeUpdateClient()
        client.respond(api, status: 500, body: Data())
        await #expect { _ = try await checker(client).check() } throws: { ($0 as? UpdateError)?.kind == .invalidResponse }
        client.respond(api, body: Data("not json".utf8))
        await #expect { _ = try await checker(client).check() } throws: { ($0 as? UpdateError)?.kind == .invalidResponse }
    }

    @Test func networkFailuresAreReported() async throws {
        let client = FakeUpdateClient()
        await #expect { _ = try await checker(client).check() } throws: { ($0 as? UpdateError)?.kind == .network }
    }
}

@Suite("Update downloader")
struct UpdateDownloaderTests {
    private let dmgURL = "https://github.com/whiteCcinn/ccinnstarrocks/releases/download/v1.2.0/CcinnStarRocks-1.2.0.dmg"
    private let sumsURL = "https://github.com/whiteCcinn/ccinnstarrocks/releases/download/v1.2.0/SHA256SUMS.txt"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnstarrocks-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setUp(file: Data, listed: Data? = nil, size: Int64? = nil) throws -> (FakeUpdateClient, ReleaseInfo) {
        let client = FakeUpdateClient()
        client.serve(dmgURL, file: file)
        client.respond(sumsURL, body: Data("\(hex(listed ?? file))  CcinnStarRocks-1.2.0.dmg\n".utf8))
        let release = try ReleaseInfo.decode(releaseJSON(dmgSize: size ?? Int64(file.count)), repository: repository)
        return (client, release)
    }

    @Test func verifiedDownloadIsSavedWithoutOverwriting() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let file = Data("disk image!".utf8)
        let (client, release) = try setUp(file: file)
        let downloader = UpdateDownloader(repository: repository, client: client, destination: downloads)
        let first = try await downloader.download(release) { _ in }
        #expect(first.lastPathComponent == "CcinnStarRocks-1.2.0.dmg")
        #expect(try Data(contentsOf: first) == file)
        let second = try await downloader.download(release) { _ in }
        #expect(second.lastPathComponent == "CcinnStarRocks-1.2.0 (1).dmg")
        #expect(try Data(contentsOf: first) == file, "the earlier download was not overwritten")
    }

    @Test func checksumMismatchDeletesTheFile() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let (client, release) = try setUp(file: Data("tampered!!!".utf8), listed: Data("disk image!".utf8))
        let downloader = UpdateDownloader(repository: repository, client: client, destination: downloads)
        await #expect { _ = try await downloader.download(release) { _ in } } throws: { ($0 as? UpdateError)?.kind == .verificationFailed }
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    }

    @Test func sizeMismatchFails() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let file = Data("disk image!".utf8)
        let (client, release) = try setUp(file: file, size: Int64(file.count) + 5)
        let downloader = UpdateDownloader(repository: repository, client: client, destination: downloads)
        await #expect { _ = try await downloader.download(release) { _ in } } throws: { ($0 as? UpdateError)?.kind == .verificationFailed }
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    }

    @Test func missingChecksumEntryFails() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let (client, release) = try setUp(file: Data("disk image!".utf8))
        client.respond(sumsURL, body: Data("\(String(repeating: "a", count: 64))  Other.dmg\n".utf8))
        let downloader = UpdateDownloader(repository: repository, client: client, destination: downloads)
        await #expect { _ = try await downloader.download(release) { _ in } } throws: { ($0 as? UpdateError)?.kind == .verificationFailed }
    }

    @Test func releaseWithoutDiskImageCannotBeDownloaded() async throws {
        let release = try ReleaseInfo.decode(releaseJSON(dmgURL: "https://evil.example/x.dmg"), repository: repository)
        let downloader = UpdateDownloader(repository: repository, client: FakeUpdateClient(), destination: try folder())
        await #expect { _ = try await downloader.download(release) { _ in } } throws: { ($0 as? UpdateError)?.kind == .noDiskImage }
    }

    @Test(arguments: ["../evil.dmg", ".hidden.dmg", "a/b.dmg", "", "x\u{0}.dmg"])
    func unsafeAssetNamesAreRefused(name: String) {
        #expect(UpdateDownloader.isSafeFileName(name) == false)
    }

    @Test func uniqueDestinationNames() throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        try Data().write(to: downloads.appendingPathComponent("A.dmg"))
        try Data().write(to: downloads.appendingPathComponent("A (1).dmg"))
        #expect(UpdateDownloader.uniqueDestination(for: "A.dmg", in: downloads).lastPathComponent == "A (2).dmg")
        #expect(UpdateDownloader.uniqueDestination(for: "B.dmg", in: downloads).lastPathComponent == "B.dmg")
    }
}

@Suite("App information")
struct AppInfoTests {
    @Test func versionFallsBackForUnbundledBuilds() {
        #expect(SemanticVersion(AppInfo.version) != nil)
        #expect(AppInfo.repository == repository)
    }
}

@Suite("Download bridge")
struct DownloadBridgeTests {
    /// Review F2: a task cancelled before `start` may complete before the continuation is stored; the
    /// outcome is kept and `start` resumes at once instead of waiting forever.
    @Test func completionBeforeStartStillResumes() async throws {
        let delegate = DownloadDelegate(expectedBytes: 10) { _ in }
        let task = URLSession.shared.downloadTask(with: URL(fileURLWithPath: "/nonexistent"))
        delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: URLError(.cancelled))
        await #expect(throws: URLError.self) {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                delegate.start(task, continuation: continuation)
            }
        }
    }
}
