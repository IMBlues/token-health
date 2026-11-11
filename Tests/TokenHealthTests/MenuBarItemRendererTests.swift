import AppKit
import Foundation
import Testing
@testable import TokenHealth

/// 渲染层只做冒烟验证：确认绘制路径在无窗口的测试进程里能跑通并真的落了像素。
/// 几何与选指标的可验证部分都在 MenuBarItemLayout 与 MenuBarMetrics 里。
@MainActor
struct MenuBarItemRendererTests {
    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func stackedPercentagesHaveVisibleInkInEveryRow(scale: CGFloat) throws {
        let metrics = [
            MenuBarMetric(label: "5h", shape: .ratio(0), severity: 0),
            MenuBarMetric(label: "Week", shape: .ratio(0.5), severity: 0.5),
            MenuBarMetric(label: "Month", shape: .ratio(1), severity: 1)
        ]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0, displayStyle: .percentage)
        let image = MenuBarItemRenderer.image(layout: layout, kind: .codex, metrics: metrics, iconColor: .black, scale: scale)
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        let data = try #require(bitmap.bitmapData)
        #expect(image.size.width <= 23)
        #expect(layout.percentageRects.count == 3)

        for row in 0..<3 {
            let start = row * bitmap.pixelsHigh / 3
            let end = (row + 1) * bitmap.pixelsHigh / 3
            var inkPixels = 0
            for y in start..<end {
                for x in 0..<bitmap.pixelsWide {
                    let alpha = data[y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + 3]
                    if alpha > 32 { inkPixels += 1 }
                }
            }
            #expect(inkPixels > 10, "every stacked percentage must render, including 0% and 100%")
        }
    }

    @Test
    func anUnknownPercentageRemainsVisibleOnADarkMenuBar() {
        let metrics = [MenuBarMetrics.placeholder]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0, displayStyle: .percentage)
        let image = MenuBarItemRenderer.image(layout: layout, kind: .codex, metrics: metrics, iconColor: .white, scale: 2)

        #expect(brightPixelCount(image) > 0)
    }

    @Test
    func rendersTheIconAndTheBars() throws {
        let metrics = [
            MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5),
            MenuBarMetric(label: "Week", shape: .ratio(1), severity: 1)
        ]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)

        let image = MenuBarItemRenderer.image(
            layout: layout,
            kind: .kimiCode,
            metrics: metrics,
            iconColor: .black,
            scale: 2
        )

        #expect(image.size == layout.size)
        #expect(!image.isTemplate)
        #expect(opaquePixelCount(image) > 0, "nothing was drawn")
    }

    @Test
    func rendersAnEmptyTrackWhenThereAreNoMetrics() throws {
        let layout = MenuBarItemLayout.make(metrics: [], hasIcon: true, amountWidth: 0)

        let image = MenuBarItemRenderer.image(
            layout: layout,
            kind: .kimiCode,
            metrics: [],
            iconColor: .black,
            scale: 2
        )

        #expect(opaquePixelCount(image) > 0, "the placeholder track was not drawn")
    }

    @Test
    func rendersTheDeepSeekAmountAsText() throws {
        let metrics = [MenuBarMetric(label: "CNY", shape: .amount("24.00"), severity: nil)]
        let layout = MenuBarItemLayout.make(
            metrics: metrics,
            hasIcon: true,
            amountWidth: MenuBarItemRenderer.amountWidth(for: metrics)
        )

        let image = MenuBarItemRenderer.image(
            layout: layout,
            kind: .deepSeek,
            metrics: metrics,
            iconColor: .black,
            scale: 2
        )

        #expect(layout.amountRect?.width ?? 0 > 0, "the amount text measured as zero width")
        #expect(opaquePixelCount(image) > 0, "the amount text was not drawn")
    }

    @Test
    func fallsBackToASymbolWhenTheProviderHasNoLogo() throws {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)

        let image = MenuBarItemRenderer.image(
            layout: layout,
            kind: .genericHTTP,
            metrics: metrics,
            iconColor: .black,
            scale: 2
        )

        #expect(opaquePixelCount(image) > 0)
    }

    /// 葫芦是模板图，颜色由系统按菜单栏的外观来；账号 logo 想跟它一致，就只能按
    /// 同一处外观自己解析 —— 系统的深浅色和菜单栏的深浅色是两层，会不一致。
    @Test
    func logoColorFollowsTheMenuBarAppearance() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        #expect(PinnedStatusItemController.iconColor(for: light) == .black)
        #expect(PinnedStatusItemController.iconColor(for: dark) == .white)
    }
}
