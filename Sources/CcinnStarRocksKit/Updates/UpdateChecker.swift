import CryptoKit
import Foundation
import os

/// HTTP access for update checks, injectable for tests.
public protocol UpdateHTTPClient: Sendable {
    /// Fetches a small response; fails if the body would exceed `maxBytes`.
    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
    /// Downloads a file to a new temporary location and returns it; fails if it grows beyond `expectedBytes`.
    func download(_ url: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

public enum UpdateCheckResult: Sendable, Equatable {
    case available(ReleaseInfo)
    case upToDate(ReleaseInfo)
    /// The repository has no published release yet.
    case noReleases
}

/// Asks GitHub for the latest release and compares it with the running version (design D1).
public struct UpdateChecker: Sendable {
    public static let maxResponseBytes = 1 << 20
    public static let timeout: TimeInterval = 15

    private let repository: GitHubRepository
    private let currentVersion: SemanticVersion
    private let client: any UpdateHTTPClient
    private let product: String

    public init(repository: GitHubRepository, currentVersion: SemanticVersion, client: any UpdateHTTPClient,
                product: String = AppInfo.productName) {
        self.repository = repository
        self.currentVersion = currentVersion
        self.client = client
        self.product = product
    }

    public func check() async throws -> UpdateCheckResult {
        var request = URLRequest(url: ProjectLinks(repository).latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("\(product)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await UpdateErrors.mapped("GitHub") { try await client.get(request, maxBytes: Self.maxResponseBytes) }
        switch response.statusCode {
        case 200:
            break
        case 404:
            return .noReleases
        case 403, 429:
            throw UpdateError(.rateLimited, "GitHub's limit for update checks was reached. Try again in an hour.")
        default:
            throw UpdateError(.invalidResponse, "GitHub answered with status \(response.statusCode).")
        }
        let release = try ReleaseInfo.decode(data, repository: repository)
        return release.version > currentVersion ? .available(release) : .upToDate(release)
    }
}

/// Downloads a release's disk image, verifies it and saves it without overwriting anything (design D3/D4).
public struct UpdateDownloader: Sendable {
    private let repository: GitHubRepository
    private let client: any UpdateHTTPClient
    private let destination: URL

    /// - Parameter destination: the folder the verified DMG is saved to (normally `~/Downloads`).
    public init(repository: GitHubRepository, client: any UpdateHTTPClient, destination: URL) {
        self.repository = repository
        self.client = client
        self.destination = destination
    }

    public func download(_ release: ReleaseInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let image = release.diskImage, Self.isSafeFileName(image.name), repository.isReleaseDownload(image.url) else {
            throw UpdateError(.noDiskImage, "This release has no disk image to download. Open the release page instead.")
        }
        guard let sums = release.checksums else {
            throw UpdateError(.verificationFailed, "This release has no SHA256SUMS.txt, so the download cannot be verified.")
        }
        let request = URLRequest(url: sums.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await UpdateErrors.mapped("GitHub") {
            try await client.get(request, maxBytes: Int(ReleaseInfo.maxChecksumBytes))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateError(.network, "Could not fetch SHA256SUMS.txt (status \(response.statusCode)).")
        }
        guard let expected = ChecksumList.parse(String(decoding: data, as: UTF8.self))[image.name] else {
            throw UpdateError(.verificationFailed, "SHA256SUMS.txt has no checksum for \(image.name).")
        }
        let temporary = try await UpdateErrors.mapped("the download server") {
            try await client.download(image.url, expectedBytes: image.size, progress: progress)
        }
        // Hashing up to 1 GiB and a cross-volume move are long synchronous work: keep them off the
        // Swift concurrency pool (review F9), with cancellation checked between chunks.
        let destination = destination
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try Self.verifyAndSave(temporary, as: image, sha256: expected, in: destination) { cancelled.withLock { $0 } }
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Checks size and SHA-256, then moves the file to a free name in `folder`; deletes it on any failure.
    static func verifyAndSave(_ temporary: URL, as image: ReleaseAsset, sha256 expected: String, in folder: URL,
                              isCancelled: () -> Bool) throws -> URL {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size == image.size else {
                throw UpdateError(.verificationFailed, "The download has \(size) bytes, but the release lists \(image.size). Nothing was saved.")
            }
            guard try sha256(of: temporary, isCancelled: isCancelled) == expected else {
                throw UpdateError(.verificationFailed, "The download does not match its published SHA-256 checksum. Nothing was saved.")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = uniqueDestination(for: image.name, in: folder)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? UpdateError { throw error }
            throw UpdateError(.fileSystem, "Could not save the download: \(error.localizedDescription)")
        }
    }

    /// A plain file name: no path separators, no leading dot, no control characters.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".")
            && !name.contains(where: { $0 == "/" || $0 == ":" || $0 == "\\" || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } })
    }

    /// `name`, or `name (1)`, `name (2)`, … if taken.
    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let manager = FileManager.default
        let candidate = folder.appendingPathComponent(name)
        guard manager.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 1...999 {
            let next = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            if !manager.fileExists(atPath: next.path) { return next }
        }
        return folder.appendingPathComponent("\(base)-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    /// SHA-256 as lowercase hex, read in 1 MiB chunks.
    static func sha256(of file: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if isCancelled() { throw UpdateError(.cancelled, "The download was cancelled.") }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum UpdateErrors {
    /// Maps transport errors to `UpdateError` (cancellation stays recognisable).
    static func mapped<T>(_ peer: String, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw UpdateError(.cancelled, "Cancelled.")
        } catch let error as URLError where error.code == .cancelled {
            throw UpdateError(.cancelled, "Cancelled.")
        } catch {
            throw UpdateError(.network, "Could not reach \(peer): \(error.localizedDescription)")
        }
    }
}

/// `URLSession`-based client: an ephemeral session (no cookies, no cache, no credentials).
public final class URLSessionUpdateClient: UpdateHTTPClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError(.invalidResponse, "Not an HTTP response.") }
        if http.expectedContentLength > Int64(maxBytes) { throw UpdateError(.invalidResponse, "The response is too large.") }
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(clamping: http.expectedContentLength))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw UpdateError(.invalidResponse, "The response is too large.") }
        }
        return (data, http)
    }

