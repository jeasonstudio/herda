import AppKit
import Foundation
import SwiftUI

/// An RGB color usable from both AppKit (`nsColor`) and SwiftUI (`color`) —
/// the two rendering stacks the terminal (`TerminalGridView`, AppKit) and the
/// native sidebar (`SidebarView`, SwiftUI) are built on.
public struct ThemeColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    public var color: Color { Color(nsColor) }
}

/// The 16 ANSI colors and default foreground/background ghostty renders
/// herdr's terminal content with. Fixed for every herdr `[theme]` — herdr
/// never overrides these in the socket-embedding case (see design.md's wire
/// color unpacking section). Index 0...15 == ANSI 0...15 in the conventional
/// order: black, red, green, yellow, blue, magenta, cyan, white, then the
/// bright variant of each.
public struct TerminalPalette: Sendable {
    public let defaultForeground: ThemeColor
    public let defaultBackground: ThemeColor
    public let ansi: [ThemeColor]

    /// libghostty's actual default: "Tomorrow Night" base16
    /// (vendor/libghostty-vt/src/terminal/color.zig `Name.default`).
    public static let ghostty = TerminalPalette(
        defaultForeground: ThemeColor(0xFF, 0xFF, 0xFF),
        defaultBackground: ThemeColor(0x00, 0x00, 0x00),
        ansi: [
            ThemeColor(0x1D, 0x1F, 0x21), // 0 black
            ThemeColor(0xCC, 0x66, 0x66), // 1 red
            ThemeColor(0xB5, 0xBD, 0x68), // 2 green
            ThemeColor(0xF0, 0xC6, 0x74), // 3 yellow
            ThemeColor(0x81, 0xA2, 0xBE), // 4 blue
            ThemeColor(0xB2, 0x94, 0xBB), // 5 magenta
            ThemeColor(0x8A, 0xBE, 0xB7), // 6 cyan
            ThemeColor(0xC5, 0xC8, 0xC6), // 7 white
            ThemeColor(0x66, 0x66, 0x66), // 8 bright black
            ThemeColor(0xD5, 0x4E, 0x53), // 9 bright red
            ThemeColor(0xB9, 0xCA, 0x4A), // 10 bright green
            ThemeColor(0xE7, 0xC5, 0x47), // 11 bright yellow
            ThemeColor(0x7A, 0xA6, 0xDA), // 12 bright blue
            ThemeColor(0xC3, 0x97, 0xD8), // 13 bright magenta
            ThemeColor(0x70, 0xC0, 0xB1), // 14 bright cyan
            ThemeColor(0xEA, 0xEA, 0xEA), // 15 bright white
        ]
    )
}
