import Foundation
import Testing
@testable import TokenHealth

struct MenuBarMetricsTests {
    private let rateTable = ExchangeRateTable(
        base: "USD",
        rates: ["CNY": 7],
        fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
        origin: .live
    )

    private func snapshot(
        kind: ProviderKind,
        usages: [TokenUsage],
        state: ProviderUsageSnapshot.State = .ready
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: UUID(),
            serviceName: "Test",
            providerTitle: kind.title,
            usages: usages,
            state: state,
            statusMessage: "ok",
            updatedAt: Date()
        )
    }

    @Test
    func buildsOneRatioMetricPerQuotaWindow() {
        let snap = snapshot(kind: .zhipuCode, usages: [
            TokenUsage(window: .fiveHours, used: 50, limit: 100),
            TokenUsage(window: .week, used: 10, limit: 100),
            TokenUsage(window: .mcpMonth, used: 0, limit: 100)
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .zhipuCode, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.count == 3)
        #expect(metrics.map(\.label) == ["5h", "Week", "MCP"])
        #expect(metrics[0].shape == .ratio(0.5))
        #expect(metrics[1].shape == .ratio(0.1))
        #expect(metrics[0].severity == 0.5)
    }

    @Test
    func remainingModeInvertsValuesButKeepsConsumedQuotaSeverity() {
        let cases: [(used: Int, remaining: Double, severity: Double)] = [
            (0, 1, 0), (25, 0.75, 0.25), (50, 0.5, 0.5), (75, 0.25, 0.75), (100, 0, 1), (300, 0, 1), (-10, 1, 0)
        ]
        for item in cases {
            let snap = snapshot(kind: .kimiCode, usages: [TokenUsage(window: .fiveHours, used: item.used, limit: 100)])
            let metrics = MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable, quotaMode: .remaining)

            #expect(metrics.first?.shape == .ratio(item.remaining))
            #expect(metrics.first?.severity == item.severity, "low remaining quota must stay dangerous, not green")
        }
    }

    @Test
    func theSelectedModeDrivesBothBarsAndPercentagesWithoutMutatingUsage() {
        let snap = snapshot(kind: .kimiCode, usages: [TokenUsage(window: .fiveHours, used: 25, limit: 100)])
        let used = MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable, quotaMode: .used)
        let remaining = MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable, quotaMode: .remaining)

        let usedBars = MenuBarItemLayout.make(metrics: used, hasIcon: true, amountWidth: 0)
        let remainingBars = MenuBarItemLayout.make(metrics: remaining, hasIcon: true, amountWidth: 0)
        #expect(usedBars.fills[0].height == 3.25)
        #expect(remainingBars.fills[0].height == 9.75)
        #expect(MenuBarMetrics.percentageText(used[0]) == "25%")
        #expect(MenuBarMetrics.percentageText(remaining[0]) == "75%")
        #expect(MenuBarItemLayout.make(metrics: used, hasIcon: true, amountWidth: 0, displayStyle: .percentage)
            == MenuBarItemLayout.make(metrics: remaining, hasIcon: true, amountWidth: 0, displayStyle: .percentage))
        #expect(snap.usages[0].used == 25)
        #expect(used[0].severity == remaining[0].severity)
    }

    @Test
    func remainingModeDoesNotInventQuotaForMissingOrUnavailableData() {
        #expect(MenuBarMetrics.metrics(for: nil, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable, quotaMode: .remaining).isEmpty)
        let unavailable = snapshot(kind: .kimiCode, usages: [TokenUsage(window: .fiveHours, used: 0, limit: 100)], state: .unavailable)
        #expect(MenuBarMetrics.metrics(for: unavailable, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable, quotaMode: .remaining).isEmpty)
        let unknownLimit = snapshot(kind: .kimiCode, usages: [TokenUsage(window: .fiveHours, used: 0, limit: nil)])
        #expect(MenuBarMetrics.metrics(for: unknownLimit, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable, quotaMode: .remaining).isEmpty)
        #expect(MenuBarMetrics.percentageText(MenuBarMetrics.placeholder) == "--")
    }

    @Test
    func remainingModeLeavesMoneyUnchanged() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", amount: Decimal(string: "24.00"))
        ])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: nil, rateTable: rateTable, quotaMode: .remaining)

        #expect(metrics.first?.shape == .amount("24.00"))
        #expect(MenuBarMetrics.tooltipText(serviceName: "DeepSeek", metrics: metrics, quotaMode: .remaining) == "DeepSeek · Balance CNY 24.00")
    }

    @Test
    func theTooltipMakesTheModeClearEvenWhenBothValuesAreFiftyPercent() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5)]
        #expect(MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: metrics, quotaMode: .used) == "Kimi · 5h 50% used")
        #expect(MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: metrics, quotaMode: .remaining) == "Kimi · 5h 50% remaining")
    }

    @Test
    func clampsRatiosAboveOne() {
        let snap = snapshot(kind: .kimiCode, usages: [TokenUsage(window: .fiveHours, used: 300, limit: 100)])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.first?.shape == .ratio(1))
    }

    @Test
    func usesTheShortWindowLabelWhenTheUsageHasNone() {
        let snap = snapshot(kind: .openCodeGo, usages: [
            TokenUsage(window: .month, used: 1, limit: 10),
            TokenUsage(window: .videoGift, used: 1, limit: 10)
        ])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .openCodeGo, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.map(\.label) == ["Month", "Video"])
    }

    @Test
    func prefersTheUsageOwnLabel() {
        let snap = snapshot(kind: .cursor, usages: [
            TokenUsage(window: .month, label: "Auto + Composer", used: 1, limit: 10)
        ])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .cursor, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.map(\.label) == ["Auto + Composer"])
    }

    @Test
    func returnsNothingWhenTheSnapshotIsNotReady() {
        let snap = snapshot(kind: .kimiCode, usages: [], state: .unavailable)
        #expect(MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable).isEmpty)
    }

    @Test
    func returnsNothingWithoutASnapshot() {
        #expect(MenuBarMetrics.metrics(for: nil, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable).isEmpty)
    }

    @Test
    func deepSeekWithoutATargetCurrencyShowsTheLeadingBalance() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "12.50 CNY", amount: Decimal(string: "12.50")),
            TokenUsage(window: .balance, label: "Balance USD", used: 0, limit: nil, unit: "USD", displayValue: "3.00 USD", amount: Decimal(string: "3.00"))
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.count == 1)
        #expect(metrics[0].shape == .amount("12.50"))
        #expect(metrics[0].severity == nil)
    }

    @Test
    func deepSeekConvertsAndSumsEveryWalletIntoTheTargetCurrency() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "10.00 CNY", amount: Decimal(string: "10.00")),
            TokenUsage(window: .balance, label: "Balance USD", used: 0, limit: nil, unit: "USD", displayValue: "2.00 USD", amount: Decimal(string: "2.00"))
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: "CNY", rateTable: rateTable)

        #expect(metrics.count == 1)
        #expect(metrics[0].shape == .amount("24.00"))
        #expect(metrics[0].label == "CNY")
    }

    @Test
    func deepSeekFallsBackToTheOriginalAmountWhenTheRateIsMissing() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "10.00 CNY", amount: Decimal(string: "10.00")),
            TokenUsage(window: .balance, label: "Balance USD", used: 0, limit: nil, unit: "USD", displayValue: "2.00 USD", amount: Decimal(string: "2.00"))
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: "EUR", rateTable: rateTable)

        #expect(metrics.count == 1)
        #expect(metrics[0].shape == .amount("10.00"))
        #expect(metrics[0].label.contains("rate unavailable"))
    }

    @Test
    func deepSeekWithNoBalanceProducesNothing() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .todayTokens, label: "Today tokens total", used: 5, limit: nil, unit: "tokens")
        ])
        #expect(MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: "CNY", rateTable: rateTable).isEmpty)
    }

    @Test
    func tooltipTextListsEveryMetric() {
        let snap = snapshot(kind: .kimiCode, usages: [
            TokenUsage(window: .fiveHours, used: 62, limit: 100),
            TokenUsage(window: .week, used: 34, limit: 100)
        ])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable)

        #expect(MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: metrics) == "Kimi · 5h 62% used · Week 34% used")
    }

    @Test
    func tooltipTextFallsBackToTheStatusMessage() {
        #expect(
            MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: [], statusMessage: "Waiting for refresh")
                == "Kimi · Waiting for refresh"
        )
    }

    @Test
    func theGoogleAIMenuBarItemStaysAtThreeBars() {
        // 钉住的项就一根条子一个额度，五六根并排时长度和颜色都读不出谁是谁 —— 菜单栏只留每组的
        // 5 小时额度，外加 Argon（有的话）。周额度在卡片和详情浮层里。
        let snap = snapshot(kind: .googleAI, usages: [
            TokenUsage(window: .week, label: "Gemini Week", used: 60, limit: 100, unit: "%"),
            TokenUsage(window: .fiveHours, label: "Gemini 5h", used: 2, limit: 100, unit: "%"),
            TokenUsage(window: .week, label: "Claude & GPT Week", used: 0, limit: 100, unit: "%"),
            TokenUsage(window: .fiveHours, label: "Claude & GPT 5h", used: 0, limit: 100, unit: "%"),
            TokenUsage(window: .week, label: "Gemini 4 Argon Week", used: 61, limit: 100, unit: "%")
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .googleAI, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.map(\.label) == ["Gemini 5h", "Claude & GPT 5h", "Gemini 4 Argon Week"])
        #expect(metrics.allSatisfy { if case .ratio = $0.shape { true } else { false } })
    }

    @Test
    func theGoogleAITooltipNamesWhateverTheBarsShow() {
        let snap = snapshot(kind: .googleAI, usages: [
            TokenUsage(window: .fiveHours, label: "Gemini 5h", used: 2, limit: 100, unit: "%")
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .googleAI, displayCurrency: nil, rateTable: rateTable)

        #expect(MenuBarMetrics.tooltipText(serviceName: "Google AI", metrics: metrics) == "Google AI · Gemini 5h 2% used")
    }
}
