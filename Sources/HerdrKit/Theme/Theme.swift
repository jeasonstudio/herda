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

/// herdr's UI-chrome palette — the tokens that theme herdr's own tab bar,
/// panels, and status indicators (`Palette` in src/app/state.rs). NOT the
/// terminal palette: herdr's `[theme]` never touches terminal content colors
/// (see `TerminalPalette`). `sidebar_bg` is omitted: every one of herdr's 18
/// built-in themes sets it to `Color::Reset`, so it carries no information.
public struct ChromePalette: Hashable, Sendable {
    public let accent: ThemeColor
    public let panelBackground: ThemeColor
    public let surface0: ThemeColor
    public let surface1: ThemeColor
    public let surfaceDim: ThemeColor
    public let overlay0: ThemeColor
    public let overlay1: ThemeColor
    public let text: ThemeColor
    public let subtext0: ThemeColor
    public let mauve: ThemeColor
    public let green: ThemeColor
    public let yellow: ThemeColor
    public let red: ThemeColor
    public let blue: ThemeColor
    public let teal: ThemeColor
    public let peach: ThemeColor

    public init(
        accent: ThemeColor, panelBackground: ThemeColor, surface0: ThemeColor,
        surface1: ThemeColor, surfaceDim: ThemeColor, overlay0: ThemeColor,
        overlay1: ThemeColor, text: ThemeColor, subtext0: ThemeColor, mauve: ThemeColor,
        green: ThemeColor, yellow: ThemeColor, red: ThemeColor, blue: ThemeColor,
        teal: ThemeColor, peach: ThemeColor
    ) {
        self.accent = accent
        self.panelBackground = panelBackground
        self.surface0 = surface0
        self.surface1 = surface1
        self.surfaceDim = surfaceDim
        self.overlay0 = overlay0
        self.overlay1 = overlay1
        self.text = text
        self.subtext0 = subtext0
        self.mauve = mauve
        self.green = green
        self.yellow = yellow
        self.red = red
        self.blue = blue
        self.teal = teal
        self.peach = peach
    }
}

/// A named herdr theme: the chrome palette to draw the native sidebar with,
/// plus the herdr `[theme]` name to write into config.toml so herdr's own
/// chrome matches on its next launch. See `ThemeCatalog` for the built-in set.
public struct Theme: Hashable, Sendable {
    public let configName: String
    public let displayName: String
    public let chrome: ChromePalette

    public init(configName: String, displayName: String, chrome: ChromePalette) {
        self.configName = configName
        self.displayName = displayName
        self.chrome = chrome
    }
}

extension Theme {
    /// Extracts the `[theme]` section's `name` from an existing config.toml,
    /// if present. A full TOML parser is unnecessary: this file is entirely
    /// generated and owned by `RuntimePaths` (see `configContents`), so its
    /// shape never varies beyond what this scan handles.
    public static func name(fromConfig contents: String) -> String? {
        var inThemeSection = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inThemeSection = (trimmed == "[theme]")
                continue
            }
            guard inThemeSection, let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex ..< equals].trimmingCharacters(in: .whitespaces)
            guard key == "name" else { continue }
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
