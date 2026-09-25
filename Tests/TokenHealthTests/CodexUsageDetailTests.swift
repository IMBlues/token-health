import Foundation
import Testing
@testable import TokenHealth

@Suite
struct CodexUsageDetailTests {
    /// 2026-09-25T00:00:00Z —— 30 天窗口是 8/27 … 9/25。
    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    /// 与 `CodexRateLimitsMapper` 产出的形状一致：账号级窗口 label 为 nil、unit 是 `%`。
    private func quotaUsages() -> [TokenUsage] {
        [
            TokenUsage(window: .fiveHours, used: 12, limit: 100, resetDate: nil, unit: "%"),
            TokenUsage(window: .week, used: 58, limit: 100, resetDate: nil, unit: "%")
        ]
    }

    private func usageResponse(_ json: String) throws -> CodexAccountUsageResponse {
        try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data(json.utf8))
    }

    private var fullSummary: String {
        """
        "summary": {
          "lifetimeTokens": 172532345, "peakDailyTokens": 117865819,
          "longestRunningTurnSec": 2550, "currentStreakDays": 3, "longestStreakDays": 3
        }
        """
    }

    @Test
    func headlineMirrorsThePinnedMenuBarMetrics() throws {
        let detail = try #require(CodexUsageDetail.make(
            usage: nil,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.headline.map(\.label) == ["5h", "Week"])
        #expect(detail.headline.map(\.value) == ["12%", "58%"])
        // 用量响应缺席时不该凭空造出别的区块。
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.table == nil)
    }

    @Test
    func headlineSkipsModelBucketsAndDuplicateLabels() throws {
        let usages = quotaUsages() + [
            // 模型桶（label 带 " · "）不算账号级指标，不进 headline。
            TokenUsage(window: .fiveHours, label: "gpt-5 · 5h", used: 3, limit: 100, unit: "%"),
            // 两个窗口折出同一个 label（`CodexRateLimitsMapper.durationLabel(60)` 就是 "1h"）。
            // `pinnedMetrics` 先按窗口 rank、同 rank 再按 label 字典序，所以两条 "1h" 各自排在
            // 同 rank 的第一位：最终顺序是 ["1h"(40%), "5h", "1h"(70%), "Week"]。
            // `DetailStat.id == label` 要求集合内唯一，去重只留第一条（.fiveHours 那条）。
            TokenUsage(window: .fiveHours, label: "1h", used: 40, limit: 100, unit: "%"),
            TokenUsage(window: .week, label: "1h", used: 70, limit: 100, unit: "%")
        ]

        let detail = try #require(CodexUsageDetail.make(usage: nil, usages: usages, today: today))

        #expect(detail.headline.map(\.label) == ["1h", "5h", "Week"])
        #expect(detail.headline.map(\.value) == ["40%", "12%", "58%"])
    }

    @Test
    func breakdownCoversTheAccountTotals() throws {
        let response = try usageResponse("{ \(fullSummary) }")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.breakdown.map(\.label) == ["Lifetime", "Peak day", "Streak", "Longest turn"])
        #expect(detail.breakdown.map(\.value) == ["172.53M", "117.87M", "3d", "42m"])
    }

    @Test
    func breakdownFormatsDurationsAndDropsBadNumbers() throws {
        // 时长四档：不足一分钟给秒，不足一小时给分钟（向下取整），整点小时不带分钟，
        // 其余带分钟。
        for (seconds, expected) in [(42, "42s"), (3599, "59m"), (3600, "1h"), (3900, "1h 5m")] {
            let response = try usageResponse("{ \"summary\": { \"longestRunningTurnSec\": \(seconds) } }")
            let detail = try #require(CodexUsageDetail.make(
                usage: response,
                usages: quotaUsages(),
                today: today
            ))
            #expect(detail.breakdown.map(\.label) == ["Longest turn"])
            #expect(detail.breakdown.map(\.value) == [expected])
        }

        // 负数是坏数据，不占位；0 天的连续记录是真的 0，照画。
        let bad = try usageResponse("""
        { "summary": { "peakDailyTokens": -5, "currentStreakDays": 0 } }
        """)
        let badDetail = try #require(CodexUsageDetail.make(
            usage: bad,
            usages: quotaUsages(),
            today: today
        ))

        #expect(badDetail.breakdown.map(\.label) == ["Streak"])
        #expect(badDetail.breakdown.map(\.value) == ["0d"])
    }

    @Test
    func everyBlockCanBeAbsent() throws {
        // 用量响应解得出、但一个统计字段都没有，也没有 buckets → 只剩 headline。
        let response = try usageResponse("{}")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.headline.count == 2)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.groups.isEmpty)

        // 额度与用量都填不出来 → nil（浮层退回错误行）。
        #expect(CodexUsageDetail.make(usage: nil, usages: [], today: today) == nil)
    }
}
