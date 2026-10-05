import Foundation

/// Little-endian primitive encoding. Gangway is Mac-only and every supported Mac is
/// little-endian, so we skip byte swapping on the hot path.
extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Double) {
        appendLE(value.bitPattern)
    }
}

/// Sequential reader over a `Data` buffer. Bounds-checked: every read returns nil
/// rather than trapping, because this parses bytes that arrived over a network.
struct Cursor {
    private let data: Data
    private var offset: Int
    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readLE<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { return nil }
        let slice = data[offset..<offset + size]
        offset += size
        let value = slice.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        return T(littleEndian: value)
    }

    mutating func readLE() -> Double? {
        guard let bits: UInt64 = readLE() else { return nil }
        return Double(bitPattern: bits)
    }

    mutating func read(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        let slice = data[offset..<offset + count]
        offset += count
        return Data(slice)
    }

    mutating func rest() -> Data {
        let slice = data[offset...]
        offset = data.endIndex
        return Data(slice)
    }

    var remaining: Int { data.endIndex - offset }
}
