import Darwin
import Foundation

/// An exclusive lock on a file (`flock`), held for the duration of a closure. The app and the `mcp` process both write
/// knowledge; each takes this lock around read-modify-write. Every call opens the lock file itself, so two callers in
/// one process exclude each other as two processes do.
public enum FileLock {
    public enum Failure: Error, Equatable, LocalizedError {
        /// Another writer held the lock for the whole timeout.
        case busy(String)
        case cannotOpen(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .busy: "The knowledge base is busy (another CcinnStarRocks window or AI session is writing). Try again."
            case let .cannotOpen(path, code): "Cannot open \(path) (\(String(cString: strerror(code))))."
            }
        }
    }

    public static func withLock<T>(at url: URL, timeout: Duration = .seconds(5), _ body: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotOpen(url.path, errno) }
        defer { close(descriptor) }
        let deadline = ContinuousClock.now + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Failure.cannotOpen(url.path, errno) }
            guard ContinuousClock.now < deadline else { throw Failure.busy(url.path) }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
