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

    /// ratatui named colors. Index 0 is Reset; 1…16 follow the enum order
    /// Black, Red, Green, Yellow, Blue, Magenta, Cyan, Gray, DarkGray,
    /// LightRed, LightGreen, LightYellow, LightBlue, LightMagenta, LightCyan,
    /// White. Note Gray is ANSI 7 and DarkGray is ANSI 8.
    private static func named(_ index: UInt8) -> TerminalColor {
        switch index {
        case 1: return .rgb(0, 0, 0)
        case 2: return .rgb(205, 49, 49)
        case 3: return .rgb(13, 188, 121)
        case 4: return .rgb(229, 229, 16)
        case 5: return .rgb(36, 114, 200)
        case 6: return .rgb(188, 63, 188)
        case 7: return .rgb(17, 168, 205)
        case 8: return .rgb(229, 229, 229)
        case 9: return .rgb(102, 102, 102)
        case 10: return .rgb(241, 76, 76)
        case 11: return .rgb(35, 209, 139)
        case 12: return .rgb(245, 245, 67)
        case 13: return .rgb(59, 142, 234)
        case 14: return .rgb(214, 112, 214)
        case 15: return .rgb(41, 184, 219)
        case 16: return .rgb(255, 255, 255)
        default: return .reset
        }
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
