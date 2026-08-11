import Foundation

/// Shortens a working directory into something that fits a sidebar row.
///
/// The leaf directories identify an agent's checkout; the path down to them
/// rarely does. Middle-truncating the string itself would cut mid-component and
/// leave an unreadable stub, so the elision happens at component boundaries.
public enum PathLabel {
    /// `/Users/jo/Projects/github.com/herdrdev/herdr` -> `~/…/herdrdev/herdr`.
    ///
    /// Paths already short enough are returned untouched: dropping `usr` from
    /// `/usr/local/bin` costs more in legibility than it saves in width, so
    /// eliding only happens when it makes a real difference.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = stripTrailingSlash(path)
        guard !trimmed.isEmpty else { return "" }

        let display = tildeSubstituted(trimmed, home: stripTrailingSlash(home))
        var components = display.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        // First component is the root marker: "" for an absolute path, "~" for a
        // path inside the home directory.
        let root = components.removeFirst()
        guard components.count > 2 else { return display }

        let elided = root + "/…/" + components.suffix(2).joined(separator: "/")
        return elided.count + 4 < display.count ? elided : display
    }

    private static func tildeSubstituted(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
