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
                // of the gap reads as a third surface competing with both.
                // `PaneTreeLayout.dividers` still computes the drag targets.
            }
            .onAppear { session.start(viewportSize: geometry.size) }
            .onChange(of: geometry.size) { _, size in
                session.areaChanged(to: CGRect(origin: .zero, size: size))
            }
        }
    }

    private func isFocused(_ paneId: String) -> Bool {
        session.tree.focusedPaneId == paneId
    }

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

/// Hosts one pane's `TerminalGridView`.
///
/// `updateNSView` deliberately does nothing: the view is driven by its own
/// connection, and re-pushing state from SwiftUI would fight the frame stream.
private struct PaneGridRepresentable: NSViewRepresentable {
    let view: TerminalGridView

    func makeNSView(context: Context) -> TerminalGridView { view }
    func updateNSView(_ nsView: TerminalGridView, context: Context) {}
}
