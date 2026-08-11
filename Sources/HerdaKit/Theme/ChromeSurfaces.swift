import Foundation

extension ThemeColor {
    /// Blends toward `other`: 0 returns self, 1 returns `other`.
    func mixed(with other: ThemeColor, _ fraction: Double) -> ThemeColor {
        let ratio = min(max(fraction, 0), 1)
        func blend(_ from: UInt8, _ to: UInt8) -> UInt8 {
            let value = Double(from) + (Double(to) - Double(from)) * ratio
            return UInt8(min(max(value.rounded(), 0), 255))
        }
        return ThemeColor(
            blend(red, other.red),
            blend(green, other.green),
            blend(blue, other.blue)
        )
    }
}

/// Chrome surfaces the native window needs but herdr's own `Palette` does not
/// define, derived from each theme's tokens so all 18 get them for free.
///
/// herdr draws its whole UI as character cells on one background, so it never
/// needed a second surface. A native window does: the roster and the terminal
/// are separate planes and have to read as such. Deriving them beats
/// hand-authoring 18 more values, and lands close to what the theme authors
/// picked anyway — for both Catppuccin variants the derived sidebar is within a
/// few points of their own `surfaceDim` — while still separating the planes for
/// the themes that set `surfaceDim` equal to `panelBackground`.
extension ChromePalette {
    /// The roster's plane, lifted off `panelBackground` toward the text color so
    /// it separates from the terminal in light and dark themes alike.
    public var sidebarBackground: ThemeColor { panelBackground.mixed(with: text, 0.06) }

    /// Hairline rules: the sidebar/terminal seam and the footer separator.
    public var hairline: ThemeColor { panelBackground.mixed(with: text, 0.16) }

    /// The color that stands for an agent state. Follows herdr's own semantics
    /// for these tokens (the `Palette` doc comments in src/app/state.rs): yellow
    /// is running, red needs a person, green has finished.
    public func color(for status: AgentStatus) -> ThemeColor {
        switch status {
        case .working: return yellow
        case .blocked: return red
        case .done: return green
        case .idle, .unknown: return overlay0
        }
    }
}

extension Theme {
    /// Whether this theme wants dark system chrome.
    ///
    /// The window is painted from the theme, not from the system appearance, so
    /// the two can disagree: a dark theme under a light system leaves every
    /// system-drawn control — menu text, scrollers, spinners, focus rings —
    /// dark-on-dark. The app matches `NSAppearance` to this instead.
    public var isDark: Bool {
        chrome.panelBackground.luminance < chrome.text.luminance
    }
}
