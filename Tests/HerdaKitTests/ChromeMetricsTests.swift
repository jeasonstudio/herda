import AppKit
import XCTest
@testable import HerdaKit

final class ChromeMetricsTests: XCTestCase {
    /// `cardTopInset` 不是审美选择。窗口是 `.hiddenTitleBar`,红绿灯浮在
    /// 内容顶部,且那条 titlebar 带仍然持有窗口拖动手势 —— 卡片顶边落进
    /// 带内,终端顶部几行的点击就会变成拖窗口。
    ///
    /// 断言的是净空关系而不是「等于 28」:后者只是把硬编码换个地方,
    /// 系统改了按钮位置照样错。
    func testCardTopInsetClearsTheTrafficLights() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let content = try XCTUnwrap(window.contentView)
        let close = try XCTUnwrap(
            window.standardWindowButton(.closeButton),
            "a .titled window should have a close button"
        )

        // AppKit 的 y 轴向上,`.fullSizeContentView` 让 contentView 铺满
        // 窗口,所以按钮底边到内容顶边的距离是 height - minY。
        let inContent = close.convert(close.bounds, to: content)
        let clearanceNeeded = content.bounds.height - inContent.minY

        XCTAssertGreaterThanOrEqual(
            ChromeMetrics.cardTopInset,
            clearanceNeeded,
            "卡片顶边会压在红绿灯上,或落进仍持有拖动手势的 titlebar 带内"
        )
    }

    /// 红绿灯只是视觉;真正会坏功能的是拖动手势。那条 titlebar 带持有它,
    /// 卡片顶边必须落在带的下沿之外,否则带内的终端行点击会被解释成拖窗口。
    ///
    /// `contentLayoutRect` 是排除 titlebar 后的内容区,它与 contentView
    /// 的高度差就是带占用的高度 —— 比用 GUI 点击去试可靠得多。
    func testCardTopInsetClearsTheTitlebarDragStrip() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let content = try XCTUnwrap(window.contentView)
        let stripHeight = content.bounds.height - window.contentLayoutRect.height

        XCTAssertGreaterThanOrEqual(
            ChromeMetrics.cardTopInset,
            stripHeight,
            "卡片顶边落进 titlebar 的拖动带,带内的终端行点击会变成拖窗口"
        )
    }

    /// 网格不贴到圆角是「不必对 TerminalGridView 做 layer 裁剪」的前提:
    /// 圆角矩形的内接矩形在 r(1 - 1/√2) 处才脱离圆角。
    func testGridInsetClearsTheCardCorner() {
        // 显式标注 CGFloat:XCTAssertGreaterThan 是泛型,CGFloat 与 Double
        // 的隐式转换在泛型上下文里不生效,不标注会编译失败。
        let clearance: CGFloat = ChromeMetrics.cardRadius * (1 - 1 / 2.0.squareRoot())
        XCTAssertGreaterThan(ChromeMetrics.gridInset, clearance)
    }
}
