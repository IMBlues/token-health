import Foundation
import Testing
@testable import TokenHealth

struct MenuBarItemLayoutTests {
    @Test
    func placesBarsLeftToRightAfterTheIcon() {
        let metrics = [
            MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5),
            MenuBarMetric(label: "Week", shape: .ratio(0.25), severity: 0.25)
        ]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)

        #expect(layout.iconRect?.width == MenuBarItemLayout.iconSize)
        #expect(layout.tracks.count == 2)
        #expect(layout.tracks[1].minX - layout.tracks[0].maxX == MenuBarItemLayout.barGap)
        #expect(layout.tracks.allSatisfy { $0.height == MenuBarItemLayout.maxBarHeight })
    }

    @Test
    func dropsTheIconGapWhenThereIsNoIcon() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)
        let withIcon = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)

        #expect(layout.iconRect == nil)
        #expect(layout.tracks[0].minX == 0)
        #expect(withIcon.size.width - layout.size.width == MenuBarItemLayout.iconSize + MenuBarItemLayout.iconGap)
    }

    @Test
    func fillsScaleWithTheRatio() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)

        #expect(layout.fills[0].height == MenuBarItemLayout.maxBarHeight * 0.5)
        #expect(layout.fills[0].minY == layout.tracks[0].minY)
    }

    @Test
    func keepsATinyFillVisible() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.02), severity: 0.02)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)

        #expect(layout.fills[0].height == MenuBarItemLayout.minimumVisibleHeight)
    }

    @Test
    func drawsNoFillAtZero() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0), severity: 0)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)

        #expect(layout.fills[0].height == 0)
        #expect(layout.tracks.count == 1)
    }

    @Test
    func anEmptyMetricListStillReservesOneTrack() {
        let layout = MenuBarItemLayout.make(metrics: [], hasIcon: true, amountWidth: 0)

        #expect(layout.tracks.count == 1)
        #expect(layout.fills[0].height == 0)
        #expect(layout.size.width > MenuBarItemLayout.iconSize)
    }

    @Test
    func amountContentReplacesTheBarsWithText() {
        let metrics = [MenuBarMetric(label: "CNY", shape: .amount("24.00"), severity: nil)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 30)

        #expect(layout.tracks.isEmpty)
        #expect(layout.fills.isEmpty)
        #expect(layout.amountRect?.width == 30)
        #expect(layout.amountRect?.height == MenuBarItemLayout.maxBarHeight)
        #expect(layout.size.width == MenuBarItemLayout.iconSize + MenuBarItemLayout.iconGap + 30)
    }

    @Test
    func heightCoversTheTallestBarPlusPadding() {
        let layout = MenuBarItemLayout.make(metrics: [], hasIcon: false, amountWidth: 0)
        #expect(layout.size.height == MenuBarItemLayout.maxBarHeight + 2 * MenuBarItemLayout.verticalPadding)
    }
}
