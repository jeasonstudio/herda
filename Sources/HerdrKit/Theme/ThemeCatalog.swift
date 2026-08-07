/// The 18 themes herdr ships built in (`Palette` constructors in
/// src/app/state.rs), ported to this client's chrome palette so the native
/// sidebar can match whichever one herdr's own UI is configured for. The
/// terminal palette does NOT vary per theme — herdr's `[theme]` never touches
/// terminal colors (see `TerminalPalette`).
public enum ThemeCatalog {
    public static let catppuccin = Theme(
        configName: "catppuccin", displayName: "Catppuccin",
        chrome: ChromePalette(
            accent: ThemeColor(137, 180, 250), panelBackground: ThemeColor(24, 24, 37),
            surface0: ThemeColor(49, 50, 68), surface1: ThemeColor(69, 71, 90),
            surfaceDim: ThemeColor(30, 30, 46), overlay0: ThemeColor(108, 112, 134),
            overlay1: ThemeColor(127, 132, 156), text: ThemeColor(205, 214, 244),
            subtext0: ThemeColor(166, 173, 200), mauve: ThemeColor(203, 166, 247),
            green: ThemeColor(166, 227, 161), yellow: ThemeColor(249, 226, 175),
            red: ThemeColor(243, 139, 168), blue: ThemeColor(137, 180, 250),
            teal: ThemeColor(148, 226, 213), peach: ThemeColor(250, 179, 135)
        )
    )

    public static let catppuccinLatte = Theme(
        configName: "catppuccin-latte", displayName: "Catppuccin Latte",
        chrome: ChromePalette(
            accent: ThemeColor(30, 102, 245), panelBackground: ThemeColor(239, 241, 245),
            surface0: ThemeColor(204, 208, 218), surface1: ThemeColor(188, 192, 204),
            surfaceDim: ThemeColor(230, 233, 239), overlay0: ThemeColor(156, 160, 176),
            overlay1: ThemeColor(140, 143, 161), text: ThemeColor(76, 79, 105),
            subtext0: ThemeColor(108, 111, 133), mauve: ThemeColor(136, 57, 239),
            green: ThemeColor(64, 160, 43), yellow: ThemeColor(223, 142, 29),
            red: ThemeColor(210, 15, 57), blue: ThemeColor(30, 102, 245),
            teal: ThemeColor(23, 146, 153), peach: ThemeColor(254, 100, 11)
        )
    )

    /// Special case: `Palette::terminal()` (src/app/state.rs:192-211) uses
    /// named ANSI colors and `Color::Reset`, not RGB literals. Resolved once
    /// here against `TerminalPalette.ghostty`: Reset backgrounds/`text` take
    /// the client's default bg/fg; named colors take their ghostty ANSI hex.
    public static let terminal = Theme(
        configName: "terminal", displayName: "Terminal",
        chrome: ChromePalette(
            accent: ThemeColor(0x81, 0xA2, 0xBE),                        // Blue -> ANSI 4
            panelBackground: TerminalPalette.ghostty.defaultBackground,  // Reset
            surface0: TerminalPalette.ghostty.defaultBackground,         // Reset
            surface1: ThemeColor(0x66, 0x66, 0x66),                      // DarkGray -> ANSI 8
            surfaceDim: ThemeColor(0x66, 0x66, 0x66),                    // DarkGray -> ANSI 8
            overlay0: ThemeColor(0xC5, 0xC8, 0xC6),                      // Gray -> ANSI 7
            overlay1: ThemeColor(0xEA, 0xEA, 0xEA),                      // White -> ANSI 15
            text: TerminalPalette.ghostty.defaultForeground,             // Reset
            subtext0: ThemeColor(0xC5, 0xC8, 0xC6),                      // Gray -> ANSI 7
            mauve: ThemeColor(0xC5, 0xC8, 0xC6),                         // Gray -> ANSI 7
            green: ThemeColor(0xB5, 0xBD, 0x68),                         // Green -> ANSI 2
            yellow: ThemeColor(0xF0, 0xC6, 0x74),                        // Yellow -> ANSI 3
            red: ThemeColor(0xD5, 0x4E, 0x53),                           // LightRed -> ANSI 9
            blue: ThemeColor(0x81, 0xA2, 0xBE),                          // Blue -> ANSI 4
            teal: ThemeColor(0x8A, 0xBE, 0xB7),                          // Cyan -> ANSI 6
            peach: ThemeColor(0xF0, 0xC6, 0x74)                          // Yellow -> ANSI 3
        )
    )

