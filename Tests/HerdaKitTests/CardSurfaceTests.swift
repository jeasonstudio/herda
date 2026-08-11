import AppKit
import SwiftUI
import XCTest
@testable import HerdaKit

/// `CardSurface` 画出来的卡片是否真的能从窗口底上分辨出来。
///
/// 与 `ChromeSurfacesTests` 里那组明度断言互补而不重复:那组比较的是
/// `windowBackground` / `panelBackground` / `hairline` 三个**颜色值**,看不见
/// 阴影,也看不见描边最终被画成什么样。这里走真实的 `CardSurface` 绘制,
/// 两者都算进去。
@MainActor
final class CardSurfaceTests: XCTestCase {
    /// 用 `ImageRenderer` 而不是 `NSHostingView.cacheDisplay`:后者对
    /// `NSHostingView` 取不到 SwiftUI 的绘制,整张图是空的(实测)。
    private func render(_ view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func luminance(_ color: NSColor?) throws -> Int {
        let c = try XCTUnwrap(color?.usingColorSpace(.deviceRGB))
        let v = (c.redComponent * 299 + c.greenComponent * 587 + c.blueComponent * 114) / 1000
        return Int((v * 255).rounded())
    }

    /// 每个主题都必须能把终端卡片从窗口底上分出来 —— 靠面的色差,或者靠
    /// 描边。`terminal` 主题两个面都是纯黑,只有描边这一条路。
    func testEveryThemeRendersTheCardDistinctFromTheWindow() throws {
        for theme in ThemeCatalog.all {
            // 画布 160,卡片 60 居中 → 卡片占 50...110,边距 50。阴影 radius
            // 14 最远扩散到 x≈36,所以 x=5 是不含阴影的纯底色。
            let view = ZStack {
                theme.chrome.windowBackground.color
                Color.clear
                    .frame(width: 60, height: 60)
                    .cardSurface(fill: theme.chrome.panelBackground, theme: theme)
            }
            .frame(width: 160, height: 160)

            let rep = try render(view)
            // y=80 是垂直中点,那里卡片边缘是直的,描边不被圆角的抗锯齿干扰。
            let window = try luminance(rep.colorAt(x: 5, y: 80))
            let border = try luminance(rep.colorAt(x: 50, y: 80))
            let face = try luminance(rep.colorAt(x: 80, y: 80))

            let byFace = abs(face - window) >= 3
            let byBorder = abs(border - window) >= 3
            XCTAssertTrue(
                byFace || byBorder,
                "\(theme.configName): 卡片与窗口底既无面色差(\(abs(face - window)))"
                    + " 也无描边差(\(abs(border - window)))"
            )
        }
    }

    /// `terminal` 主题下面色差恰好为零,分离完全落在描边上。把它单独钉住:
    /// 这是「描边不可省」在真实绘制里的证据,不只是 token 计算的推论。
    func testTerminalThemeCardIsHeldUpByTheBorderAlone() throws {
        let theme = ThemeCatalog.terminal
        let view = ZStack {
            theme.chrome.windowBackground.color
            Color.clear
                .frame(width: 60, height: 60)
                .cardSurface(fill: theme.chrome.panelBackground, theme: theme)
        }
        .frame(width: 160, height: 160)

        let rep = try render(view)
        let window = try luminance(rep.colorAt(x: 5, y: 80))
        let border = try luminance(rep.colorAt(x: 50, y: 80))
        let face = try luminance(rep.colorAt(x: 80, y: 80))

        XCTAssertEqual(face, window, "terminal 的两个面本该同色")
        XCTAssertGreaterThanOrEqual(abs(border - window), 3, "描边没把卡片勾出来")
    }
}
