import Combine
import HerdaKit
import SwiftUI

struct ContentView: View {
    @StateObject private var session = TerminalSession()

    var body: some View {
        // 只有终端浮起。sidebar 与窗口底同一层、同一底色,所以它贴着窗口
        // 左边缘、铺满整个高度,由自己的内容让开红绿灯(见
        // ChromeMetrics.contentTopInset)。窗口只有一个"面",卡片浮在它上面。
        HStack(spacing: 0) {
            // Every sidebar action hands keyboard focus back: SwiftUI's Button
            // and Menu take first responder when clicked, and until it returns
            // the terminal silently ignores typing.
            SidebarView(
                model: session.sidebar,
                theme: session.theme,
                onSelectWorkspace: {
                    session.focusWorkspace($0)
                    session.focusTerminal()
                },
                onSelectPane: {
                    session.focusPane($0)
                    session.focusTerminal()
                },
                onSelectTheme: {
                    session.setTheme($0)
                    session.focusTerminal()
                }
            )
            .frame(width: 224)

            terminalArea
                .cardSurface(
                    fill: session.theme.chrome.panelBackground,
                    over: session.theme.chrome.windowBackground,
                    theme: session.theme
                )
                .padding(.leading, ChromeMetrics.cardGap)
                .padding(.top, ChromeMetrics.contentTopInset)
                .padding(.trailing, ChromeMetrics.cardInset)
                .padding(.bottom, ChromeMetrics.cardInset)
        }
        .background(session.theme.chrome.windowBackground.color)
        .ignoresSafeArea(.container, edges: .top)
        // System-drawn chrome — menus, scrollers, spinners — reads the appearance,
        // not the theme, so the two are kept in step.
        .onChange(of: session.theme, initial: true) { _, theme in
            NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        }
        .onDisappear { session.shutdown() }
    }

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

                overlay
            }
        }
        // 窗口边距由 body 给,这里只让网格退出卡片的圆角:内缩超过
        // r(1 - 1/√2) 后任何单元格都不会被圆角切到,所以不必对
        // TerminalGridView 做 layer 裁剪。GeometryReader 拿到的是内缩后
        // 的尺寸,session.resize 因此仍收到正确的网格大小。
        .padding(ChromeMetrics.gridInset)
    }

    /// What is drawn over the grid while there is nothing to draw in it.
    @ViewBuilder private var overlay: some View {
        switch session.state {
        case .idle, .starting:
            card {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(startingDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(session.theme.chrome.subtext0.color)
                }
            }
        case .failed(let reason):
            errorCard("herdr could not start", reason: reason)
        case .disconnected(let reason):
            errorCard("herdr disconnected", reason: reason)
        case .running:
            EmptyView()
        }
    }

    private func errorCard(_ title: String, reason: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.theme.chrome.red.color)
                // The prototype does not recover on its own, so say what does.
                Text("Quit and open the app again to retry.")
                    .font(.system(size: 11))
                    .foregroundStyle(session.theme.chrome.subtext0.color)
                ScrollView {
                    Text(reason)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(session.theme.chrome.overlay1.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 256)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    /// 覆盖在终端上的提示卡片。走同一个 `CardSurface`,所以圆角、阴影、描边
    /// 与终端卡片同一套 —— 之前它自带一份 10pt 圆角和硬编码阴影,和窗口其余
    /// 部分不是一个体系。`over` 是 `panelBackground`:它浮在终端卡片上,不是
    /// 浮在窗口底上,描边要相对终端卡片派生。
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            // 24 / 16 / 32 都在 8pt 网格上(原来是 22 / 18 / 32)。
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .cardSurface(
                fill: session.theme.chrome.sidebarBackground,
                over: session.theme.chrome.panelBackground,
                theme: session.theme
            )
            .padding(32)
    }

    private var startingDetail: String {
        if case .starting(let detail) = session.state { return detail }
        return "starting herdr"
    }
}

private struct GridViewRepresentable: NSViewRepresentable {
    let view: TerminalGridView

    func makeNSView(context: Context) -> TerminalGridView { view }
    func updateNSView(_ nsView: TerminalGridView, context: Context) {}
}
