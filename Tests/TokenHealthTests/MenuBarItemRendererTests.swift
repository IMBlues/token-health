import AppKit
import Foundation
import Testing
@testable import TokenHealth

/// 渲染层只做冒烟验证：确认绘制路径在无窗口的测试进程里能跑通并真的落了像素。
/// 几何与选指标的可验证部分都在 MenuBarItemLayout 与 MenuBarMetrics 里。
@MainActor
struct MenuBarItemRendererTests {
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

    /// 数出至少部分不透明的像素。用来区分「画了东西」和「交了张空白图」。
    private func opaquePixelCount(_ image: NSImage) -> Int {
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let data = rep.bitmapData else {
            return 0
        }
        let samples = rep.samplesPerPixel
        let alphaIndex = samples - 1
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where data[y * rep.bytesPerRow + x * samples + alphaIndex] > 0 {
                count += 1
            }
        }
        return count
    }
}
