import Foundation

/// bincode 2 `standard` variable-length integer encoding.
///
/// First byte selects the width: `0...250` is the value itself, `251` is
/// followed by a little-endian `u16`, `252` by a `u32`, `253` by a `u64`.
public enum Varint {
    public static func encode(_ value: UInt64) -> [UInt8] {
        if value < 251 {
            return [UInt8(value)]
        }
        if value <= UInt64(UInt16.max) {
            return [251] + littleEndianBytes(UInt16(value))
        }
        if value <= UInt64(UInt32.max) {
            return [252] + littleEndianBytes(UInt32(value))
        }
        return [253] + littleEndianBytes(value)
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
