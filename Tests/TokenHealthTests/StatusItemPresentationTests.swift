import AppKit
import Foundation
import Testing
@testable import TokenHealth

/// 一帧菜单栏项的比较值。只按几何判断是不够的：tooltip 与点击行为变了同样得重写，
/// 否则菜单栏上会留着过期的数字、过期的菜单。
@MainActor
struct StatusItemPresentationTests {
    private func presentation(
        ratio: Double = 0.5,
        kind: ProviderKind = .kimiCode,
        logoIsWhite: Bool = false,
        scale: CGFloat = 2,
        tooltip: String = "KimiCode · 5h 50%",
        interaction: StatusItemInteraction = .detailPopover
    ) -> StatusItemPresentation {
        StatusItemPresentation(
            providerKind: kind,
            metrics: [MenuBarMetric(label: "5h", shape: .ratio(ratio), severity: ratio)],
            logoIsWhite: logoIsWhite,
            scale: scale,
            tooltip: tooltip,
            interaction: interaction
        )
    }

    @Test
    func identicalPresentationsCompareEqual() {
        #expect(presentation() == presentation())
    }

    @Test
    func aMovedBarIsADifferentPresentation() {
        #expect(presentation(ratio: 0.5) != presentation(ratio: 0.6))
    }

    /// 账号换了 Provider：指标可能碰巧一样，但 logo 不一样，位图就得重画。
    @Test
    func aDifferentProviderLogoIsADifferentPresentation() {
        #expect(presentation(kind: .kimiCode) != presentation(kind: .deepSeek))
    }

    /// 换壁纸会改菜单栏的深浅色，logo 得跟着反色。
    @Test
    func aDifferentLogoColorIsADifferentPresentation() {
        #expect(presentation(logoIsWhite: false) != presentation(logoIsWhite: true))
    }

    /// 外接屏缩放不同，位图的实际像素宽也不同。
    @Test
    func aDifferentScaleIsADifferentPresentation() {
        #expect(presentation(scale: 2) != presentation(scale: 1))
    }

    /// 数字没动、只是状态文案变了（比如从「正在刷新」回到正常），tooltip 也要更新。
    @Test
    func aDifferentTooltipIsADifferentPresentation() {
        #expect(presentation(tooltip: "before") != presentation(tooltip: "after"))
    }

    /// 账号改名，或者账号从「有详情」改成「只有小菜单」，点击行为就变了。
    @Test
    func aDifferentInteractionIsADifferentPresentation() {
        #expect(presentation(interaction: .detailPopover) != presentation(interaction: .menu(displayName: "KimiCode")))
        #expect(presentation(interaction: .menu(displayName: "KimiCode")) != presentation(interaction: .menu(displayName: "KimiCode 2")))
    }

    /// `iconColor(for:)` 只给黑或白，重绘判据用的是这个布尔值，两者不能各说各话。
    @Test
    func logoColorMatchesTheResolvedIconColor() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        #expect(!PinnedStatusItemController.usesWhiteLogo(for: light))
        #expect(PinnedStatusItemController.usesWhiteLogo(for: dark))
        #expect(PinnedStatusItemController.iconColor(for: light) == .black)
        #expect(PinnedStatusItemController.iconColor(for: dark) == .white)
    }
}
