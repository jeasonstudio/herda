import Foundation

/// Sequential reader over a bincode payload.
///
/// Every accessor is strict: it throws rather than returning a partial or
/// guessed value. Silent misalignment in a hand-written codec shows up as
/// intermittent visual corruption, which is far harder to diagnose than a
/// hard failure at the point of the mistake.
public struct ByteReader {
    public enum Failure: Error, Equatable {
        case truncated(need: Int, offset: Int, remaining: Int)
        case badVarintTag(UInt8)
        case unexpectedOptionTag(UInt8)
        case lengthOverflow(UInt64)
        case invalidUTF8
        case trailingBytes(consumed: Int, total: Int)
    }

    private let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var isAtEnd: Bool { offset == bytes.count }
    public var remaining: Int { bytes.count - offset }

    public mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw Failure.truncated(need: 1, offset: offset, remaining: 0)
        }
        let value = bytes[offset]
        offset += 1
        return value
    }

    public mutating func bool() throws -> Bool {
        try byte() != 0
    }

    public mutating func varint() throws -> UInt64 {
        let tag = try byte()
        switch tag {
        case 0 ... 250:
            return UInt64(tag)
        case 251:
            return UInt64(try fixedWidth(UInt16.self))
        case 252:
            return UInt64(try fixedWidth(UInt32.self))
        case 253:
            return try fixedWidth(UInt64.self)
        default:
            throw Failure.badVarintTag(tag)
        }
    }

    /// Reads an `Option` discriminant. Returns true for `Some`.
    public mutating func optionTag() throws -> Bool {
        let tag = try byte()
        switch tag {
        case 0: return false
        case 1: return true
        default: throw Failure.unexpectedOptionTag(tag)
        }
    }

    public mutating func string() throws -> String {
        let slice = try take(try length())
        guard let text = String(bytes: slice, encoding: .utf8) else {
            throw Failure.invalidUTF8
        }
        return text
    }

    public mutating func byteArray() throws -> [UInt8] {
        Array(try take(try length()))
    }

    /// Reads a varint length and converts it to `Int`, rejecting values that
    /// cannot be represented (corrupt or hostile input).
    public mutating func length() throws -> Int {
        let raw = try varint()
        guard let value = Int(exactly: raw) else {
            throw Failure.lengthOverflow(raw)
        }
        return value
    }

    public func requireFullyConsumed() throws {
        guard isAtEnd else {
            throw Failure.trailingBytes(consumed: offset, total: bytes.count)
        }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else {
            throw Failure.truncated(need: count, offset: offset, remaining: remaining)
        }
        let slice = bytes[offset ..< offset + count]
        offset += count
        return slice
    }

    private mutating func fixedWidth<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let slice = try take(MemoryLayout<T>.size)
        var value = T.zero
        for (index, byte) in slice.enumerated() {
            value |= T(byte) << (8 * index)
        }
        return value
    }
}
