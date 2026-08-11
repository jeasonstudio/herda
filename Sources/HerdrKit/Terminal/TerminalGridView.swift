import AppKit
import CoreText

/// Draws a `GridFrame` with Core Text.
///
/// The frame is painted in ordered passes rather than cell by cell. Drawing each
/// cell with its own `NSString.draw` measured 45.6 ms for a 140×47 grid — a
/// 22 fps ceiling before any other work — because every call builds a fresh text
/// layout and re-resolves font fallback. Grouping the same content into one draw
/// call per (font, colour) brought the same frame to 3.1 ms.
///
/// The passes also fix what per-cell drawing could not express:
///
/// - Backgrounds merge into horizontal runs, so a filled region is one rect.
/// - Block elements are geometry, not glyphs (`CellGeometry`): a font's block
///   outlines do not fill the cell, which leaves seams between rows of them.
/// - Every glyph sits on one shared baseline, so a row mixing Latin, CJK and
///   emoji does not come out on three different lines.
/// - Underlines and strikethroughs are continuous rects instead of per-cell
///   segments that break at every cell edge.
public final class TerminalGridView: NSView {
    public let cellSize: CGSize
    public private(set) var currentFrame: GridFrame?

    private let terminalFont: TerminalFont
    private let glyphs: GlyphCache
    private let baseline: CGFloat

    private var palette: TerminalPalette
    private var defaultForeground: Ink
    private var defaultBackground: Ink

    private var windowIsKey = false
    private var isFirstResponder = false
    private let focusObservers = ObserverTokens()

    private var verticalScroll: ScrollAccumulator
    private var horizontalScroll: ScrollAccumulator

    /// Provisional input-method text, drawn at the cursor until committed.
    var markedText: String = ""
    /// Clause the input method currently has selected inside `markedText`.
    private var markedSelection = NSRange(location: 0, length: 0)
    /// Whether `doCommand(by:)` already sent a key for the event being handled,
    /// so `keyDown` does not send it a second time.
    private var commandSentAKey = false

    public init(
        terminalFont: TerminalFont,
        palette: TerminalPalette = .ghostty
    ) {
        self.terminalFont = terminalFont
        self.glyphs = GlyphCache(font: terminalFont)
        self.cellSize = terminalFont.cellSize
        self.baseline = terminalFont.baselineFromTop
        self.palette = palette
        self.defaultForeground = Ink(palette.defaultForeground)
        self.defaultBackground = Ink(palette.defaultBackground)
        self.verticalScroll = ScrollAccumulator(threshold: terminalFont.cellSize.height)
        self.horizontalScroll = ScrollAccumulator(threshold: terminalFont.cellSize.width)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalGridView is created in code only")
    }

    /// Swaps in a new theme's terminal palette and repaints.
    public func applyTheme(_ theme: Theme) {
        palette = theme.terminal
        defaultForeground = Ink(palette.defaultForeground)
        defaultBackground = Ink(palette.defaultBackground)
        needsDisplay = true
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

    /// Row 0 must be at the top, matching the row-major cell order.
    public override var isFlipped: Bool { true }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Focus

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowFocus()
        windowIsKey = window?.isKeyWindow ?? false
        // SwiftUI does not focus an NSViewRepresentable automatically.
        window?.makeFirstResponder(self)
    }

