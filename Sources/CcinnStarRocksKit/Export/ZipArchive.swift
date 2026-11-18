import Compression
import Foundation

// A ZIP writer just large enough for Office Open XML packages: deflated entries, streamed to a file, no ZIP64.
// Shared verbatim by the ccinn* apps; it depends on Foundation and Apple's Compression framework only.

/// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), the checksum ZIP stores per entry.
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public var checksum: UInt32 { state ^ 0xFFFF_FFFF }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { bytes in
            Self.table.withUnsafeBufferPointer { table in
                var value = state
                for byte in bytes { value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
                state = value
            }
        }
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.checksum
    }
}

public enum ZipArchiveError: Error, Equatable, LocalizedError {
    case cannotCreate(String)
    case compressionFailed
    /// An entry or the archive passed 4 GB, which needs ZIP64.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case let .cannotCreate(path): "Cannot create \(path)."
        case .compressionFailed: "Compression failed."
        case .tooLarge: "The file would be larger than 4 GB."
        }
    }
}

/// Raw DEFLATE (RFC 1951, ZIP method 8) fed in chunks; Compression's `COMPRESSION_ZLIB` is raw DEFLATE without the
/// zlib header, exactly what ZIP stores.
final class DeflateEncoder {
    private static let bufferSize = 1 << 16
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: DeflateEncoder.bufferSize)
    private var isFinished = false

    init() throws {
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            buffer.deallocate()
            throw ZipArchiveError.compressionFailed
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        buffer.deallocate()
    }

    /// Compresses `data`, passing every compressed chunk to `output`; `final` flushes the end of the stream.
    func encode(_ data: Data, final: Bool, output: (Data) throws -> Void) throws {
        guard !isFinished else { throw ZipArchiveError.compressionFailed }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            // An empty buffer may have no base address; Compression still wants a pointer, with a size of zero.
            stream.pointee.src_ptr = bytes.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            stream.pointee.src_size = bytes.count
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = Self.bufferSize
                let status = compression_stream_process(stream, flags)
                let produced = Self.bufferSize - stream.pointee.dst_size
                if produced > 0 { try output(Data(bytes: buffer, count: produced)) }
                switch status {
                case COMPRESSION_STATUS_END:
                    isFinished = true
                    return
                case COMPRESSION_STATUS_OK:
                    // Not finalizing: done once the input is consumed and the output buffer was not filled up.
                    if !final, stream.pointee.src_size == 0, stream.pointee.dst_size > 0 { return }
                default:
                    throw ZipArchiveError.compressionFailed
                }
            }
        }
    }
}

/// Writes a ZIP archive to a file. Entries are deflated as they are produced, so a large entry never has to be held
/// in memory; the local header's CRC and sizes are patched in once the entry is complete.
final class ZipArchiveWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let headerOffset: UInt32
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(url: URL, date: Date = Date()) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ZipArchiveError.cannotCreate(url.path) }
        handle = try FileHandle(forWritingTo: url)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((parts.year ?? 1980) - 1980, 0), 127)
        dosDate = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
    }

    deinit { try? handle.close() }

    func addEntry(_ name: String, data: Data) throws {
        try addEntry(name) { write in try write(data) }
    }

    /// Adds an entry whose bytes `produce` passes, chunk by chunk, to the function it is given.
    func addEntry(_ name: String, produce: ((Data) throws -> Void) throws -> Void) throws {
        let nameBytes = Array(name.utf8)
        let headerOffset = offset
        guard headerOffset <= UInt64(UInt32.max) else { throw ZipArchiveError.tooLarge }
        try write(header(signature: 0x0403_4B50, name: nameBytes, crc: 0, compressedSize: 0, size: 0, central: nil))

        let encoder = try DeflateEncoder()
        var crc = CRC32()
        var size: UInt64 = 0
        var compressedSize: UInt64 = 0
        func store(_ chunk: Data) throws {
            compressedSize += UInt64(chunk.count)
            try write(chunk)
        }
        try produce { chunk in
            crc.update(chunk)
            size += UInt64(chunk.count)
            try encoder.encode(chunk, final: false, output: store)
        }
        try encoder.encode(Data(), final: true, output: store)
        guard size <= UInt64(UInt32.max), compressedSize <= UInt64(UInt32.max) else { throw ZipArchiveError.tooLarge }

        let entry = Entry(name: nameBytes, crc: crc.checksum, compressedSize: UInt32(compressedSize), size: UInt32(size),
                          headerOffset: UInt32(headerOffset))
        // CRC-32, compressed size and size start 14 bytes into the local header.
        var patch = Data()
        patch.appendLittleEndian(entry.crc)
        patch.appendLittleEndian(entry.compressedSize)
        patch.appendLittleEndian(entry.size)
        try handle.seek(toOffset: headerOffset + 14)
        try handle.write(contentsOf: patch)
        try handle.seekToEnd()
        entries.append(entry)
    }

    /// Writes the central directory and closes the file.
    func finish() throws {
        let directoryOffset = offset
        for entry in entries {
            try write(header(signature: 0x0201_4B50, name: entry.name, crc: entry.crc, compressedSize: entry.compressedSize,
                             size: entry.size, central: entry.headerOffset))
        }
        let directorySize = offset - directoryOffset
        guard entries.count <= Int(UInt16.max), directoryOffset <= UInt64(UInt32.max), directorySize <= UInt64(UInt32.max) else {
            throw ZipArchiveError.tooLarge
        }
        var end = Data()
        end.appendLittleEndian(UInt32(0x0605_4B50))
        end.appendLittleEndian(UInt16(0)) // this disk
        end.appendLittleEndian(UInt16(0)) // disk with the central directory
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt32(directorySize))
        end.appendLittleEndian(UInt32(directoryOffset))
        end.appendLittleEndian(UInt16(0)) // comment length
        try write(end)
        try handle.synchronize()
        try handle.close()
    }

    /// A local file header, or with `central` (the local header's offset) a central directory header.
    private func header(signature: UInt32, name: [UInt8], crc: UInt32, compressedSize: UInt32, size: UInt32, central: UInt32?) -> Data {
        var data = Data()
        data.appendLittleEndian(signature)
        if central != nil { data.appendLittleEndian(UInt16(20)) } // version made by
        data.appendLittleEndian(UInt16(20)) // version needed: deflate
        data.appendLittleEndian(UInt16(0x0800)) // names are UTF-8
        data.appendLittleEndian(UInt16(8)) // deflated
        data.appendLittleEndian(dosTime)
        data.appendLittleEndian(dosDate)
        data.appendLittleEndian(crc)
        data.appendLittleEndian(compressedSize)
        data.appendLittleEndian(size)
        data.appendLittleEndian(UInt16(name.count))
        data.appendLittleEndian(UInt16(0)) // extra field length
        if let central {
            data.appendLittleEndian(UInt16(0)) // comment length
            data.appendLittleEndian(UInt16(0)) // disk number
            data.appendLittleEndian(UInt16(0)) // internal attributes
            data.appendLittleEndian(UInt32(0)) // external attributes
            data.appendLittleEndian(central)
        }
        data.append(contentsOf: name)
        return data
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