    public static let tokyoNight = Theme(
        configName: "tokyo-night", displayName: "Tokyo Night",
        chrome: ChromePalette(
            accent: ThemeColor(122, 162, 247), panelBackground: ThemeColor(26, 27, 38),
            surface0: ThemeColor(36, 40, 59), surface1: ThemeColor(65, 72, 104),
            surfaceDim: ThemeColor(26, 27, 38), overlay0: ThemeColor(86, 95, 137),
            overlay1: ThemeColor(105, 113, 150), text: ThemeColor(192, 202, 245),
            subtext0: ThemeColor(169, 177, 214), mauve: ThemeColor(187, 154, 247),
            green: ThemeColor(158, 206, 106), yellow: ThemeColor(224, 175, 104),
            red: ThemeColor(247, 118, 142), blue: ThemeColor(122, 162, 247),
            teal: ThemeColor(125, 207, 255), peach: ThemeColor(255, 158, 100)
        )
    )

    public static let tokyoNightDay = Theme(
        configName: "tokyo-night-day", displayName: "Tokyo Night Day",
        chrome: ChromePalette(
            accent: ThemeColor(46, 125, 233), panelBackground: ThemeColor(225, 226, 231),
            surface0: ThemeColor(196, 200, 218), surface1: ThemeColor(168, 174, 203),
            surfaceDim: ThemeColor(210, 211, 218), overlay0: ThemeColor(137, 144, 179),
            overlay1: ThemeColor(104, 112, 154), text: ThemeColor(55, 96, 191),
            subtext0: ThemeColor(97, 114, 176), mauve: ThemeColor(120, 71, 189),
            green: ThemeColor(88, 117, 57), yellow: ThemeColor(140, 108, 62),
            red: ThemeColor(245, 42, 101), blue: ThemeColor(46, 125, 233),
            teal: ThemeColor(17, 140, 116), peach: ThemeColor(177, 92, 0)
        )
    )

    public static let dracula = Theme(
        configName: "dracula", displayName: "Dracula",
        chrome: ChromePalette(
            accent: ThemeColor(189, 147, 249), panelBackground: ThemeColor(40, 42, 54),
            surface0: ThemeColor(68, 71, 90), surface1: ThemeColor(98, 114, 164),
            surfaceDim: ThemeColor(40, 42, 54), overlay0: ThemeColor(98, 114, 164),
            overlay1: ThemeColor(130, 140, 180), text: ThemeColor(248, 248, 242),
            subtext0: ThemeColor(210, 210, 220), mauve: ThemeColor(255, 121, 198),
            green: ThemeColor(80, 250, 123), yellow: ThemeColor(241, 250, 140),
            red: ThemeColor(255, 85, 85), blue: ThemeColor(139, 233, 253),
            teal: ThemeColor(139, 233, 253), peach: ThemeColor(255, 184, 108)
        )
    )

    public static let nord = Theme(
        configName: "nord", displayName: "Nord",
        chrome: ChromePalette(
            accent: ThemeColor(136, 192, 208), panelBackground: ThemeColor(46, 52, 64),
            surface0: ThemeColor(59, 66, 82), surface1: ThemeColor(67, 76, 94),
            surfaceDim: ThemeColor(46, 52, 64), overlay0: ThemeColor(76, 86, 106),
            overlay1: ThemeColor(100, 110, 130), text: ThemeColor(236, 239, 244),
            subtext0: ThemeColor(216, 222, 233), mauve: ThemeColor(180, 142, 173),
            green: ThemeColor(163, 190, 140), yellow: ThemeColor(235, 203, 139),
            red: ThemeColor(191, 97, 106), blue: ThemeColor(129, 161, 193),
            teal: ThemeColor(143, 188, 187), peach: ThemeColor(208, 135, 112)
        )
    )

