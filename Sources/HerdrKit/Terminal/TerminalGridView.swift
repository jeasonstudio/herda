import AppKit

/// Draws a `GridFrame` with Core Text.
///
/// Cells are painted one at a time. That is enough for a prototype; if the
/// frame rate proves insufficient, the next step is to merge runs of cells
/// sharing the same attributes into a single draw call.
public final class TerminalGridView: NSView {
    public let cellSize: CGSize
    public private(set) var currentFrame: GridFrame?

    private let regularFont: NSFont
    private let boldFont: NSFont
    private let italicFont: NSFont
    private let defaultForeground: NSColor
    private let defaultBackground: NSColor

    public init(
        font: NSFont,
        foreground: NSColor = TerminalPalette.ghostty.defaultForeground.nsColor,
        background: NSColor = TerminalPalette.ghostty.defaultBackground.nsColor
    ) {
        self.regularFont = font
        let manager = NSFontManager.shared
        self.boldFont = manager.convert(font, toHaveTrait: .boldFontMask)
        self.italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
        self.defaultForeground = foreground
        self.defaultBackground = background
        self.cellSize = TerminalGridView.measureCell(font: font)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalGridView is created in code only")
    }

    /// Integral cell metrics. Fractional advances accumulate rounding error
    /// across a wide row and visibly shear the grid.
    public static func measureCell(font: NSFont) -> CGSize {
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = font.ascender - font.descender + font.leading
        return CGSize(width: max(1, advance.rounded()), height: max(1, height.rounded()))
    }

    public func gridSize(for size: CGSize) -> (columns: UInt16, rows: UInt16) {
        let columns = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        return (UInt16(min(columns, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
    }

    public func update(_ frame: GridFrame) {
        currentFrame = frame
        needsDisplay = true
    }

    /// Set by the session; receives encoded payloads ready for the socket.
    public var onPayload: (@Sendable ([UInt8]) -> Void)?

    /// Provisional input-method text, drawn at the cursor until committed.
    var markedText: String = ""

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI does not focus an NSViewRepresentable automatically.
        window?.makeFirstResponder(self)
    }

    public override func keyDown(with event: NSEvent) {
        // cmd+v is handled locally: the pane cannot read the host pasteboard.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v"
        {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                onPayload?(WireEncoder.paste(text))
            }
            return
        }

        switch KeyMap.decide(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            flags: event.modifierFlags
        ) {
        case .send(let key, let modifiers):
            onPayload?(WireEncoder.key(key, modifiers: modifiers))
        case .inputMethod:
            // Produces insertText or setMarkedText (Task 7).
            inputContext?.handleEvent(event)
        case .ignore:
            break
        }
    }

    /// Swallow the system beep for keys the pane consumes.
    public override func doCommand(by selector: Selector) {}

    /// Converts a point in view coordinates to a cell position. The view is
    /// flipped, so y increases downward and matches the row order directly.
    public func cellPosition(for point: CGPoint) -> (column: UInt16, row: UInt16) {
        let column = max(0, Int(point.x / cellSize.width))
        let row = max(0, Int(point.y / cellSize.height))
        return (
            UInt16(min(column, Int(UInt16.max))),
            UInt16(min(row, Int(UInt16.max)))
        )
    }

    private func sendMouse(_ kind: WireEncoder.MouseKind, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let position = cellPosition(for: point)
        onPayload?(
            WireEncoder.mouse(
                kind,
                column: position.column,
                row: position.row,
                modifiers: KeyMap.modifiers(from: event.modifierFlags)
            )
        )
    }

    public override func mouseDown(with event: NSEvent) { sendMouse(.down(.left), event) }
    public override func mouseUp(with event: NSEvent) { sendMouse(.up(.left), event) }
    public override func mouseDragged(with event: NSEvent) { sendMouse(.drag(.left), event) }
    public override func rightMouseDown(with event: NSEvent) { sendMouse(.down(.right), event) }
    public override func rightMouseUp(with event: NSEvent) { sendMouse(.up(.right), event) }

    public override func scrollWheel(with event: NSEvent) {
        // One event per notch; herdr treats each as a discrete scroll step.
        if event.scrollingDeltaY > 0 {
            sendMouse(.scrollUp, event)
        } else if event.scrollingDeltaY < 0 {
            sendMouse(.scrollDown, event)
        }
        if event.scrollingDeltaX > 0 {
            sendMouse(.scrollLeft, event)
        } else if event.scrollingDeltaX < 0 {
            sendMouse(.scrollRight, event)
        }
    }

    /// Row 0 must be at the top, matching the row-major cell order.
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        defaultBackground.setFill()
        bounds.fill()

        guard let grid = currentFrame else { return }

        for row in 0 ..< Int(grid.height) {
            var column = 0
            while column < Int(grid.width) {
                guard let cell = grid.cell(column: column, row: row) else { break }
                let advance = CharWidth.displayWidth(of: cell.symbol)
                draw(cell, column: column, row: row, advance: advance)
                // Skipping by display width is what keeps wide characters
                // aligned: the next cell is an unmarked filler space.
                column += advance
            }
        }

        drawCursor(grid)
        drawMarkedText(grid)
    }

