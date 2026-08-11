import Darwin
import Foundation

/// Display width of a cell symbol, in terminal columns.
///
/// The wire format does not mark the filler cell that follows a wide
/// character — it is an ordinary space with `skip == false`. The renderer
/// therefore has to know which symbols advance two columns and skip the
/// following cell itself. This must agree with the server's own width
/// judgement (ghostty-vt); disagreement shears the whole row.
public enum CharWidth {
    /// `wcwidth` consults the C locale; without this it misreports non-ASCII.
    private static let localeReady: Bool = {
        setlocale(LC_CTYPE, "UTF-8")
        return true
    }()

    public static func displayWidth(of symbol: String) -> Int {
        guard let scalar = symbol.unicodeScalars.first else { return 1 }

        // Printable ASCII is every cell in most frames, and it is always one
        // column. Answering it here keeps the renderer off the `wcwidth` and
        // Unicode-property paths for the overwhelming majority of cells.
        if scalar.value >= 0x20, scalar.value < 0x7F { return 1 }

        _ = localeReady

        // Checked before wcwidth: Darwin's wcwidth reports 1 for many emoji,
        // which terminals render at two columns.
        if scalar.properties.isEmojiPresentation {
            return 2
        }

        let reported = wcwidth(wchar_t(bitPattern: scalar.value))
        if reported <= 0 {
            // Combining marks report 0, but the server already folded them
            // into a single cell, and a cell always advances at least once.
            return 1
        }
        return min(2, Int(reported))
    }
}
