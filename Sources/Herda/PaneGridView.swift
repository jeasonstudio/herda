import HerdaKit
import SwiftUI

/// 终端区:每个 pane 一张原生卡片,位置由 herdr 的 layout rect 决定。
///
/// 卡片之间的间距不是这里编出来的 —— herdr 在 `pane_gaps` 下让相邻 pane 各收缩
/// 一格,13pt 下正好 8pt。卡片各向外扩 `paneCardOutset` 吃掉一半,剩下的 4pt 就是
/// 间距;扩出来的那 2pt 同时给圆角当内缩,所以角上的字符不会被切(见
/// `ChromeMetrics.paneCardOutset`)。
struct PaneGridView: View {
    @ObservedObject var session: TerminalSession
    let theme: Theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if session.isWholeGridFallback {
                    // 有内容跨越了 pane 边界(prefix key 按出来的 modal),或者还没
                    // 拿到布局。整块画:按 rect 切会把它切碎,落在间隙上的部分直接
                    // 丢失。
                    //
                    // 用与 pane 卡片相同的 outset 与圆角,这样两种状态之间切换时
                    // 卡片形态不跳。代价是内容右下会被这层 padding 裁掉 2pt(不足
                    // 半个 cell):可接受 —— 这是 modal 弹出时的过渡态,而 modal
                    // 本身画在中央。
                    GridViewRepresentable(view: session.wholeGridView)
                        .padding(ChromeMetrics.paneCardOutset)
                        .cardSurface(
                            fill: theme.chrome.panelBackground,
                            over: theme.chrome.windowBackground,
                            theme: theme,
                            radius: ChromeMetrics.paneCardRadius
                        )
                } else {
                    ForEach(session.router.visiblePanes) { pane in
                        paneCard(pane)
                    }
                }
            }
            // 卡片各向外扩 outset,最左/最上那张会到 -outset。内缩同样的量,让它
            // 落回 0,卡片才不会溢出终端区。
            .padding(ChromeMetrics.paneCardOutset)
            .onAppear { session.start(viewportSize: gridArea(in: geometry.size)) }
            .onChange(of: geometry.size) { _, size in session.resize(to: gridArea(in: size)) }
        }
    }

    /// 声明给 server 的网格所对应的像素区域。
    ///
    /// 必须扣掉上面那层 padding:声明的 cols/rows 决定 pane rect 的总和,而卡片
    /// 要在这个区域内向外扩 outset。不扣的话最右和最下那张卡片会被窗口边缘切掉。
    private func gridArea(in available: CGSize) -> CGSize {
        let inset = ChromeMetrics.paneCardOutset * 2
        return CGSize(
            width: max(0, available.width - inset),
            height: max(0, available.height - inset)
        )
    }

    @ViewBuilder private func paneCard(_ pane: PaneLayoutPane) -> some View {
        let frame = LayoutGeometry.frame(for: pane.rect, cellSize: session.cellSize)
        let outset = ChromeMetrics.paneCardOutset

        Group {
            if let view = session.paneViews[pane.paneId] {
                GridViewRepresentable(view: view)
            } else {
                // 布局已到但这一帧还没分派过来的瞬间。用卡片底色填,而不是留一个
                // 透出窗口底的洞。
                theme.chrome.panelBackground.color
            }
        }
        // 内容必须精确等于 rect × cell:小了最后一列会被裁,大了会溢进间隙。
        .frame(width: frame.width, height: frame.height)
        // 非焦点 pane 的内容压淡,卡片本身(描边、阴影)不动 —— 让描边始终清晰,
        // 分隔靠它。opacity 放在 cardSurface 之前才只作用于内容。
        .opacity(pane.focused ? 1 : 0.72)
        .padding(outset)
        .cardSurface(
            fill: theme.chrome.panelBackground,
            over: theme.chrome.windowBackground,
            theme: theme,
            radius: ChromeMetrics.paneCardRadius
        )
        .offset(x: frame.minX - outset, y: frame.minY - outset)
        .onTapGesture {
            session.focusPane(pane.paneId)
            session.focusTerminal()
        }
    }
}

struct GridViewRepresentable: NSViewRepresentable {
    let view: TerminalGridView

    func makeNSView(context: Context) -> TerminalGridView { view }
    func updateNSView(_ nsView: TerminalGridView, context: Context) {}
}
