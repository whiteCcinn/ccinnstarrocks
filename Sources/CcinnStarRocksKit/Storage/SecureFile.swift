import Darwin
import Foundation

/// Private files written atomically: the bytes go to a temporary file in the destination's directory, created 0600 (no
/// moment where another user can read it), flushed to disk, then renamed over the destination. Readers see the old file
/// or the new one, never half of either.
public enum SecureFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try createDirectory(directory)
        var template = Array(directory.appendingPathComponent(".\(url.lastPathComponent).XXXXXX").path.utf8CString)
        let descriptor: Int32 = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return mkstemp(base) // creates the file with mode 0600
        }
        guard descriptor >= 0 else { throw posixError() }
        let temporaryPath = String(cString: template)
        do {
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw posixError() }
        } catch {
            unlink(temporaryPath)
            throw error
        }
        guard rename(temporaryPath, url.path) == 0 else {
            let failure = posixError()
            unlink(temporaryPath)
            throw failure
        }
        // Make the rename itself durable; best effort, the data is already on disk.
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    /// Creates `url` (and missing parents) with mode 0700, or tightens an existing directory to 0700.
    public static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard var pointer = bytes.baseAddress else { return }
            var remaining: Int = bytes.count
            while remaining > 0 {
                let written: Int = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
