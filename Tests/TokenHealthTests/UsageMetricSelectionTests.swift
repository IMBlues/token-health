import Foundation
import Testing
@testable import TokenHealth

struct UsageMetricSelectionTests {
    @Test
    func ranksQuotaWindowsInDisplayOrder() {
        let fiveHours = TokenUsage(window: .fiveHours, used: 1, limit: 10)
        let week = TokenUsage(window: .week, used: 1, limit: 10)
        let month = TokenUsage(window: .month, used: 1, limit: 10)
        let mcp = TokenUsage(window: .mcpMonth, used: 1, limit: 10)
        let video = TokenUsage(window: .videoGift, used: 1, limit: 10)

        #expect(UsageMetricSelection.rank(fiveHours) < UsageMetricSelection.rank(week))
        #expect(UsageMetricSelection.rank(week) < UsageMetricSelection.rank(month))
        #expect(UsageMetricSelection.rank(month) < UsageMetricSelection.rank(mcp))
        #expect(UsageMetricSelection.rank(mcp) < UsageMetricSelection.rank(video))
    }

    @Test
    func treatsLabelledModelBucketsAsNotAccountLevel() {
        let account = TokenUsage(window: .fiveHours, used: 1, limit: 10)
        let bucket = TokenUsage(window: .fiveHours, label: "gpt-5 · 5h", used: 1, limit: 10)
        let cursorPool = TokenUsage(window: .month, label: "Auto + Composer", used: 1, limit: 10)

        #expect(UsageMetricSelection.isAccountLevel(account))
        #expect(!UsageMetricSelection.isAccountLevel(bucket))
        #expect(UsageMetricSelection.isAccountLevel(cursorPool))
    }

    @Test
    func classifiesQuotaWindows() {
        #expect(UsageMetricSelection.isQuotaWindow(TokenUsage(window: .fiveHours, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isQuotaWindow(TokenUsage(window: .week, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isQuotaWindow(TokenUsage(window: .month, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isQuotaWindow(TokenUsage(window: .mcpMonth, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isQuotaWindow(TokenUsage(window: .videoGift, used: 1, limit: 10)))
        // GenericHTTP 的总额度：卡片对它也画进度条，钉住项不能漏。
        #expect(UsageMetricSelection.isQuotaWindow(TokenUsage(window: .tokenQuota, used: 1, limit: 10)))

        #expect(!UsageMetricSelection.isQuotaWindow(TokenUsage(window: .balance, used: 0, limit: nil)))
        #expect(!UsageMetricSelection.isQuotaWindow(TokenUsage(window: .todayCost, used: 0, limit: nil)))
        #expect(!UsageMetricSelection.isQuotaWindow(TokenUsage(window: .todayTokens, used: 0, limit: nil)))
        #expect(!UsageMetricSelection.isQuotaWindow(TokenUsage(window: .todayRequests, used: 0, limit: nil)))
        #expect(!UsageMetricSelection.isQuotaWindow(TokenUsage(window: .sevenDaysTokens, label: "7d Token total", used: 5, limit: nil)))
        #expect(!UsageMetricSelection.isQuotaWindow(TokenUsage(window: .sevenDaysTools, used: 5, limit: nil)))
    }

    @Test
    func pinnedMetricsIncludeTheTotalTokenQuota() {
        // 同一个窗口不能在卡片上有比例、在菜单栏上却是空槽。
        // tokenQuota 的 rank 是 4，排在 5h 的 10 之前，沿用卡片既有顺序。
        let usages = [
            TokenUsage(window: .fiveHours, used: 10, limit: 100),
            TokenUsage(window: .tokenQuota, used: 40, limit: 100)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .genericHTTP)

        #expect(pinned.map(\.window) == [.tokenQuota, .fiveHours])
    }

    @Test
    func pinnedMetricsTakeEveryQuotaWindow() {
        let usages = [
            TokenUsage(window: .week, used: 10, limit: 100),
            TokenUsage(window: .fiveHours, used: 10, limit: 100),
            TokenUsage(window: .mcpMonth, used: 10, limit: 100),
            TokenUsage(window: .todayTokens, label: "Today tokens total", used: 10, limit: nil)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .zhipuCode)

        #expect(pinned.map(\.window) == [.fiveHours, .week, .mcpMonth])
    }

    @Test
    func pinnedMetricsDropCodexModelBuckets() {
        let usages = [
            TokenUsage(window: .fiveHours, used: 10, limit: 100),
            TokenUsage(window: .fiveHours, label: "gpt-5 · 5h", used: 10, limit: 100),
            TokenUsage(window: .week, used: 10, limit: 100)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .codex)

        #expect(pinned.count == 2)
        #expect(pinned.allSatisfy { UsageMetricSelection.isAccountLevel($0) })
    }

    @Test
    func pinnedMetricsOrderCursorPoolsByTheirLabel() {
        let usages = [
            TokenUsage(window: .month, label: "Grokbot", used: 10, limit: 100),
            TokenUsage(window: .month, label: "API", used: 10, limit: 100),
            TokenUsage(window: .month, label: "Auto + Composer", used: 10, limit: 100)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .cursor)

        #expect(pinned.map(\.label) == ["Auto + Composer", "API", "Grokbot"])
    }

    @Test
    func pinnedMetricsAreEmptyWhenNothingHasAQuota() {
        let usages = [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "12.34 CNY")
        ]
        #expect(UsageMetricSelection.pinnedMetrics(from: usages, kind: .deepSeek).isEmpty)
    }

    @Test
    func pinnedMetricsSkipQuotaWindowsWithoutALimit() {
        // GenericHTTP 一类的接口可能只给 used 不给 limit。卡片在这种情况下不画进度条，
        // 钉住项也必须一致，否则空槽会被读成「用了 0%」。
        let usages = [
            TokenUsage(window: .fiveHours, used: 10, limit: 100),
            TokenUsage(window: .week, used: 10, limit: nil),
            TokenUsage(window: .month, used: 10, limit: 0)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .genericHTTP)

        #expect(pinned.map(\.window) == [.fiveHours])
    }

    @Test
    func sortingIsStableForEqualRanks() {
        let usages = [
            TokenUsage(window: .week, used: 1, limit: 10),
            TokenUsage(window: .fiveHours, used: 1, limit: 10)
        ]
        #expect(UsageMetricSelection.sorted(usages, kind: .kimiCode).map(\.window) == [.fiveHours, .week])
    }
}