    public func download(_ url: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if Task.isCancelled { throw UpdateError(.cancelled, "Cancelled.") }
        let delegate = DownloadDelegate(expectedBytes: expectedBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Bridges one `URLSessionDownloadTask` to async/await with progress and a size cap.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, any Error>?
        var file: URL?
        var failure: UpdateError?
        /// The task finished before `start` stored the continuation (cancelled before it began, review F2).
        var outcome: Result<URL, any Error>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void

    init(expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, any Error>) {
        let finished = state.withLockUnchecked { state -> Result<URL, any Error>? in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        if let finished {
            continuation.resume(with: finished)
        } else {
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes {
            state.withLockUnchecked { $0.failure = UpdateError(.verificationFailed, "The download is larger than the release lists.") }
            downloadTask.cancel()
            return
        }
        if expectedBytes > 0 { progress(min(1, Double(totalBytesWritten) / Double(expectedBytes))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this method returns: move it now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            state.withLockUnchecked { $0.failure = UpdateError(.network, "The download server answered with status \(http.statusCode).") }
            return
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-update-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            state.withLockUnchecked { $0.file = target }
        } catch {
            state.withLockUnchecked { $0.failure = UpdateError(.fileSystem, "Could not keep the download: \(error.localizedDescription)") }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (file, failure) = state.withLockUnchecked { ($0.file, $0.failure) }
        let outcome: Result<URL, any Error>
        if let failure {
            outcome = .failure(failure)
        } else if let error {
            outcome = .failure(error)
        } else if let file {
            outcome = .success(file)
        } else {
            outcome = .failure(UpdateError(.network, "The download ended without a file."))
        }
        if case .failure = outcome, let file { try? FileManager.default.removeItem(at: file) }
        let continuation = state.withLockUnchecked { state -> CheckedContinuation<URL, any Error>? in
            guard let continuation = state.continuation else {
                state.outcome = outcome
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: outcome)
    }
}