    /// The cursor's appearance depends on whether this view has keyboard focus,
    /// so both halves of "focused" are tracked as they change rather than
    /// sampled during drawing, where `firstResponder` may not be updated yet.
    private func observeWindowFocus() {
        focusObservers.clear()
        guard let window else { return }

        let center = NotificationCenter.default
        focusObservers.replace(with: [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setWindowIsKey(true) }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setWindowIsKey(false) }
            },
        ])
    }

    private func setWindowIsKey(_ value: Bool) {
        guard windowIsKey != value else { return }
        windowIsKey = value
        // A composition cannot survive the window losing focus: the input
        // method's own state is gone, so keeping the provisional text on screen
        // would leave it stranded there.
        if !value { abandonComposition() }
        needsDisplay = true
    }

    public override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        isFirstResponder = false
        abandonComposition()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    private var isTerminalFocused: Bool { windowIsKey && isFirstResponder }

    private func abandonComposition() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        inputContext?.discardMarkedText()
    }

    // MARK: - Keyboard

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
            flags: event.modifierFlags,
            composing: hasMarkedText()
        ) {
        case .send(let key, let modifiers):
            onPayload?(WireEncoder.key(key, modifiers: modifiers))
        case .inputMethod:
            // Produces insertText, setMarkedText, or doCommand(by:). An input
            // method has three ways to answer, and all three have to be handled
            // or the key is silently swallowed.
            commandSentAKey = false
            let consumed = inputContext?.handleEvent(event) == true
            guard !consumed, !commandSentAKey else { break }
            // Declined outright: the pane still needs it.
            let fallback = KeyMap.decide(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                flags: event.modifierFlags,
                composing: false
            )
            if case .send(let key, let modifiers) = fallback {
                onPayload?(WireEncoder.key(key, modifiers: modifiers))
            }
        case .ignore:
            break
        }
    }

    /// An input method frequently answers a key by turning it into a standard
    /// editing command and reporting success, so those have to be translated
    /// back. Commands with no wire key are swallowed, which suppresses the system
    /// beep for keys the pane consumes.
    public override func doCommand(by selector: Selector) {
        guard let key = KeyMap.key(forCommand: selector) else { return }
        commandSentAKey = true
        onPayload?(WireEncoder.key(key, modifiers: []))
    }

    // MARK: - Mouse

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

    public override func mouseDown(with event: NSEvent) {
        // Clicking a SwiftUI control in the sidebar takes first responder away,
        // and nothing gives it back — typing would go nowhere until the window
        // was re-focused.
        if !isFirstResponder { window?.makeFirstResponder(self) }
        sendMouse(.down(.left), event)
    }

    public override func mouseUp(with event: NSEvent) { sendMouse(.up(.left), event) }
    public override func mouseDragged(with event: NSEvent) { sendMouse(.drag(.left), event) }
    public override func rightMouseDown(with event: NSEvent) { sendMouse(.down(.right), event) }
    public override func rightMouseUp(with event: NSEvent) { sendMouse(.up(.right), event) }

    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let vertical = verticalScroll.steps(delta: event.scrollingDeltaY, precise: precise)
        let horizontal = horizontalScroll.steps(delta: event.scrollingDeltaX, precise: precise)

        for _ in 0 ..< abs(vertical) {
            sendMouse(vertical > 0 ? .scrollUp : .scrollDown, event)
        }
        for _ in 0 ..< abs(horizontal) {
            sendMouse(horizontal > 0 ? .scrollLeft : .scrollRight, event)
        }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2

        context.setShouldAntialias(false)
        context.setFillColor(defaultBackground.cgColor)
        context.fill(bounds)

        guard let grid = currentFrame else { return }

        var plan = RenderPlan()
        collect(grid, into: &plan, backingScale: scale)

        // Ordered: backgrounds, then block geometry on top of them, then glyphs,
        // then anything that annotates a glyph, then the cursor.
        fill(plan.backgrounds, in: context)
        fill(plan.geometry, in: context)
        drawGlyphs(plan, in: context)
        context.setShouldAntialias(false)
        fill(plan.decorations, in: context)
        fill(plan.overlays, in: context)
        for outline in plan.outlines {
            context.setStrokeColor(outline.ink.cgColor)
            context.setLineWidth(1)
            context.stroke(outline.rect.insetBy(dx: 0.5, dy: 0.5))
        }

        drawComposition(in: context, backingScale: scale)
    }

    private func fill(_ groups: [Ink: [CGRect]], in context: CGContext) {
        for (ink, rects) in groups {
            context.setFillColor(ink.cgColor)
            context.fill(rects)
        }
    }

    /// Walks the frame once and sorts every cell into the pass it belongs to.
    private func collect(_ grid: GridFrame, into plan: inout RenderPlan, backingScale: CGFloat) {
        let width = Int(grid.width)
        let height = Int(grid.height)
        let cursor = grid.cursor.flatMap { $0.isVisible ? $0 : nil }
        let presentation = cursor.map { CursorPresentation.resolve(shape: $0.shape, focused: isTerminalFocused) }
        // Only a block cursor inverts the cell; the others sit on top of it, so
        // the character underneath stays as it was.
        let invertsCursorCell = presentation == .block
        let cursorColumn = cursor.map { Int($0.column) } ?? -1
        let cursorRow = cursor.map { Int($0.row) } ?? -1
        // Read once: `bounds` is a property lookup, and the glyph pass needs the
        // view's height for every cell.
        let flipHeight = bounds.height

        for row in 0 ..< height {
            var run: BackgroundRun?
            var column = 0

            while column < width {
                guard let cell = grid.cell(column: column, row: row) else { break }
                let advance = min(CharWidth.displayWidth(of: cell.symbol), width - column)

                var (foreground, background) = colors(for: cell)
                if invertsCursorCell, column == cursorColumn, row == cursorRow {
                    background = defaultForeground
                    foreground = defaultBackground
                }

                let origin = CGPoint(
                    x: CGFloat(column) * cellSize.width,
                    y: CGFloat(row) * cellSize.height
                )
                let slot = CGRect(
                    origin: origin,
                    size: CGSize(width: cellSize.width * CGFloat(advance), height: cellSize.height)
                )

                if background == defaultBackground {
                    run?.flush(into: &plan)
                    run = nil
                } else if let current = run, current.ink == background {
                    run?.extend(to: slot.maxX)
                } else {
                    run?.flush(into: &plan)
                    run = BackgroundRun(ink: background, rect: slot)
                }

                append(
                    cell,
                    foreground: foreground,
                    origin: origin,
                    advance: advance,
                    flipHeight: flipHeight,
                    into: &plan,
                    backingScale: backingScale
                )

                column += advance
            }
            run?.flush(into: &plan)
        }

        if let cursor, let presentation {
            appendCursor(cursor, as: presentation, into: &plan, backingScale: backingScale)
        }
    }

    /// Adds one cell's glyph and text decorations.
    private func append(
        _ cell: GridCell,
        foreground: Ink,
        origin: CGPoint,
        advance: Int,
        flipHeight: CGFloat,
        into plan: inout RenderPlan,
        backingScale: CGFloat
    ) {
        // `hidden` keeps the cell's background but suppresses its content —
        // password prompts rely on it.
        guard cell.modifier & Modifier.hidden == 0 else { return }

        if let fill = CellGeometry.fill(for: cell.symbol) {
            let ink: Ink
            switch fill {
            case .rects: ink = foreground
            case .shade(let opacity): ink = foreground.withAlpha(opacity)
            }
            plan.geometry[ink, default: []].append(
                contentsOf: CellGeometry.deviceRects(
                    fill,
                    cellOrigin: origin,
                    cellSize: cellSize,
                    backingScale: backingScale
                )
            )
        } else {
            let resolved = glyphs.resolve(
                symbol: cell.symbol,
                bold: cell.modifier & Modifier.bold != 0,
                italic: cell.modifier & Modifier.italic != 0
            )
            plan.add(resolved, at: origin, baseline: baseline, flipHeight: flipHeight, ink: foreground)
        }

        let width = cellSize.width * CGFloat(advance)
        if cell.modifier & Modifier.underlined != 0 {
            plan.decorations[foreground, default: []].append(
                CGRect(
                    x: origin.x,
                    y: snapToDevicePixels(origin.y + baseline + 1, scale: backingScale),
                    width: width,
                    height: 1
                )
            )
        }
        if cell.modifier & Modifier.crossedOut != 0 {
            plan.decorations[foreground, default: []].append(
                CGRect(
                    x: origin.x,
                    y: snapToDevicePixels(
                        origin.y + baseline - terminalFont.regular.xHeight / 2,
                        scale: backingScale
                    ),
                    width: width,
                    height: 1
                )
            )
        }
    }

    /// Everything except the block, which `collect` already handled by inverting
    /// the cell.
    private func appendCursor(
        _ cursor: GridCursor,
        as presentation: CursorPresentation,
        into plan: inout RenderPlan,
        backingScale: CGFloat
    ) {
        let cell = CGRect(
            x: CGFloat(cursor.column) * cellSize.width,
            y: CGFloat(cursor.row) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
        let thickness = snapToDevicePixels(2, scale: backingScale)

        switch presentation {
        case .block:
            break
        case .underline:
            plan.overlays[defaultForeground, default: []].append(
                CGRect(x: cell.minX, y: cell.maxY - thickness, width: cell.width, height: thickness)
            )
        case .bar:
            plan.overlays[defaultForeground, default: []].append(
                CGRect(x: cell.minX, y: cell.minY, width: thickness, height: cell.height)
            )
        case .outline:
            plan.outlines.append(Outline(rect: cell, ink: defaultForeground))
        }
    }

    /// Core Text lays glyphs out in a y-up space. Flipping the context for this
    /// one pass keeps every other pass in view coordinates, where the rectangles
    /// were computed.
    private func drawGlyphs(_ plan: RenderPlan, in context: CGContext) {
        guard !plan.batches.isEmpty || !plan.placed.isEmpty else { return }

        context.saveGState()
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity

        for (key, batch) in plan.batches {
            context.setFillColor(key.ink.cgColor)
            CTFontDrawGlyphs(batch.font, batch.glyphs, batch.positions, batch.glyphs.count, context)
        }

        // Glyphs that had to be scaled to fit their slot, and multi-glyph
        // clusters. Scaling through the text matrix would move the origin too,
        // so the context is translated to the origin and the glyph drawn at zero.
        for placed in plan.placed {
            context.saveGState()
            context.setFillColor(placed.ink.cgColor)
            context.translateBy(x: placed.position.x, y: placed.position.y)
            context.scaleBy(x: placed.scale, y: placed.scale)
            switch placed.content {
            case .glyph(let font, var glyph):
                var origin = CGPoint.zero
                context.textMatrix = .identity
                CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
            case .line(let line):
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(line, context)
            }
            context.restoreGState()
        }

        context.restoreGState()
    }

    // MARK: - Composition

    /// Grid placement of the in-progress input-method text. Shared with
    /// `firstRect(forCharacterRange:)` so the candidate window cannot drift away
    /// from the text it belongs to.
    private func compositionSlots() -> [MarkedText.Slot] {
        guard !markedText.isEmpty else { return [] }
        let grid = currentFrame
        let width = Int(grid?.width ?? 1)
        let height = Int(grid?.height ?? 1)
        return MarkedText.layout(
            markedText,
            cursorColumn: Int(grid?.cursor?.column ?? 0),
            cursorRow: Int(grid?.cursor?.row ?? 0),
            gridWidth: width,
            gridHeight: height
        )
    }

    /// Draws the composition over the grid: the pane knows nothing about it, so
    /// it has to be painted last, on its own background.
    private func drawComposition(in context: CGContext, backingScale: CGFloat) {
        let slots = compositionSlots()
        guard !slots.isEmpty else { return }

        var plan = RenderPlan()
        for slot in slots {
            let origin = CGPoint(
                x: CGFloat(slot.column) * cellSize.width,
                y: CGFloat(slot.row) * cellSize.height
            )
            let width = cellSize.width * CGFloat(slot.width)
            plan.backgrounds[defaultBackground, default: []].append(
                CGRect(origin: origin, size: CGSize(width: width, height: cellSize.height))
            )
            plan.add(
                glyphs.resolve(symbol: slot.symbol),
                at: origin,
                baseline: baseline,
                flipHeight: bounds.height,
                ink: defaultForeground
            )

            // macOS marks the clause under conversion with a heavier underline.
            let end = slot.utf16Offset + slot.symbol.utf16.count
            let selected = slot.utf16Offset >= markedSelection.location
                && end <= markedSelection.location + max(markedSelection.length, 1)
            let thickness = snapToDevicePixels(selected ? 2 : 1, scale: backingScale)
            plan.decorations[defaultForeground, default: []].append(
                CGRect(
                    x: origin.x,
                    y: snapToDevicePixels(origin.y + cellSize.height - thickness, scale: backingScale),
                    width: width,
                    height: thickness
                )
            )
        }

        context.setShouldAntialias(false)
        fill(plan.backgrounds, in: context)
        drawGlyphs(plan, in: context)
        context.setShouldAntialias(false)
        fill(plan.decorations, in: context)
    }

    // MARK: - Colors

    private func colors(for cell: GridCell) -> (foreground: Ink, background: Ink) {
        var foreground = ink(cell.foreground, or: defaultForeground)
        var background = ink(cell.background, or: defaultBackground)
        if cell.modifier & Modifier.reversed != 0 {
            swap(&foreground, &background)
        }
        if cell.modifier & Modifier.dim != 0 {
            foreground = foreground.blended(with: background, fraction: 0.5)
        }
        return (foreground, background)
    }

    private func ink(_ packed: UInt32, or fallback: Ink) -> Ink {
        switch TerminalColor.unpack(packed, palette: palette) {
        case .reset: return fallback
        case .rgb(let red, let green, let blue): return Ink(red, green, blue)
        }
    }

    /// ratatui `Modifier` bit positions.
    private enum Modifier {
        static let bold: UInt16 = 1 << 0
        static let dim: UInt16 = 1 << 1
        static let italic: UInt16 = 1 << 2
        static let underlined: UInt16 = 1 << 3
        static let reversed: UInt16 = 1 << 6
        static let hidden: UInt16 = 1 << 7
        static let crossedOut: UInt16 = 1 << 8
    }
}