    public static let gruvbox = Theme(
        configName: "gruvbox", displayName: "Gruvbox",
        chrome: ChromePalette(
            accent: ThemeColor(215, 153, 33), panelBackground: ThemeColor(40, 40, 40),
            surface0: ThemeColor(60, 56, 54), surface1: ThemeColor(80, 73, 69),
            surfaceDim: ThemeColor(40, 40, 40), overlay0: ThemeColor(146, 131, 116),
            overlay1: ThemeColor(168, 153, 132), text: ThemeColor(235, 219, 178),
            subtext0: ThemeColor(213, 196, 161), mauve: ThemeColor(211, 134, 155),
            green: ThemeColor(184, 187, 38), yellow: ThemeColor(250, 189, 47),
            red: ThemeColor(251, 73, 52), blue: ThemeColor(131, 165, 152),
            teal: ThemeColor(142, 192, 124), peach: ThemeColor(254, 128, 25)
        )
    )

    public static let gruvboxLight = Theme(
        configName: "gruvbox-light", displayName: "Gruvbox Light",
        chrome: ChromePalette(
            accent: ThemeColor(7, 102, 120), panelBackground: ThemeColor(251, 241, 199),
            surface0: ThemeColor(235, 219, 178), surface1: ThemeColor(213, 196, 161),
            surfaceDim: ThemeColor(242, 229, 188), overlay0: ThemeColor(146, 131, 116),
            overlay1: ThemeColor(124, 111, 100), text: ThemeColor(60, 56, 54),
            subtext0: ThemeColor(80, 73, 69), mauve: ThemeColor(143, 63, 113),
            green: ThemeColor(121, 116, 14), yellow: ThemeColor(181, 118, 20),
            red: ThemeColor(157, 0, 6), blue: ThemeColor(7, 102, 120),
            teal: ThemeColor(66, 123, 88), peach: ThemeColor(175, 58, 3)
        )
    )

    public static let oneDark = Theme(
        configName: "one-dark", displayName: "One Dark",
        chrome: ChromePalette(
            accent: ThemeColor(97, 175, 239), panelBackground: ThemeColor(40, 44, 52),
            surface0: ThemeColor(44, 49, 58), surface1: ThemeColor(62, 68, 81),
            surfaceDim: ThemeColor(40, 44, 52), overlay0: ThemeColor(92, 99, 112),
            overlay1: ThemeColor(115, 122, 135), text: ThemeColor(171, 178, 191),
            subtext0: ThemeColor(150, 156, 168), mauve: ThemeColor(198, 120, 221),
            green: ThemeColor(152, 195, 121), yellow: ThemeColor(229, 192, 123),
            red: ThemeColor(224, 108, 117), blue: ThemeColor(97, 175, 239),
            teal: ThemeColor(86, 182, 194), peach: ThemeColor(209, 154, 102)
        )
    )

    public static let oneLight = Theme(
        configName: "one-light", displayName: "One Light",
        chrome: ChromePalette(
            accent: ThemeColor(64, 120, 242), panelBackground: ThemeColor(250, 250, 250),
            surface0: ThemeColor(240, 240, 241), surface1: ThemeColor(229, 229, 230),
            surfaceDim: ThemeColor(245, 245, 246), overlay0: ThemeColor(160, 161, 167),
            overlay1: ThemeColor(104, 107, 119), text: ThemeColor(56, 58, 66),
            subtext0: ThemeColor(104, 107, 119), mauve: ThemeColor(166, 38, 164),
            green: ThemeColor(80, 161, 79), yellow: ThemeColor(193, 132, 1),
            red: ThemeColor(228, 86, 73), blue: ThemeColor(64, 120, 242),
            teal: ThemeColor(1, 132, 188), peach: ThemeColor(152, 104, 1)
        )
    )

