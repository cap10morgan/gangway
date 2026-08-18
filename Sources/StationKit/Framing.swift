import Foundation

/// Frame layout on the wire:
///
///     [UInt32 payloadLength][UInt8 messageType][payload bytes...]
///
/// A 4-byte length prefix caps a single frame at 4 GiB, but we enforce a far smaller
/// ceiling: an attacker (or a bug) must not be able to make us allocate arbitrarily.
public enum Framing {
    /// Generous for input events (~300 bytes) while still bounding allocation.
    /// Clipboard transfers will use a separate chunked path rather than raising this.
    public static let maxFrameSize = 4 * 1024 * 1024

    public static func frame(_ type: MessageType, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.appendLE(UInt32(payload.count))
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    public static func frame<T: Encodable>(_ type: MessageType, json value: T) throws -> Data {
        frame(type, try JSONEncoder().encode(value))
    }
}

public enum FramingError: Error, Equatable {
    case frameTooLarge(Int)
    case unknownMessageType(UInt8)
}

/// Accumulates bytes from a stream and yields complete frames.
///
/// TCP gives us a byte stream with no message boundaries, so a single read may contain
/// a partial frame, one frame, or several. This buffers until each frame is whole.
public struct FrameDecoder {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete frame, or nil if more bytes are needed.
    public mutating func next() throws -> (type: MessageType, payload: Data)? {
        guard buffer.count >= 5 else { return nil }

        let length = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        guard length <= Framing.maxFrameSize else {
            throw FramingError.frameTooLarge(length)
        }
        guard buffer.count >= 5 + length else { return nil }

        let rawType = buffer[buffer.startIndex + 4]
        guard let type = MessageType(rawValue: rawType) else {
            // Drop the frame so one unknown message can't wedge the connection.
            buffer.removeFirst(5 + length)
            throw FramingError.unknownMessageType(rawType)
        }

        let start = buffer.startIndex + 5
        let payload = Data(buffer[start..<start + length])
        buffer.removeFirst(5 + length)
        return (type, payload)
    }
}
