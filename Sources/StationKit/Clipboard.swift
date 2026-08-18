import Foundation

/// A single pasteboard item, as a map of uniform type identifier to its data.
///
/// Multiple representations are carried together because pasteboard consumers pick the
/// richest type they understand: dropping all but plain text would silently degrade a
/// copied table or styled passage into unformatted text.
public struct ClipboardItem: Codable, Sendable, Equatable {
    public var representations: [String: Data]

    public init(representations: [String: Data]) {
        self.representations = representations
    }

    public var totalBytes: Int {
        representations.values.reduce(0) { $0 + $1.count }
    }
}

public struct ClipboardContent: Codable, Sendable, Equatable {
    public var items: [ClipboardItem]

    public init(items: [ClipboardItem]) {
        self.items = items
    }

    public var totalBytes: Int {
        items.reduce(0) { $0 + $1.totalBytes }
    }

    /// Binary property list rather than JSON: `Data` is stored natively instead of
    /// base64, which would inflate every image by a third.
    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ClipboardContent {
        try PropertyListDecoder().decode(ClipboardContent.self, from: data)
    }
}

/// Splits a large payload across frames and reassembles it on the far side.
public enum ClipboardTransfer {
    /// Comfortably inside `Framing.maxFrameSize`, and small enough that a large
    /// transfer cannot monopolise the connection while input is being forwarded.
    public static let chunkSize = 256 * 1024

    /// Refuse anything larger rather than buffering it. A clipboard is not a file
    /// transfer channel, and an unbounded assembler is a memory exhaustion risk even
    /// from an authenticated peer.
    public static let maxTotalSize = 32 * 1024 * 1024

    /// Frame layout: `[UInt64 transferID][UInt32 index][UInt32 count][bytes...]`
    public static let headerSize = 16

    public static func chunks(of payload: Data, transferID: UInt64) -> [Data] {
        guard !payload.isEmpty else {
            var only = Data()
            only.appendLE(transferID)
            only.appendLE(UInt32(0))
            only.appendLE(UInt32(1))
            return [only]
        }
        var out: [Data] = []
        let count = (payload.count + chunkSize - 1) / chunkSize
        for index in 0..<count {
            let start = payload.index(payload.startIndex, offsetBy: index * chunkSize)
            let end = payload.index(start, offsetBy: min(chunkSize, payload.distance(from: start, to: payload.endIndex)))
            var frame = Data(capacity: headerSize + chunkSize)
            frame.appendLE(transferID)
            frame.appendLE(UInt32(index))
            frame.appendLE(UInt32(count))
            frame.append(payload[start..<end])
            out.append(frame)
        }
        return out
    }
}

/// Reassembles chunked clipboard transfers.
///
/// Tolerates a transfer being abandoned partway: a newer transfer supersedes an older
/// incomplete one, so a peer that disconnects mid-copy cannot wedge the receiver.
public struct ClipboardAssembler {
    private var transferID: UInt64?
    private var received: [UInt32: Data] = [:]
    private var expectedCount: UInt32 = 0
    private var bytesSoFar = 0

    public init() {}

    public enum AssemblyError: Error, Equatable {
        case malformed
        case tooLarge(Int)
    }

    /// Returns the complete payload once the final chunk arrives, otherwise nil.
    public mutating func accept(_ frame: Data) throws -> Data? {
        guard frame.count >= ClipboardTransfer.headerSize else { throw AssemblyError.malformed }
        var cursor = Cursor(frame)
        guard let id: UInt64 = cursor.readLE(),
              let index: UInt32 = cursor.readLE(),
              let count: UInt32 = cursor.readLE(), count > 0 else {
            throw AssemblyError.malformed
        }
        guard index < count else { throw AssemblyError.malformed }
        let body = cursor.rest()

        // A different transfer means the previous one was abandoned. Start fresh rather
        // than mixing chunks from two copies.
        if transferID != id {
            transferID = id
            received = [:]
            expectedCount = count
            bytesSoFar = 0
        }

        bytesSoFar += body.count
        guard bytesSoFar <= ClipboardTransfer.maxTotalSize else {
            reset()
            throw AssemblyError.tooLarge(bytesSoFar)
        }

        received[index] = body
        guard received.count == Int(expectedCount) else { return nil }

        var payload = Data(capacity: bytesSoFar)
        for i in 0..<expectedCount {
            guard let part = received[i] else { return nil }
            payload.append(part)
        }
        reset()
        return payload
    }

    private mutating func reset() {
        transferID = nil
        received = [:]
        expectedCount = 0
        bytesSoFar = 0
    }
}
