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

        #expect(MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: metrics) == "Kimi · 5h 62% · Week 34%")
    }

    @Test
    func tooltipTextFallsBackToTheStatusMessage() {
        #expect(
            MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: [], statusMessage: "Waiting for refresh")
                == "Kimi · Waiting for refresh"
        )
    }
}
