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
        #expect(detail.headline.map(\.ratio) == [0.12, 0.58], "额度行要带比例，浮层才画得出条")
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

    /// 稀疏 buckets：今天两条（求和）、7 天窗口边界 9/19 一条、窗口内更早的 9/18 一条、
    /// 窗口外的 8/26 一条。窗口是 8/27 … 9/25。
    private var sparseBuckets: String {
        """
        "dailyUsageBuckets": [
          { "startDate": "2026-08-26", "tokens": 7000000 },
          { "startDate": "2026-09-18", "tokens": 900000 },
          { "startDate": "2026-09-19", "tokens": 300000 },
          { "startDate": "2026-09-24", "tokens": 500000 },
          { "startDate": "2026-09-25", "tokens": 1200000 },
          { "startDate": "2026-09-25", "tokens": 800000 }
        ]
        """
    }

    @Test
    func groupsSumSparseBucketsIntoTodaySevenAndThirtyDays() throws {
        let response = try usageResponse("{ \(sparseBuckets) }")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.groups.map(\.title) == ["Today", "7 days", "30 days"])
        // 今天 1.2M + 0.8M；7 天含 9/19 起（300K + 500K + 2M）；30 天再加 9/18 的 900K。
        // 8/26 那 7M 落在窗口外，不进任何一行。
        #expect(detail.groups.map { $0.values.map(\.label) } == [["Tokens"], ["Tokens"], ["Tokens"]])
        #expect(detail.groups.map { $0.values[0].value } == ["2M", "2.8M", "3.7M"])
    }

    @Test
    func seriesCoversThirtyDaysWithGapsFilledByZero() throws {
        let response = try usageResponse("{ \(sparseBuckets) }")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        let series = try #require(detail.series)
        #expect(series.points.count == 30)
        #expect(series.title == "Tokens · last 30 days")
        #expect(series.emptyText == "No usage in the last 30 days")
        #expect(series.axisStart == "8/27")
        #expect(series.axisEnd == "9/25")
        // 没有 bucket 的日子补 0；窗口外的 8/26 不许漏进第一天。
        #expect(series.points.first?.value == 0)
        #expect(series.points.last?.value == 2_000_000)
        #expect(series.points.map(\.value).reduce(0, +) == 3_700_000)
    }

    @Test
    func emptyBucketsDrawZeroRowsButMissingBucketsDrawNothing() throws {
        let empty = try usageResponse("{ \(fullSummary), \"dailyUsageBuckets\": [] }")
        let emptyDetail = try #require(CodexUsageDetail.make(
            usage: empty,
            usages: quotaUsages(),
            today: today
        ))
        #expect(emptyDetail.groups.map { $0.values[0].value } == ["0", "0", "0"])
        #expect(emptyDetail.series?.points.count == 30)
        #expect(emptyDetail.series?.points.allSatisfy { $0.value == 0 } == true)

        // 键缺席（老后端 / 那次调用失败）→ 两段都不画。
        let missing = try usageResponse("{ \(fullSummary) }")
        let missingDetail = try #require(CodexUsageDetail.make(
            usage: missing,
            usages: quotaUsages(),
            today: today
        ))
        #expect(missingDetail.groups.isEmpty)
        #expect(missingDetail.series == nil)
        #expect(missingDetail.breakdown.count == 4)
    }

    @Test
    func bucketsOutsideTheWindowAndUnusableOnesAreIgnored() throws {
        let response = try usageResponse("""
        { "dailyUsageBuckets": [
            { "startDate": "2026-09-25T00:00:00Z", "tokens": 1000 },
            { "startDate": "not a date", "tokens": 999999 },
            { "startDate": "2026-09-20", "tokens": null },
            "nonsense"
        ] }
        """)

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        // 只有第一条可用：日期前缀能解析，tokens 才算数。
        #expect(detail.groups.map { $0.values[0].value } == ["1K", "1K", "1K"])
    }

    @Test
    func extremeBucketsSaturateInsteadOfTrapping() throws {
        // 敌意数据必须饱和，不许 trap。9/25 那两条钉住 `dayTotals` 的同日累加，
        // 9/24 那条让 `groups` 的 7 天 / 30 天累加器也要面对 `Int.max + Int.max`。
        let response = try usageResponse("""
        { "dailyUsageBuckets": [
            { "startDate": "2026-09-24", "tokens": 9223372036854775807 },
            { "startDate": "2026-09-25", "tokens": 9223372036854775807 },
            { "startDate": "2026-09-25", "tokens": 9223372036854775807 } ] }
        """)

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        let saturated = UsageAmountFormatter.compactAmount(.max)
        #expect(detail.groups.map { $0.values[0].value } == [saturated, saturated, saturated])
        // 注意别写成 `Double(.max)`：那是 greatestFiniteMagnitude，不是 `Int.max` 转过来的值。
        #expect(detail.series?.points.last?.value == Double(Int.max))
    }

    @Test
    func anAfternoonAnchorStillEndsTheWindowToday() throws {
        // 生产路径传的是「当下时刻」而不是 UTC 零点：锚点必须先规范化到当天，否则
        // `allowed` 会拒掉所有 bucket，表现为「三行全 0 + 一条平线」。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let afternoon = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 25, hour: 13, minute: 30
        ))!

        let response = try usageResponse("{ \(sparseBuckets) }")
        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: afternoon
        ))

        #expect(detail.groups.map { $0.values[0].value } == ["2M", "2.8M", "3.7M"])
        #expect(detail.series?.axisStart == "8/27")
        #expect(detail.series?.axisEnd == "9/25")
    }

    /// 窗口按 UTC 天切分，跟机器在哪个时区无关：锚点落在 9/25 这一 UTC 天的哪个小时，都该给出
    /// 同一条 8/27 … 9/25 的窗口。本地日历在 UTC+8 会把 20:00Z 算成 9/26、在 UTC-5 会把 02:00Z
    /// 算成 9/24，两种情况窗口都整体平移一天 —— 这就是「必须用 UTC」的回归钉子。
    ///
    /// 测试进程改不了系统时区，只能从 `today` 这个注入点造边界锚点；两端各取一个小时候，
    /// 任何非 UTC 的机器都会红。
    @Test
    func theWindowFollowsTheUTCDayNotTheLocalOne() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let response = try usageResponse("{ \(sparseBuckets) }")

        for hour in [0, 2, 12, 20, 23] {
            let anchor = calendar.date(from: DateComponents(
                year: 2026, month: 9, day: 25, hour: hour
            ))!
            let detail = try #require(CodexUsageDetail.make(
                usage: response,
                usages: quotaUsages(),
                today: anchor
            ))

            #expect(detail.series?.axisStart == "8/27")
            #expect(detail.series?.axisEnd == "9/25")
            #expect(detail.groups.map { $0.values[0].value } == ["2M", "2.8M", "3.7M"])
        }
    }

    /// 三个构建器共用同一处窗口日历，这一行钉住那份定义本身 —— 上面那条行为用例在 UTC 机器上
    /// 看不出差别（`.current` 恰好就是 UTC），这条至少把共享的 `utcCalendar()` 钉死；两个
    /// formatter 的时区取自同一个日历，一并钉住，防止将来有人把它们改成各自的 `.current`。
    @Test
    func theSharedWindowCalendarAndFormattersAreUTC() {
        let calendar = UsageDetailSupport.utcCalendar()
        #expect(calendar.timeZone.secondsFromGMT() == 0)
        #expect(UsageDetailSupport.dateFormatter(calendar: calendar).timeZone.secondsFromGMT() == 0)
        #expect(UsageDetailSupport.axisDateFormatter(calendar: calendar).timeZone.secondsFromGMT() == 0)
    }

    @Test
    func negativeBucketCountsAreDroppedRatherThanSubtracted() throws {
        let response = try usageResponse("""
        { "dailyUsageBuckets": [
            { "startDate": "2026-09-25", "tokens": 1200000 },
            { "startDate": "2026-09-25", "tokens": -500000 } ] }
        """)

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.groups.map { $0.values[0].value } == ["1.2M", "1.2M", "1.2M"])
    }
}
