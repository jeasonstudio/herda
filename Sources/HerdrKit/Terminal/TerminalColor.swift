import AppKit

/// A cell color after unpacking the wire representation.
///
/// `reset` means "terminal default", which differs for foreground and
/// background, so the renderer resolves it rather than this type.
public enum TerminalColor: Equatable, Sendable {
    case reset
    case rgb(UInt8, UInt8, UInt8)

    /// Unpacks the `u32` produced by herdr's `color_to_u32`:
    /// tag `0x00` named (low byte 0…16, 0 == Reset), `0x01` palette index,
    /// `0x02` RGB in the low three bytes.
    public static func unpack(_ packed: UInt32) -> TerminalColor {
        switch packed >> 24 {
        case 0x00:
            return named(UInt8(truncatingIfNeeded: packed))
        case 0x01:
            return palette(UInt8(truncatingIfNeeded: packed))
        case 0x02:
            return .rgb(
                UInt8(truncatingIfNeeded: packed >> 16),
                UInt8(truncatingIfNeeded: packed >> 8),
                UInt8(truncatingIfNeeded: packed)
            )
        default:
            return .reset
        }
    }

    /// ratatui named colors. Index 0 is Reset; 1…16 map to ANSI 0…15 in the
    /// same order as `TerminalPalette.ghostty.ansi` (Black, Red, Green, Yellow,
    /// Blue, Magenta, Cyan, Gray/white, DarkGray/bright-black, then the bright
    /// variants). Resolving through the shared ghostty table keeps the
    /// terminal's colors identical to what herdr actually renders.
    private static func named(_ index: UInt8) -> TerminalColor {
        guard (1 ... 16).contains(index) else { return .reset }
        let color = TerminalPalette.ghostty.ansi[Int(index) - 1]
        return .rgb(color.red, color.green, color.blue)
    }

    /// Standard xterm 256-color palette.
    private static func palette(_ index: UInt8) -> TerminalColor {
        if index < 16 {
            return named(index + 1)
        }
        if index < 232 {
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let offset = Int(index) - 16
            return .rgb(levels[offset / 36], levels[(offset % 36) / 6], levels[offset % 6])
        }
        let level = UInt8(8 + (Int(index) - 232) * 10)
        return .rgb(level, level, level)
    }

    /// Resolves to an `NSColor`, using the supplied default for `reset`.
    public func nsColor(default fallback: NSColor) -> NSColor {
        switch self {
        case .reset:
            return fallback
        case .rgb(let r, let g, let b):
            return NSColor(
                srgbRed: CGFloat(r) / 255,
                green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255,
                alpha: 1
            )
        }
    }
}
