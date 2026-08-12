import HerdaKit
import SwiftUI

/// The terminal area: one native card per visible pane, laid out from the pane
/// tree in points.
///
/// Every number here is a point on the 8pt grid and none of them depend on the
/// font. That is the difference from the first design, where the gap was one
/// character cell and the corner radius had to be squeezed out of it.
struct SplitContainerView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        GeometryReader { geometry in
            let area = CGRect(origin: .zero, size: geometry.size)
            let frames = session.frames(in: area)

            ZStack(alignment: .topLeading) {
                ForEach(session.tree.visiblePaneIds, id: \.self) { paneId in
                    if let connection = session.connections[paneId],
                       let frame = frames[paneId]
                    {
                        card(connection: connection, isFocused: isFocused(paneId))
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }

                // No divider line is drawn. The gap separates the cards and each
                // card already carries its own stroke; a hairline down the middle
                // of the gap reads as a third surface competing with both. What
                // sits in the gap is an invisible drag handle.
                ForEach(session.dividers(in: area), id: \.path) { divider in
                    DividerHandle(divider: divider, coordinateSpace: Self.areaSpace) { ratio in
                        session.setRatio(ratio, at: divider.path)
                    }
                }
            }
            .coordinateSpace(name: Self.areaSpace)
            .onAppear { session.start(viewportSize: geometry.size) }
            .onChange(of: geometry.size) { _, size in
                session.areaChanged(to: CGRect(origin: .zero, size: size))
            }
        }
    }

    private func isFocused(_ paneId: String) -> Bool {
        session.tree.focusedPaneId == paneId
    }

    /// Named so a drag reports a position in the terminal area's coordinates
    /// rather than the handle's own, which is what `Divider.ratio(at:gap:)` needs.
    private static let areaSpace = "herda.terminal-area"

    private func card(connection: PaneConnection, isFocused: Bool) -> some View {
        PaneGridRepresentable(view: connection.view)
            .padding(ChromeMetrics.panePadding)
            // Unfocused panes stay legible but recede, so the focused one reads
            // as focused without a coloured ring competing with the content.
            .opacity(isFocused ? 1 : 0.72)
            .cardSurface(
                fill: session.theme.chrome.panelBackground,
                over: session.theme.chrome.windowBackground,
                theme: session.theme,
                radius: ChromeMetrics.paneCardRadius
            )
            .contentShape(Rectangle())
            .onTapGesture { session.focus(paneId: connection.paneId) }
    }
}

/// An invisible strip in the gap that resizes the split it divides.
///
/// A view of its own so the cursor push is balanced by its own state. Pushing and
/// popping `NSCursor` from a stateless hover closure goes wrong the first time an
/// exit event is missed, and the symptom — a resize cursor stuck over the whole
/// window until the app is relaunched — is far more annoying than the feature.
private struct DividerHandle: View {
    let divider: PaneTreeLayout.Divider
    let coordinateSpace: String
    let onRatio: (Double) -> Void

    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: divider.hitRect.width, height: divider.hitRect.height)
            .offset(x: divider.hitRect.minX, y: divider.hitRect.minY)
            .onHover { inside in
                if inside, !pushedCursor {
                    pushedCursor = true
                    divider.orientation == .horizontal
                        ? NSCursor.resizeLeftRight.push()
                        : NSCursor.resizeUpDown.push()
                } else if !inside, pushedCursor {
                    pushedCursor = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                // A split can be closed while the pointer is still over its
                // divider, and then no exit event ever arrives.
                if pushedCursor { pushedCursor = false; NSCursor.pop() }
            }
            .gesture(
                // The ratio comes from the pointer's absolute position rather than
                // an accumulated translation, so the divider tracks the cursor
                // exactly instead of drifting away from it once the ratio clamps.
                //
                // Only the tree changes here, which is local and immediate. The
                // PTYs follow through PaneConnection.resize, which coalesces a
                // drag's worth of changes — each one that reached the server would
                // make the child application reflow.
                DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
                    .onChanged { value in
                        onRatio(divider.ratio(at: value.location, gap: ChromeMetrics.paneGap))
                    }
            )
    }
}

/// Hosts one pane's `TerminalGridView`.
///
/// `updateNSView` deliberately does nothing: the view is driven by its own
/// connection, and re-pushing state from SwiftUI would fight the frame stream.
private struct PaneGridRepresentable: NSViewRepresentable {
    let view: TerminalGridView

    func makeNSView(context: Context) -> TerminalGridView { view }
    func updateNSView(_ nsView: TerminalGridView, context: Context) {}
}