    public static let solarized = Theme(
        configName: "solarized", displayName: "Solarized",
        chrome: ChromePalette(
            accent: ThemeColor(38, 139, 210), panelBackground: ThemeColor(0, 43, 54),
            surface0: ThemeColor(7, 54, 66), surface1: ThemeColor(88, 110, 117),
            surfaceDim: ThemeColor(0, 43, 54), overlay0: ThemeColor(88, 110, 117),
            overlay1: ThemeColor(101, 123, 131), text: ThemeColor(147, 161, 161),
            subtext0: ThemeColor(131, 148, 150), mauve: ThemeColor(211, 54, 130),
            green: ThemeColor(133, 153, 0), yellow: ThemeColor(181, 137, 0),
            red: ThemeColor(220, 50, 47), blue: ThemeColor(38, 139, 210),
            teal: ThemeColor(42, 161, 152), peach: ThemeColor(203, 75, 22)
        )
    )

    public static let solarizedLight = Theme(
        configName: "solarized-light", displayName: "Solarized Light",
        chrome: ChromePalette(
            accent: ThemeColor(38, 139, 210), panelBackground: ThemeColor(253, 246, 227),
            surface0: ThemeColor(238, 232, 213), surface1: ThemeColor(147, 161, 161),
            surfaceDim: ThemeColor(238, 232, 213), overlay0: ThemeColor(147, 161, 161),
            overlay1: ThemeColor(88, 110, 117), text: ThemeColor(101, 123, 131),
            subtext0: ThemeColor(131, 148, 150), mauve: ThemeColor(211, 54, 130),
            green: ThemeColor(133, 153, 0), yellow: ThemeColor(181, 137, 0),
            red: ThemeColor(220, 50, 47), blue: ThemeColor(38, 139, 210),
            teal: ThemeColor(42, 161, 152), peach: ThemeColor(203, 75, 22)
        )
    )

    public static let kanagawa = Theme(
        configName: "kanagawa", displayName: "Kanagawa",
        chrome: ChromePalette(
            accent: ThemeColor(126, 156, 216), panelBackground: ThemeColor(31, 31, 40),
            surface0: ThemeColor(42, 42, 55), surface1: ThemeColor(54, 54, 70),
            surfaceDim: ThemeColor(31, 31, 40), overlay0: ThemeColor(114, 113, 105),
            overlay1: ThemeColor(135, 134, 125), text: ThemeColor(220, 215, 186),
            subtext0: ThemeColor(200, 195, 170), mauve: ThemeColor(149, 127, 184),
            green: ThemeColor(118, 148, 106), yellow: ThemeColor(192, 163, 110),
            red: ThemeColor(195, 64, 67), blue: ThemeColor(126, 156, 216),
            teal: ThemeColor(127, 180, 202), peach: ThemeColor(255, 160, 102)
        )
    )

    public static let kanagawaLotus = Theme(
        configName: "kanagawa-lotus", displayName: "Kanagawa Lotus",
        chrome: ChromePalette(
            accent: ThemeColor(77, 105, 155), panelBackground: ThemeColor(242, 236, 188),
            surface0: ThemeColor(220, 213, 172), surface1: ThemeColor(201, 203, 209),
            surfaceDim: ThemeColor(213, 206, 163), overlay0: ThemeColor(160, 156, 172),
            overlay1: ThemeColor(138, 137, 128), text: ThemeColor(84, 84, 100),
            subtext0: ThemeColor(67, 67, 108), mauve: ThemeColor(98, 76, 131),
            green: ThemeColor(111, 137, 78), yellow: ThemeColor(119, 113, 63),
            red: ThemeColor(200, 64, 83), blue: ThemeColor(77, 105, 155),
            teal: ThemeColor(78, 140, 162), peach: ThemeColor(204, 109, 0)
        )
    )