/// How the cursor is drawn, given its DECSCUSR shape and whether the pane has
/// keyboard focus.
///
/// An unfocused pane always draws an outline, whatever the shape: the point is to
/// show where the cursor is without claiming it will receive what the user types.
/// Only the block replaces the cell's colours; the others are overlays, so the
/// character underneath stays legible.
public enum CursorPresentation: Equatable, Sendable {
    case block
    case underline
    case bar
    case outline

    public static func resolve(shape: UInt8, focused: Bool) -> CursorPresentation {
        guard focused else { return .outline }
        switch shape {
        case 3, 4: return .underline
        case 5, 6: return .bar
        default: return .block // 0 default, 1/2 block, and anything unknown
        }
    }
}

/// Owns notification tokens so they can be unregistered when the view goes away.
///
/// The view is main-actor isolated and its `deinit` is not, so it cannot reach
/// its own stored properties there. Holding the tokens in a separate object
/// moves the cleanup into that object's `deinit`, which runs at the same moment
/// and only calls `removeObserver` — thread-safe on its own.
///
/// `@unchecked Sendable`: the array is mutated only from the main actor, and the
/// deinit that reads it runs after the last reference is gone, so no two
/// accesses can overlap.
private final class ObserverTokens: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func replace(with new: [NSObjectProtocol]) {
        clear()
        tokens = new
    }

    func clear() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }

    deinit { clear() }
}

