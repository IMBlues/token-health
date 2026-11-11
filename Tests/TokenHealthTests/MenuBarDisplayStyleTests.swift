import AppKit
import CoreText
import Foundation
import Testing
@testable import TokenHealth

private struct DisplayStyleRateFetcher: ExchangeRateFetching {
    func fetchTable() async throws -> ExchangeRateTable { throw URLError(.notConnectedToInternet) }
}

@MainActor
struct MenuBarDisplayStyleTests {
    private func makeState(store: ConfigStore) -> AppState {
        AppState(configStore: store, rateStore: ExchangeRateStore(configStore: store, fetcher: DisplayStyleRateFetcher()))
    }

    @Test
    func quotaModeDefaultsToUsedForMissingOrUnknownPreferences() {
        let defaults = UserDefaults(suiteName: "quota-mode-tests-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        #expect(store.loadMenuBarQuotaMode() == .used)

        defaults.set("future-mode", forKey: "menu-bar.quota-mode.v1")
        #expect(store.loadMenuBarQuotaMode() == .used)
    }

    @Test
    func quotaModeSavesImmediatelyAndSurvivesStyleChangesAndRelaunch() {
        let defaults = UserDefaults(suiteName: "quota-mode-tests-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        let state = makeState(store: store)
        state.menuBarDisplayStyle = .percentage
        state.menuBarQuotaMode = .remaining

        #expect(makeState(store: store).menuBarQuotaMode == .remaining)
        state.menuBarDisplayStyle = .bars
        let relaunched = makeState(store: store)
        #expect(relaunched.menuBarDisplayStyle == .bars)
        #expect(relaunched.menuBarQuotaMode == .remaining)

        state.menuBarQuotaMode = .used
        #expect(store.loadMenuBarQuotaMode() == .used)
    }

    @Test
    func anAbsentOrUnknownPreferenceKeepsTheExistingBars() {
        let defaults = UserDefaults(suiteName: "display-style-tests-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        #expect(store.loadMenuBarDisplayStyle() == .bars)

        defaults.set("future-style", forKey: "menu-bar.display-style.v1")
        #expect(store.loadMenuBarDisplayStyle() == .bars)
    }

    @Test
    func aStyleChangeIsImmediatelySavedAndLoadedOnRelaunch() {
        let defaults = UserDefaults(suiteName: "display-style-tests-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        let state = makeState(store: store)
        #expect(state.menuBarDisplayStyle == .bars)

        state.menuBarDisplayStyle = .percentage

        #expect(store.loadMenuBarDisplayStyle() == .percentage)
        #expect(makeState(store: store).menuBarDisplayStyle == .percentage)

        state.menuBarDisplayStyle = .bars
        #expect(store.loadMenuBarDisplayStyle() == .bars)
    }

    @Test
    func percentageModeUsesEveryQuotaWindowInOrder() {
        let metrics = [
            MenuBarMetric(label: "5h", shape: .ratio(0.125), severity: 0.125),
            MenuBarMetric(label: "Week", shape: .ratio(1), severity: 1)
        ]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0, displayStyle: .percentage)

        #expect(layout.tracks.isEmpty)
        #expect(layout.fills.isEmpty)
        #expect(layout.percentageRects.count == 2)
        #expect(layout.percentageRects[0].minX > layout.iconRect!.maxX)
        #expect(layout.percentageRects[0].minX == layout.percentageRects[1].minX)
        #expect(layout.percentageRects[0].minY >= layout.percentageRects[1].maxY)
        #expect(metrics.map(MenuBarMetrics.percentageText) == ["13%", "100%"])
    }

    @Test
    func percentageWidthsStayFixedAsUsageChanges() {
        let zero = [MenuBarMetric(label: "5h", shape: .ratio(0), severity: 0)]
        let full = [MenuBarMetric(label: "5h", shape: .ratio(1), severity: 1)]
        let zeroLayout = MenuBarItemLayout.make(metrics: zero, hasIcon: true, amountWidth: 0, displayStyle: .percentage)
        let fullLayout = MenuBarItemLayout.make(metrics: full, hasIcon: true, amountWidth: 0, displayStyle: .percentage)

        #expect(zeroLayout == fullLayout)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "100%", attributes: [.font: MenuBarItemRenderer.percentageFont]))
        let inkBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        #expect(inkBounds.width <= fullLayout.percentageRects[0].width)
        #expect(inkBounds.height <= fullLayout.percentageRects[0].height)
    }

    @Test
    func percentageColumnsDoNotReserveOversizedBlankSpace() {
        let metrics = [
            MenuBarMetric(label: "5h", shape: .ratio(0.01), severity: 0.01),
            MenuBarMetric(label: "Week", shape: .ratio(0.18), severity: 0.18)
        ]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0, displayStyle: .percentage)

        #expect(layout.statusItemLength <= 36, "stacked percentages must be close to the bars' footprint")
        #expect(layout.percentageRects[0].minX - layout.iconRect!.maxX <= 1)
        #expect(layout.percentageRects[0].minX == layout.percentageRects[1].minX)
    }

    @Test(arguments: [1, 2, 3])
    func upToThreePercentagesStayWithinOneCompactColumn(count: Int) {
        let metrics = (0..<count).map { _ in MenuBarMetric(label: "", shape: .ratio(1), severity: 1) }
        let percentage = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0, displayStyle: .percentage)
        let bars = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)

        #expect(percentage.percentageRects.count == count)
        #expect(percentage.statusItemLength <= 36)
        #expect(percentage.statusItemLength <= bars.statusItemLength + 12)
        #expect(percentage.size.height <= 22, "the bitmap must fit a standard menu bar")
        #expect(Set(percentage.percentageRects.map(\.minX)).count == 1)
        #expect(MenuBarItemRenderer.percentageFont.pointSize >= 8, "do not trade away legibility for width")
    }