    public static let rosePine = Theme(
        configName: "rose-pine", displayName: "Rosé Pine",
        chrome: ChromePalette(
            accent: ThemeColor(196, 167, 231), panelBackground: ThemeColor(25, 23, 36),
            surface0: ThemeColor(31, 29, 46), surface1: ThemeColor(38, 35, 58),
            surfaceDim: ThemeColor(38, 35, 58), overlay0: ThemeColor(110, 106, 134),
            overlay1: ThemeColor(144, 140, 170), text: ThemeColor(224, 222, 244),
            subtext0: ThemeColor(200, 197, 220), mauve: ThemeColor(196, 167, 231),
            green: ThemeColor(49, 116, 143), yellow: ThemeColor(246, 193, 119),
            red: ThemeColor(235, 111, 146), blue: ThemeColor(49, 116, 143),
            teal: ThemeColor(156, 207, 216), peach: ThemeColor(234, 154, 151)
        )
    )

    public static let rosePineDawn = Theme(
        configName: "rose-pine-dawn", displayName: "Rosé Pine Dawn",
        chrome: ChromePalette(
            accent: ThemeColor(144, 122, 169), panelBackground: ThemeColor(250, 244, 237),
            surface0: ThemeColor(242, 233, 225), surface1: ThemeColor(255, 250, 243),
            surfaceDim: ThemeColor(242, 233, 225), overlay0: ThemeColor(152, 147, 165),
            overlay1: ThemeColor(121, 117, 147), text: ThemeColor(70, 66, 97),
            subtext0: ThemeColor(121, 117, 147), mauve: ThemeColor(144, 122, 169),
            green: ThemeColor(40, 105, 131), yellow: ThemeColor(234, 157, 52),
            red: ThemeColor(180, 99, 122), blue: ThemeColor(40, 105, 131),
            teal: ThemeColor(86, 148, 159), peach: ThemeColor(215, 130, 126)
        )
    )

    public static let vesper = Theme(
        configName: "vesper", displayName: "Vesper",
        chrome: ChromePalette(
            accent: ThemeColor(255, 199, 153), panelBackground: ThemeColor(26, 26, 26),
            surface0: ThemeColor(35, 35, 35), surface1: ThemeColor(40, 40, 40),
            surfaceDim: ThemeColor(16, 16, 16), overlay0: ThemeColor(92, 92, 92),
            overlay1: ThemeColor(126, 126, 126), text: ThemeColor(255, 255, 255),
            subtext0: ThemeColor(160, 160, 160), mauve: ThemeColor(255, 209, 168),
            green: ThemeColor(153, 255, 228), yellow: ThemeColor(255, 199, 153),
            red: ThemeColor(255, 128, 128), blue: ThemeColor(176, 176, 176),
            teal: ThemeColor(102, 221, 204), peach: ThemeColor(255, 199, 153)
        )
    )

    public static let all: [Theme] = [
        catppuccin, catppuccinLatte, terminal, tokyoNight, tokyoNightDay, dracula, nord,
        gruvbox, gruvboxLight, oneDark, oneLight, solarized, solarizedLight,
        kanagawa, kanagawaLotus, rosePine, rosePineDawn, vesper,
    ]

    public static let `default` = catppuccin

    /// Mirrors herdr's `Palette::from_name` (src/app/state.rs:560-582) exactly,
    /// including its alias table and `to_lowercase().replace([' ', '_'], "-")`
    /// normalization.
    public static func resolve(name: String) -> Theme? {
        let normalized = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "catppuccin", "catppuccin-mocha": return catppuccin
        case "catppuccin-latte", "latte", "light": return catppuccinLatte
        case "terminal": return terminal
        case "tokyo-night", "tokyonight": return tokyoNight
        case "tokyo-night-day", "tokyo-day", "tokyonight-day": return tokyoNightDay
        case "dracula": return dracula
        case "nord": return nord
        case "gruvbox", "gruvbox-dark": return gruvbox
        case "gruvbox-light": return gruvboxLight
        case "one-dark", "onedark": return oneDark
        case "one-light", "onelight": return oneLight
        case "solarized", "solarized-dark": return solarized
        case "solarized-light": return solarizedLight
        case "kanagawa": return kanagawa
        case "kanagawa-lotus", "lotus": return kanagawaLotus
        case "rose-pine", "rosepine": return rosePine
        case "rose-pine-dawn", "rosepine-dawn", "dawn": return rosePineDawn
        case "vesper": return vesper
        default: return nil
        }
    }
}