// MARK: - Render plan

/// A colour in the terminal's own space. Hashable so draw calls can be grouped
/// by it without touching `NSColor` on the hot path.
struct Ink: Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: ThemeColor) {
        self.init(color.red, color.green, color.blue)
    }

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    func withAlpha(_ opacity: CGFloat) -> Ink {
        Ink(red, green, blue, alpha: UInt8(clamping: Int((opacity * 255).rounded())))
    }

    /// Mixes toward `other`. `dim` is expressed this way rather than as
    /// transparency so it stays legible on a light theme too.
    func blended(with other: Ink, fraction: Double) -> Ink {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(clamping: Int((Double(a) * (1 - fraction) + Double(b) * fraction).rounded()))
        }
        return Ink(mix(red, other.red), mix(green, other.green), mix(blue, other.blue), alpha: alpha)
    }
}

/// Everything one frame needs to draw, grouped so each group is a single call.
private struct RenderPlan {
    struct BatchKey: Hashable {
        let fontId: Int
        let ink: Ink
    }

    struct Batch {
        let font: CTFont
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []

        mutating func append(_ glyph: CGGlyph, at position: CGPoint) {
            glyphs.append(glyph)
            positions.append(position)
        }
    }

    enum Content {
        case glyph(CTFont, CGGlyph)
        case line(CTLine)
    }

