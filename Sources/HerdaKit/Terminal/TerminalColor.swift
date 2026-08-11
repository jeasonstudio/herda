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
    ///
    /// Named and indexed colors resolve against `palette`'s 16 ANSI slots,
    /// which lets the active theme recolor terminal content. Defaults to the
    /// fixed ghostty palette (what herdr itself renders) when none is supplied.
    public static func unpack(
        _ packed: UInt32,
        palette: TerminalPalette = .ghostty
    ) -> TerminalColor {
        switch packed >> 24 {
        case 0x00:
            return named(UInt8(truncatingIfNeeded: packed), palette: palette)
        case 0x01:
            return indexed(UInt8(truncatingIfNeeded: packed), palette: palette)
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
    /// order of `palette.ansi` (Black, Red, Green, Yellow, Blue, Magenta, Cyan,
    /// Gray/white, DarkGray/bright-black, then the bright variants).
    private static func named(_ index: UInt8, palette: TerminalPalette) -> TerminalColor {
        guard (1 ... 16).contains(index) else { return .reset }
        let color = palette.ansi[Int(index) - 1]
        return .rgb(color.red, color.green, color.blue)
    }

    /// Standard xterm 256-color palette. Indices 0…15 follow the theme's ANSI
    /// slots; 16…255 are the fixed xterm cube and grayscale ramp.
    private static func indexed(_ index: UInt8, palette: TerminalPalette) -> TerminalColor {
        if index < 16 {
            return named(index + 1, palette: palette)
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