    private func draw(_ cell: GridCell, column: Int, row: Int, advance: Int) {
        let rect = CGRect(
            x: CGFloat(column) * cellSize.width,
            y: CGFloat(row) * cellSize.height,
            width: cellSize.width * CGFloat(advance),
            height: cellSize.height
        )

        let reversed = cell.modifier & Modifier.reversed != 0
        var foreground = TerminalColor.unpack(cell.foreground).nsColor(default: defaultForeground)
        var background = TerminalColor.unpack(cell.background).nsColor(default: defaultBackground)
        if reversed {
            swap(&foreground, &background)
        }

        if background != defaultBackground {
            background.setFill()
            rect.fill()
        }

        guard !cell.symbol.isEmpty, cell.symbol != " " else { return }

        var font = regularFont
        if cell.modifier & Modifier.bold != 0 {
            font = boldFont
        } else if cell.modifier & Modifier.italic != 0 {
            font = italicFont
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
        ]
        if cell.modifier & Modifier.underlined != 0 {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        // The view is flipped, so this point is the glyph's top-left corner.
        (cell.symbol as NSString).draw(
            at: CGPoint(x: rect.minX, y: rect.minY),
            withAttributes: attributes
        )
    }

    private func drawCursor(_ grid: GridFrame) {
        guard let cursor = grid.cursor, cursor.isVisible else { return }
        let rect = CGRect(
            x: CGFloat(cursor.column) * cellSize.width,
            y: CGFloat(cursor.row) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
        defaultForeground.withAlphaComponent(0.6).setFill()
        rect.fill()
    }

    /// Draws in-progress input-method text at the cursor, underlined, so the
    /// user can see the composition before committing it.
    private func drawMarkedText(_ grid: GridFrame) {
        guard !markedText.isEmpty else { return }
        let column = CGFloat(grid.cursor?.column ?? 0)
        let row = CGFloat(grid.cursor?.row ?? 0)

        let columns = markedText.reduce(into: 0) { total, character in
            total += CharWidth.displayWidth(of: String(character))
        }
        let rect = CGRect(
            x: column * cellSize.width,
            y: row * cellSize.height,
            width: cellSize.width * CGFloat(max(1, columns)),
            height: cellSize.height
        )

        defaultBackground.setFill()
        rect.fill()

        (markedText as NSString).draw(
            at: CGPoint(x: rect.minX, y: rect.minY),
            withAttributes: [
                .font: regularFont,
                .foregroundColor: defaultForeground,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
    }

    /// ratatui `Modifier` bit positions.
    private enum Modifier {
        static let bold: UInt16 = 1 << 0
        static let dim: UInt16 = 1 << 1
        static let italic: UInt16 = 1 << 2
        static let underlined: UInt16 = 1 << 3
        static let reversed: UInt16 = 1 << 6
    }
}

// NSView is already main-actor isolated; isolating the conformance to match
// lets these methods touch view state. The input method only calls them on the
// main thread. `@MainActor` sits on the conformance clause — as an attribute on
// the extension it is silently ignored.
extension TerminalGridView: @MainActor NSTextInputClient {
    /// Composition finished: send the committed text.
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as String: text = value
        case let value as NSAttributedString: text = value.string
        default: return
        }
        markedText = ""
        needsDisplay = true
        guard !text.isEmpty else { return }
        onPayload?(WireEncoder.textCommit(text))
    }

    /// Composition in progress: hold the provisional text for drawing.
    public func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        switch string {
        case let value as String: markedText = value
        case let value as NSAttributedString: markedText = value.string
        default: markedText = ""
        }
        needsDisplay = true
    }

    public func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: markedText.utf16.count, length: 0)
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Positions the candidate window at the cursor. Without this it appears in
    /// a corner of the screen, which makes CJK input unusable in practice.
    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        let cursor = currentFrame?.cursor
        let column = CGFloat(cursor?.column ?? 0)
        let row = CGFloat(cursor?.row ?? 0)
        let local = CGRect(
            x: column * cellSize.width,
            y: row * cellSize.height,
            width: cellSize.width * CGFloat(max(1, markedText.count)),
            height: cellSize.height
        )
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