    /// A glyph that cannot join a batch because it carries its own transform.
    struct Placed {
        let content: Content
        let position: CGPoint
        let scale: CGFloat
        let ink: Ink
    }

    /// Kept apart from `geometry` because a shaded cell can also carry its own
    /// background colour, and dictionary iteration order is arbitrary — merged
    /// into one bucket, the background would sometimes paint over the shade.
    var backgrounds: [Ink: [CGRect]] = [:]
    var geometry: [Ink: [CGRect]] = [:]
    var batches: [BatchKey: Batch] = [:]
    var placed: [Placed] = []
    var decorations: [Ink: [CGRect]] = [:]
    /// Cursor shapes that sit on top of the cell rather than replacing it.
    var overlays: [Ink: [CGRect]] = [:]
    var outlines: [Outline] = []

    mutating func add(
        _ resolved: GlyphCache.Resolved,
        at origin: CGPoint,
        baseline: CGFloat,
        flipHeight: CGFloat,
        ink: Ink
    ) {
        guard let placement = resolved.placement else { return }
        // Core Text's y-up space: the baseline measured from the bottom edge.
        let position = CGPoint(
            x: origin.x + placement.xOffset,
            y: flipHeight - (origin.y + baseline)
        )

        switch resolved {
        case .blank:
            return
        case .line(let line, _):
            placed.append(Placed(content: .line(line), position: position, scale: placement.scale, ink: ink))
        case .glyph(let font, let fontId, let glyph, _):
            guard placement.scale == 1 else {
                placed.append(
                    Placed(content: .glyph(font, glyph), position: position, scale: placement.scale, ink: ink)
                )
                return
            }
            // The `default:` subscript mutates in place. Reading into a local
            // and writing back would copy both arrays on every cell, which is
            // quadratic in the number of glyphs sharing a batch.
            batches[BatchKey(fontId: fontId, ink: ink), default: Batch(font: font)]
                .append(glyph, at: position)
        }
    }
}

