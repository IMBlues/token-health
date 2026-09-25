import Foundation
import Testing
@testable import TokenHealth

@Suite
struct OpenCodeGoUsageDetailTests {
    /// 2026-09-25T00:00:00Z —— 30 天窗口是 8/27 … 9/25。
    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    private var usages: [TokenUsage] {
        [
            TokenUsage(window: .fiveHours, used: 32_000_000, limit: 1_200_000_000, resetDate: nil, unit: nil, displayValue: "$0.32 / $12.00"),
            TokenUsage(window: .week, used: 95_000_000, limit: 3_000_000_000, resetDate: nil, unit: nil, displayValue: "$0.95 / $30.00"),
            TokenUsage(window: .month, used: 222_000_000, limit: 6_000_000_000, resetDate: nil, unit: nil, displayValue: "$2.22 / $60.00")
        ]
    }

    private func bundle(
        summary: String? = #"{"totalRequests":902,"totalInputTokens":44000000,"totalOutputTokens":9000000,"totalCacheReadTokens":33000000,"totalCacheWrite5mTokens":1500000,"totalCacheWrite1hTokens":500000,"totalCostMicroCents":1986000000}"#,
        byDay: String? = Self.byDayJSON,
        models: String? = Self.modelsJSON
    ) -> Data {
        var object: [String: Any] = ["goStatus": ["access": ["meters": [:] as [String: Any]]]]
        if let summary { object["usageSummary"] = try! JSONSerialization.jsonObject(with: Data(summary.utf8)) }
        if let byDay { object["usageByDay"] = try! JSONSerialization.jsonObject(with: Data(byDay.utf8)) }
        if let models { object["usageModels"] = try! JSONSerialization.jsonObject(with: Data(models.utf8)) }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static let byDayJSON = """
    [
      {"date":"2026-09-25","totalRequests":12,"totalTokens":1200000,"totalCostMicroCents":41000000},
      {"date":"2026-09-25","totalRequests":1,"totalTokens":100000,"totalCostMicroCents":1000000},
      {"date":"2026-09-24","totalRequests":10,"totalTokens":1000000,"totalCostMicroCents":30000000},
      {"date":"2026-09-20","totalRequests":8,"totalTokens":800000,"totalCostMicroCents":20000000},
      {"date":"2026-09-19","totalRequests":7,"totalTokens":700000,"totalCostMicroCents":10000000},
      {"date":"2026-09-18","totalRequests":6,"totalTokens":600000,"totalCostMicroCents":5000000},
      {"date":"2026-08-27","totalRequests":5,"totalTokens":500000,"totalCostMicroCents":4000000},
      {"date":"2026-08-26","totalRequests":99,"totalTokens":9900000,"totalCostMicroCents":99000000},
      {"date":"2026-09-26","totalRequests":99,"totalTokens":9900000,"totalCostMicroCents":99000000}
    ]
    """

    private static let modelsJSON = """
    {
      "items": [
        {"model":"claude-sonnet-5","provider":"anthropic","totalRequests":402,"totalInputTokens":20000000,"totalOutputTokens":3000000,"totalCacheReadTokens":18000000,"totalCacheWrite5mTokens":100000,"totalCacheWrite1hTokens":100000,"totalCostMicroCents":819000000},
        {"model":"kimi-k2.5","provider":"opencode","totalRequests":310,"totalInputTokens":15000000,"totalOutputTokens":2000000,"totalCacheReadTokens":13000000,"totalCacheWrite5mTokens":50000,"totalCacheWrite1hTokens":50000,"totalCostMicroCents":602000000},
        {"model":"kimi-k2.5","provider":"moonshot","totalRequests":30,"totalInputTokens":500000,"totalOutputTokens":50000,"totalCacheReadTokens":50000,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":1000000},
        {"model":"","provider":"opencode","totalRequests":9,"totalInputTokens":90000,"totalOutputTokens":9000,"totalCacheReadTokens":1000,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":30000000},
        {"model":"free-model","provider":"opencode","totalRequests":4,"totalInputTokens":1000,"totalOutputTokens":0,"totalCacheReadTokens":0,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":0},
        {"model":"zero-model","provider":"opencode","totalRequests":0,"totalInputTokens":0,"totalOutputTokens":0,"totalCacheReadTokens":0,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":0}
      ],
      "pageInfo": {"page":1,"pageSize":100,"total":6,"pageCount":1}
    }
    """

    @Test
    func buildsHeadlineFromTheSnapshotsUsages() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))

        #expect(detail.headline.map(\.label) == ["5 hours", "Week", "Month"])
        #expect(detail.headline.map(\.value) == ["$0.32 / $12.00", "$0.95 / $30.00", "$2.22 / $60.00"])
    }

    @Test
    func headlinesSkipWindowsThatAreNotInTheSnapshot() throws {
        let onlyWeek = [TokenUsage(window: .week, used: 1, limit: 2, resetDate: nil, unit: nil, displayValue: "$0.01 / $0.02")]
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: onlyWeek, today: today))

        #expect(detail.headline.map(\.label) == ["Week"])
    }

    @Test
    func groupsSumTodaySevenAndThirtyDays() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))

        // Duplicate 9/25 rows sum; 8/26 and 9/26 fall outside the window and are dropped.
        #expect(detail.groups.map(\.title) == ["Today", "7 days", "30 days"])
        #expect(detail.groups[0].values.map(\.value) == ["13", "1.3M", "$0.42"])
        #expect(detail.groups[1].values.map(\.value) == ["38", "3.8M", "$1.02"])
        #expect(detail.groups[2].values.map(\.value) == ["49", "4.9M", "$1.11"])
        #expect(detail.groups[0].values.map(\.label) == ["Requests", "Tokens", "Cost"])
    }

    @Test
    func seriesCoversThirtyDaysEndingToday() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))
        let series = try #require(detail.series)

        #expect(series.points.count == 30)
        #expect(series.title == "Cost · last 30 days")
        #expect(series.emptyText == "No usage in the last 30 days")
        #expect(series.axisStart == "8/27")
        #expect(series.axisEnd == "9/25")
        // First point is 8/27 ($0.04); the 8/26 row must not leak into it.
        #expect(series.points.first?.value == 0.04)
        #expect(series.points.last?.value == 0.42)
        // Only six days carry usage; the other 24 points are zero-filled.
        #expect(series.points.filter { $0.value == 0 }.count == 30 - 6)
    }

    @Test
    func breakdownSumsBothCacheWriteWindows() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))

        #expect(detail.breakdown.map(\.label) == ["Input", "Output", "Cache read", "Cache write"])
        #expect(detail.breakdown.map(\.value) == ["44M", "9M", "33M", "2M"])
    }

    @Test
    func tableMergesModelsDropsEmptyRowsAndSortsByCost() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))
        let table = try #require(detail.table)

        #expect(table.title == "By model · last 30 days")
        #expect(table.columns == ["Model", "Requests", "Tokens", "Cost"])
        // kimi-k2.5 appears twice (two providers) and must be one row; zero-model is dropped.
        #expect(table.rows.map(\.name) == ["claude-sonnet-5", "kimi-k2.5", "Unknown model", "free-model"])
        #expect(table.rows[0].cells == ["402", "41.2M", "$8.19"])
        #expect(table.rows[1].cells == ["340", "30.7M", "$6.03"])
        #expect(table.footnote == nil)
    }

    @Test
    func tableTruncatesToSixRowsAndCountsTheRest() throws {
        let items = (0..<8).map { index in
            """
            {"model":"model-\(index)","provider":"opencode","totalRequests":1,"totalInputTokens":1000,"totalOutputTokens":0,"totalCacheReadTokens":0,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":\(100_000_000 - index * 1_000_000)}
            """
        }
        let models = "{\"items\":[\(items.joined(separator: ","))]}"
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(models: models), usages: usages, today: today))
        let table = try #require(detail.table)

        #expect(table.rows.count == 6)
        #expect(table.rows.first?.name == "model-0")
        #expect(table.footnote == "+2 more models")
    }

    @Test
    func missingUsageKeysLeaveTheSectionsOut() throws {
        let detail = try #require(
            OpenCodeGoUsageDetail.make(bundle: bundle(summary: nil, byDay: nil, models: nil), usages: usages, today: today)
        )

        #expect(detail.headline.count == 3)
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.table == nil)
    }

    @Test
    func anEmptyThirtyDaysStillDrawsZeros() throws {
        let detail = try #require(
            OpenCodeGoUsageDetail.make(bundle: bundle(summary: #"{}"#, byDay: "[]", models: #"{"items":[]}"#), usages: usages, today: today)
        )

        #expect(detail.groups[2].values.map(\.value) == ["0", "0", "$0.00"])
        #expect(detail.series?.points.allSatisfy { $0.value == 0 } == true)
        #expect(detail.breakdown.map(\.value) == ["0", "0", "0", "0"])
        #expect(detail.table == nil)
    }

    @Test
    func noMetersAndNoUsageMeansNoDetail() {
        #expect(OpenCodeGoUsageDetail.make(bundle: bundle(summary: nil, byDay: nil, models: nil), usages: [], today: today) == nil)
    }

    @Test
    func garbageBundleMeansNoDetail() {
        #expect(OpenCodeGoUsageDetail.make(bundle: Data("not json".utf8), usages: usages, today: today) == nil)
    }
}
