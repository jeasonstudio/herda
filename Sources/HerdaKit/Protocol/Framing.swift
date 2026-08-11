import Foundation

/// Wire framing: `[u32 little-endian payload length][payload]`.
public enum Framing {
    public enum Failure: Error, Equatable {
        case shortPrefix(count: Int)
        case oversized(claimed: UInt32, max: Int)
    }

    /// Mirrors the server's own frame ceiling closely enough for a prototype;
    /// its purpose is to refuse absurd allocations from a corrupt prefix.
    public static let maxPayloadSize = 64 * 1024 * 1024

    public static let prefixSize = 4

    public static func frame(_ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(prefixSize + payload.count)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) })
        out.append(contentsOf: payload)
        return out
    }

    public static func payloadLength(from prefix: [UInt8]) throws -> Int {
        guard prefix.count == prefixSize else {
            throw Failure.shortPrefix(count: prefix.count)
        }
        var claimed: UInt32 = 0
        for (index, byte) in prefix.enumerated() {
            claimed |= UInt32(byte) << (8 * index)
        }
        guard Int(claimed) <= maxPayloadSize else {
            throw Failure.oversized(claimed: claimed, max: maxPayloadSize)
        }
        return Int(claimed)
    }
}