private struct Outline {
    let rect: CGRect
    let ink: Ink
}

/// A stretch of adjacent cells sharing one background colour.
private struct BackgroundRun {
    let ink: Ink
    var rect: CGRect

    mutating func extend(to x: CGFloat) {
        rect.size.width = x - rect.minX
    }

    func flush(into plan: inout RenderPlan) {
        plan.backgrounds[ink, default: []].append(rect)
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
        markedSelection = NSRange(location: 0, length: 0)
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
        markedSelection = selectedRange
        needsDisplay = true
    }

    public func unmarkText() {
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange { markedSelection }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        let units = Array(markedText.utf16)
        guard range.location >= 0, range.location + range.length <= units.count else { return nil }
        let slice = units[range.location ..< range.location + range.length]
        actualRange?.pointee = range
        return NSAttributedString(string: String(decoding: slice, as: UTF16.self))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.markedClauseSegment, .underlineStyle]
    }

    /// Positions the candidate window at the composition. Without this it
    /// appears in a corner of the screen, which makes CJK input unusable in
    /// practice; measured in display columns rather than characters, so a
    /// half-typed CJK phrase does not report itself as half as wide as it is.
    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        let cursor = currentFrame?.cursor
        let fallback = CGRect(
            x: CGFloat(cursor?.column ?? 0) * cellSize.width,
            y: CGFloat(cursor?.row ?? 0) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
        let local = MarkedText.boundingRect(
            for: range,
            in: compositionSlots(),
            cellSize: cellSize
        ) ?? fallback
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
