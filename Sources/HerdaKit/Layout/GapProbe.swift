import Foundation

/// Detects content drawn outside every pane rect.
///
/// Config silences the dialogs herdr raises on its own, but the ones a prefix key
/// opens — Navigator, GlobalMenu, KeybindHelp — still draw on the whole grid and
/// cross pane boundaries. Slicing by rect would cut such a modal at the card gap
/// and drop whatever sits in the gap column outright.
///
/// With `pane_borders = false` that column is blank by construction, which makes
/// "something is in the gap" a reliable signal to fall back to whole-grid
/// rendering, with no extra API call.
///
/// **The premise is not yet measured.** The one-cell gap between rects is
/// confirmed, but nothing has actually looked at the contents of that column: the
/// CLI can only read a single pane, so verifying it needs a client that sees the
/// whole grid. Treat this as a well-founded assumption until then.
public enum GapProbe {
    public static func hasContentOutsidePanes(
        _ frame: GridFrame,
        panes: [PaneLayoutRect]
    ) -> Bool {
        firstContentOutsidePanes(frame, panes: panes) != nil
    }

    /// The first non-blank cell that no pane rect covers, in row-major order.
    ///
    /// Exists for diagnosis as much as for the check above: knowing that
    /// *something* crossed a boundary is not enough to explain why the card grid
    /// fell back to one big card — the offending coordinate is what makes that
    /// traceable in the log.
    public static func firstContentOutsidePanes(
        _ frame: GridFrame,
        panes: [PaneLayoutRect]
    ) -> (column: Int, row: Int, symbol: String)? {
        let width = Int(frame.width)
        let height = Int(frame.height)
        guard width > 0, height > 0 else { return nil }

        var covered = [Bool](repeating: false, count: width * height)
        for rect in panes {
            let rowRange = Int(rect.y)..<min(Int(rect.y) + Int(rect.height), height)
            let columnRange = Int(rect.x)..<min(Int(rect.x) + Int(rect.width), width)
            guard rowRange.lowerBound < rowRange.upperBound,
                  columnRange.lowerBound < columnRange.upperBound
            else { continue }
            for row in rowRange {
                let rowStart = row * width
                for column in columnRange {
                    covered[rowStart + column] = true
                }
            }
        }

        for index in 0..<min(covered.count, frame.cells.count) where !covered[index] {
            let symbol = frame.cells[index].symbol
            if !isBlank(symbol) {
                return (column: index % width, row: index / width, symbol: symbol)
            }
        }
        return nil
    }

    /// ratatui pads empty regions with ordinary spaces. Tabs and newlines are not
    /// content either.
    private static func isBlank(_ symbol: String) -> Bool {
        symbol.isEmpty || symbol.allSatisfy(\.isWhitespace)
    }
}
