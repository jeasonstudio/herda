import Combine
import HerdrKit
import SwiftUI

struct ContentView: View {
    @StateObject private var session = TerminalSession()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                model: session.sidebar,
                onSelectWorkspace: { session.focusWorkspace($0) },
                onSelectPane: { session.focusPane($0) }
            )
            .frame(width: 220)
            .background(.thinMaterial)

            Divider()

            terminalArea
        }
        .onDisappear { session.shutdown() }
    }

    /// The M1/M2 terminal surface, unchanged apart from being nested.
    private var terminalArea: some View {
        GeometryReader { geometry in
            ZStack {
                GridViewRepresentable(view: session.view)
                    .onAppear { session.start(viewportSize: geometry.size) }
                    .onChange(of: geometry.size) { _, size in session.resize(to: size) }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSWindow.didBecomeKeyNotification
                        )
                    ) { _ in session.reportFocus(gained: true) }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSWindow.didResignKeyNotification
                        )
                    ) { _ in session.reportFocus(gained: false) }

                switch session.state {
                case .idle, .starting:
                    ProgressView(statusText)
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                case .failed(let message), .disconnected(let message):
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(40)
                case .running:
                    EmptyView()
                }
            }
        }
    }

    private var statusText: String {
        if case .starting(let detail) = session.state { return detail }
        return "starting herdr…"
    }
}

private struct GridViewRepresentable: NSViewRepresentable {
    let view: TerminalGridView

    func makeNSView(context: Context) -> TerminalGridView { view }
    func updateNSView(_ nsView: TerminalGridView, context: Context) {}
}