    @Test
    func additionalMetricsWrapWithoutDroppingOrOverlappingValues() {
        let metrics = (0..<4).map { _ in MenuBarMetric(label: "", shape: .ratio(1), severity: 1) }
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0, displayStyle: .percentage)

        #expect(layout.percentageRects.count == 4)
        #expect(layout.percentageRects[0].minX == layout.percentageRects[2].minX)
        #expect(layout.percentageRects[0].minY >= layout.percentageRects[1].maxY)
        #expect(layout.percentageRects[1].minY >= layout.percentageRects[2].maxY)
        #expect(layout.percentageRects[3].minX > layout.percentageRects[0].maxX)
        #expect(layout.percentageRects[3].minY == layout.percentageRects[0].minY)
        #expect(layout.size.height <= 22)
    }

    @Test
    func tighterStatusItemMarginsApplyOnlyToPercentages() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.18), severity: 0.18)]
        let percentage = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0, displayStyle: .percentage)
        let bars = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)
        let amount = MenuBarItemLayout.make(
            metrics: [MenuBarMetric(label: "CNY", shape: .amount("24.00"), severity: nil)],
            hasIcon: true, amountWidth: 30, displayStyle: .percentage
        )

        #expect(percentage.statusItemLength - percentage.size.width == 2)
        #expect(bars.statusItemLength - bars.size.width == 6)
        #expect(amount.statusItemLength - amount.size.width == 6)
    }

    @Test
    func anUnknownQuotaIsNotMisrepresentedAsZeroPercent() {
        #expect(MenuBarMetrics.percentageText(MenuBarMetrics.placeholder) == "--")
        #expect(MenuBarMetrics.percentageText(MenuBarMetric(label: "5h", shape: .ratio(0), severity: 0)) == "0%")
        #expect(MenuBarMetrics.percentageText(MenuBarMetric(label: "5h", shape: .ratio(-1), severity: 0)) == "0%")
        #expect(MenuBarMetrics.percentageText(MenuBarMetric(label: "5h", shape: .ratio(2), severity: 1)) == "100%")
        #expect(MenuBarMetrics.percentageText(MenuBarMetric(label: "5h", shape: .ratio(.nan), severity: nil)) == "--")
        let layout = MenuBarItemLayout.make(metrics: [], hasIcon: true, amountWidth: 0, displayStyle: .percentage)
        #expect(layout.percentageRects.count == 1)
        #expect(layout.tracks.isEmpty)
    }

    @Test
    func monetaryValuesDoNotTurnIntoPercentages() {
        let metrics = [MenuBarMetric(label: "CNY", shape: .amount("24.00"), severity: nil)]
        let bars = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 30)
        let percentage = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 30, displayStyle: .percentage)

        #expect(percentage == bars)
        #expect(percentage.percentageRects.isEmpty)
        #expect(percentage.amountRect?.width == 30)
    }

    @Test
    func percentagesActuallyRenderWithoutRelyingOnTheLogoForPixels() {
        let metrics = [
            MenuBarMetric(label: "5h", shape: .ratio(0), severity: 0),
            MenuBarMetric(label: "Week", shape: .ratio(1), severity: 1)
        ]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0, displayStyle: .percentage)
        let image = MenuBarItemRenderer.image(layout: layout, kind: .codex, metrics: metrics, iconColor: .black, scale: 2)

        #expect(opaquePixelCount(image) > 0)
        #expect(image.size == layout.size)
        #expect(!image.isTemplate)
    }

    @Test
    func changingStyleInvalidatesAnOtherwiseIdenticalPresentation() {
        let bars = StatusItemPresentation(
            providerKind: .codex,
            metrics: [MenuBarMetrics.placeholder],
            logoIsWhite: false,
            scale: 2,
            tooltip: "Codex",
            interaction: .detailPopover
        )
        var percentage = bars
        percentage.displayStyle = .percentage

        #expect(bars != percentage)
    }
}
