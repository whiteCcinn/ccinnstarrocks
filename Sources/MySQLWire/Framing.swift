/// MySQL packet = 3-byte length + 1-byte sequence id + payload. Payloads of 2^24-1 bytes or more
/// are split into consecutive maximum-size packets terminated by a shorter (possibly empty) one.
public enum PacketCodec {
    public static let maxChunk = 0xFF_FFFF

    public static func frame(_ payload: [UInt8], sequence: UInt8) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(payload.count + 4 + 4 * (payload.count / maxChunk))
        var offset = 0
        var sequence = sequence
        while true {
            let length = min(maxChunk, payload.count - offset)
            output.append(UInt8(truncatingIfNeeded: length))
            output.append(UInt8(truncatingIfNeeded: length >> 8))
            output.append(UInt8(truncatingIfNeeded: length >> 16))
            output.append(sequence)
            output.append(contentsOf: payload[offset..<(offset + length)])
            offset += length
            sequence &+= 1
            if length < maxChunk { break }
        }
        return output
    }
}

/// Reassembles logical packets from a byte stream (linear time; amortised buffer compaction).
public struct PacketFramer: Sendable {
    public struct Packet: Sendable, Equatable {
        public let sequence: UInt8
        public let payload: [UInt8]
    }

    public static let defaultMaxPayload = 256 * 1024 * 1024

    private var buffer: [UInt8] = []
    private var readIndex = 0
    private let maxPayload: Int

    public init(maxPayload: Int = PacketFramer.defaultMaxPayload) {
        self.maxPayload = maxPayload
    }

    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ bytes: [UInt8]) {
        if readIndex > 0, readIndex >= buffer.count / 2 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete logical packet, `nil` if more bytes are needed.
    public mutating func nextPacket() throws -> Packet? {
        // First pass: make sure every physical chunk of the logical packet is buffered.
        var cursor = readIndex
        var total = 0
        var lastSequence: UInt8 = 0
        while true {
            guard buffer.count - cursor >= 4 else { return nil }
            let length = Int(buffer[cursor]) | Int(buffer[cursor + 1]) << 8 | Int(buffer[cursor + 2]) << 16
            lastSequence = buffer[cursor + 3]
            total += length
            guard total <= maxPayload else { throw MySQLWireError.packetTooLarge(total) }
            guard buffer.count - cursor - 4 >= length else { return nil }
            cursor += 4 + length
            if length < PacketCodec.maxChunk { break }
        }
        // Second pass: copy the payload chunks.
        var payload: [UInt8] = []
        payload.reserveCapacity(total)
        var position = readIndex
        while position < cursor {
            let length = Int(buffer[position]) | Int(buffer[position + 1]) << 8 | Int(buffer[position + 2]) << 16
            payload.append(contentsOf: buffer[(position + 4)..<(position + 4 + length)])
            position += 4 + length
        }
        readIndex = cursor
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        }
        return Packet(sequence: lastSequence, payload: payload)
    }
}
