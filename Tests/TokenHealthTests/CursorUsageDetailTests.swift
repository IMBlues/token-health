import Foundation
import Testing
@testable import TokenHealth

@Suite
struct CursorUsageDetailTests {
    /// 2026-09-30T00:00:00Z。周期取真实抓包的那一个：8/30 07:13 → 9/30 07:13（UTC）。
    private var today: Date { Self.date(year: 2026, month: 9, day: 30) }
    private var cycleStart: Date { Self.date(year: 2026, month: 8, day: 30, hour: 7, minute: 13, second: 20) }
    private var cycleEnd: Date { Self.date(year: 2026, month: 9, day: 30, hour: 7, minute: 13, second: 20) }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    /// 与 `CursorUsageMapper` 产出的形状一致：三条池都是 `.month`、unit 是 `%`、带自己的 label。
    private func poolUsages() -> [TokenUsage] {
        [
            TokenUsage(window: .month, label: "Auto + Composer", used: 95, limit: 100, unit: "%"),
            TokenUsage(window: .month, label: "API", used: 100, limit: 100, unit: "%"),
            TokenUsage(window: .month, label: "Grokbot", used: 34, limit: 100, unit: "%")
        ]
    }

    private func dailySpend(_ json: String) throws -> CursorDailySpendResponse {
        try JSONDecoder().decode(CursorDailySpendResponse.self, from: Data(json.utf8))
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private var breakdown: CursorPlanBreakdown {
        try! JSONDecoder().decode(
            CursorPlanBreakdown.self,
            from: Data(#"{"included": 2000, "bonus": 43019, "total": 45019}"#.utf8)
        )
    }

    private func make(
        usages: [TokenUsage]? = nil,
        planBreakdown: CursorPlanBreakdown? = nil,
        cycleStart: Date? = nil,
        cycleEnd: Date? = nil,
        dailySpend: CursorDailySpendResponse? = nil,
        today: Date? = nil
    ) -> UsageDetail? {
        CursorUsageDetail.make(
            usages: usages ?? poolUsages(),
            planBreakdown: planBreakdown,
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            dailySpend: dailySpend,
            today: today ?? self.today
        )
    }

    // MARK: - headline

    @Test
    func headlineMirrorsThePinnedMenuBarMetrics() {
        let detail = make(planBreakdown: breakdown, cycleEnd: cycleEnd)

        #expect(detail?.headline.map(\.label) == ["Auto + Composer", "API", "Grokbot"])
        #expect(detail?.headline.map(\.value) == ["95%", "100%", "34%"])
        #expect(detail?.headline.map(\.ratio) == [0.95, 1, 0.34], "额度行要带比例，浮层才画得出条")
        // 没有按天数据时不该凭空造出别的区块。
        #expect(detail?.groups.isEmpty == true)
        #expect(detail?.series == nil)
        #expect(detail?.table == nil)
        // 只有花费行的那次调用里，breakdown 仍然要画。
        #expect(detail?.breakdown.map(\.label) == ["Included", "Bonus", "Total", "Resets"])
    }

    @Test
    func emptyUsagesWithoutAnySectionProduceNoDetail() {
        #expect(make(usages: []) == nil, "四个区块都空时浮层该退回错误行")
    }

    // MARK: - groups

    @Test
    func groupsSumTodayTheTrailingWeekAndTheCycle() throws {
        // 9/24 只在「7 天」里（周期内），8/29 在周期外、也在 7 天外。
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "grok-bot-default", "totalTokens": "1000" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 24)))", "category": "default", "totalTokens": "2000" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 8, day: 29)))", "category": "default", "totalTokens": "4000" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 10)))", "category": "default", "totalTokens": "500" }
            ] }
            """
        )

        let detail = try #require(make(
            planBreakdown: breakdown,
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            dailySpend: spend
        ))

        #expect(detail.groups.map(\.title) == ["Today", "7 days", "Billing cycle"])
        #expect(detail.groups.map { $0.values.map(\.label) } == [["Tokens"], ["Tokens"], ["Tokens"]])
        #expect(detail.groups.map { $0.values.map(\.value) } == [["1K"], ["3K"], ["3.5K"]])
        // 列标题取第一组的 values，三组列必须同形。
        #expect(Set(detail.groups.map { $0.values.count }) == [1])
    }

    @Test
    func sameDayRowsSumAndMissingDaysCountAsZero() throws {
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "a", "totalTokens": "700" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "b", "totalTokens": "300" }
            ] }
            """
        )

        let detail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: spend))

        #expect(detail.groups.first?.values.first?.value == "1K", "同一天多条要求和")
        #expect(detail.groups.last?.values.first?.value == "1K")
        #expect(detail.series?.points.count == 32, "8/30…9/30 共 32 天，缺的那几天补 0")
        #expect(detail.series?.points.last?.value == 1000)
        #expect(detail.series?.points.first?.value == 0)
    }

    @Test
    func emptyDailySpendDrawsZeroRowsButAMissingArrayDoesNot() throws {
        let empty = try dailySpend(#"{ "dailySpend": [] }"#)
        let emptyDetail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: empty))
        #expect(emptyDetail.groups.map { $0.values.first?.value } == ["0", "0", "0"], "空数组是「这些天没用量」，照画 0")
        #expect(emptyDetail.series?.points.count == 32)
        #expect(emptyDetail.table == nil)

        // `{}` —— 接口失败或没有按天数据 —— 整段不画，不是画成 0。
        let absent = try dailySpend("{}")
        let absentDetail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: absent))
        #expect(absentDetail.groups.isEmpty)
        #expect(absentDetail.series == nil)
        #expect(absentDetail.headline.count == 3, "额度照常")
    }

    // MARK: - series

    @Test
    func seriesCoversTheCycleAndLabelsItsEnds() throws {
        // 空数组（而不是 `{}`）：这些天没有用量，趋势图与三行 0 都要照画。
        let detail = try #require(make(
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            dailySpend: try dailySpend(#"{ "dailySpend": [] }"#)
        ))

        #expect(detail.series?.title == "Tokens · billing cycle")
        #expect(detail.series?.axisStart == "8/30")
        #expect(detail.series?.axisEnd == "9/30")
        #expect(detail.series?.emptyText == "No usage in this billing cycle")
    }

    @Test
    func aMissingCycleFallsBackToTheTrailingThirtyDays() throws {
        let detail = try #require(make(
            cycleStart: nil,
            cycleEnd: nil,
            dailySpend: try dailySpend(#"{ "dailySpend": [] }"#)
        ))

        #expect(detail.groups.map(\.title) == ["Today", "7 days", "30 days"])
        #expect(detail.groups.last?.values.first?.value == "0")
        #expect(detail.series?.title == "Tokens · last 30 days")
        #expect(detail.series?.axisStart == "9/1")
        #expect(detail.series?.axisEnd == "9/30")
        #expect(detail.series?.points.count == 30)
        #expect(detail.breakdown.map(\.label) == [], "没有 breakdown、也没有周期末日时，这一段不画")
    }

    @Test
    func anInvertedCycleAlsoFallsBackInsteadOfDrawingNothing() throws {
        let detail = try #require(make(
            cycleStart: Self.date(year: 2026, month: 9, day: 30),
            cycleEnd: Self.date(year: 2026, month: 9, day: 1),
            dailySpend: try dailySpend(#"{ "dailySpend": [] }"#)
        ))

        #expect(detail.groups.map(\.title) == ["Today", "7 days", "30 days"])
        #expect(detail.series?.points.count == 30)
    }

    // MARK: - window

    /// 回归：本机 2026-09-30 07:13 刚滚进新计费周期，窗口一度被切成 `[9/30, 9/30]` ——
    /// 一天的柱状图是一整条通栏色块，轴两端还都写着 9/30。
    @Test
    func aCycleYoungerThanTheWindowKeepsTheRollingWindow() {
        let calendar = UsageDetailSupport.utcCalendar()
        let window = CursorUsageDetail.window(
            cycleStart: Self.date(year: 2026, month: 9, day: 30, hour: 7, minute: 13, second: 20),
            cycleEnd: Self.date(year: 2026, month: 10, day: 30, hour: 7, minute: 13, second: 20),
            today: Self.date(year: 2026, month: 9, day: 30, hour: 15),
            calendar: calendar
        )

        #expect(window.days.count == 30, "窗口至少 30 天，不能缩成一天")
        #expect(window.start == Self.date(year: 2026, month: 9, day: 1))
        #expect(window.end == Self.date(year: 2026, month: 9, day: 30))
        #expect(window.groupTitle == "30 days", "窗口不是周期，标题要如实")
        #expect(!window.isCycle)
        #expect(window.fetchStart == window.start, "窗口本身就有 30 天，取数不用再往前多要")
    }

    /// 用户的抱怨原样固化：新周期第一天打开浮层，图上必须有上一个周期的数据，
    /// 而不是一根通栏色块。
    @Test
    func aFreshCycleStillDrawsAMonthOfHistory() throws {
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 12)))", "category": "cursor-grok-4.6-high", "totalTokens": "12000000" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "grok-bot-default", "totalTokens": "603770" }
            ] }
            """
        )
        let detail = try #require(make(
            cycleStart: Self.date(year: 2026, month: 9, day: 30, hour: 7, minute: 13, second: 20),
            cycleEnd: Self.date(year: 2026, month: 10, day: 30, hour: 7, minute: 13, second: 20),
            dailySpend: spend,
            today: Self.date(year: 2026, month: 9, day: 30, hour: 15)
        ))

        #expect(detail.groups.map(\.title) == ["Today", "7 days", "30 days"])
        #expect(detail.series?.points.count == 30)
        #expect(detail.series?.points.count { $0.value > 0 } == 2, "9/12 与 9/30 两天有量")
        #expect(
            detail.series?.points.first { $0.date == Self.date(year: 2026, month: 9, day: 12) }?.value == 12_000_000,
            "上一个周期的用量仍然在图上"
        )
        #expect(detail.series?.axisStart == "9/1")
        #expect(detail.series?.axisEnd == "9/30")
        #expect(detail.table?.title == "Grok bot · last 30 days")
        #expect(detail.table?.rows.map(\.name) == ["cursor-grok-4.6-high", "grok-bot-default"])
    }

    /// 同一个账号、同一天，但周期已经跑了 30 天以上时仍然按周期画（既有行为）。
    @Test
    func aCycleOlderThanTheWindowIsTheWindow() {
        let calendar = UsageDetailSupport.utcCalendar()
        let window = CursorUsageDetail.window(
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            today: today,
            calendar: calendar
        )

        #expect(window.isCycle)
        #expect(window.start == Self.date(year: 2026, month: 8, day: 30))
        #expect(window.days.count == 32, "8/30…9/30 共 32 天")
        #expect(window.groupTitle == "Billing cycle")
    }

    @Test
    func theWindowNeverRunsPastToday() {
        let calendar = UsageDetailSupport.utcCalendar()
        let window = CursorUsageDetail.window(
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            today: today,
            calendar: calendar
        )

        #expect(window.end == today, "周期末日是 9/30 07:13，窗口末日只能到 9/30 —— 未来没有数据")
        #expect(window.fetchStart == Self.date(year: 2026, month: 8, day: 30))
    }

    /// 下午锚点：所有窗口都按 UTC 自然日取整，若把锚点原样当成某天的起点，当天那一行会整个错位。
    @Test
    func anAfternoonAnchorStillCountsAsTheSameDay() throws {
        let afternoon = Self.date(year: 2026, month: 9, day: 30, hour: 15, minute: 42)
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "default", "totalTokens": "1234" }
            ] }
            """
        )

        let detail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: spend, today: afternoon))

        #expect(detail.groups.first?.values.first?.value == "1.23K")
        #expect(detail.series?.points.last?.value == 1234, "窗口末日仍是今天")
    }

    // MARK: - breakdown

    @Test
    func breakdownRendersCentsAndTheResetDay() throws {
        let detail = try #require(make(
            planBreakdown: breakdown,
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            dailySpend: try dailySpend("{}")
        ))

        #expect(detail.breakdown.map(\.label) == ["Included", "Bonus", "Total", "Resets"])
        #expect(detail.breakdown.map(\.value) == ["$20.00", "$430.19", "$450.19", "9/30"])
        #expect(detail.breakdown.allSatisfy { $0.ratio == nil }, "金额不是比例，不该画额度条")
    }

    @Test
    func eachBreakdownPieceDegradesOnItsOwn() throws {
        let partial = try JSONDecoder().decode(
            CursorPlanBreakdown.self,
            from: Data(#"{"bonus": 43019}"#.utf8)
        )
        let detail = try #require(make(planBreakdown: partial, cycleStart: cycleStart, cycleEnd: cycleEnd))

        #expect(detail.breakdown.map(\.label) == ["Bonus", "Resets"])
        #expect(detail.breakdown.first?.value == "$430.19")
    }

    @Test
    func negativeAmountsAreBadDataAndDoNotRender() throws {
        let negative = try JSONDecoder().decode(
            CursorPlanBreakdown.self,
            from: Data(#"{"included": -1, "bonus": 0, "total": -500}"#.utf8)
        )
        let detail = try #require(make(planBreakdown: negative, cycleStart: cycleStart, cycleEnd: cycleEnd))

        #expect(detail.breakdown.map(\.label) == ["Bonus", "Resets"], "负数不占位；0 是真的，照画；重置日与金额无关")
        #expect(detail.breakdown.first?.value == "$0.00")
    }

    // MARK: - Grok bot table

    @Test
    func theTableListsEveryGrokModelByTokens() throws {
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 29)))", "category": "cursor-grok-4.6-high", "totalTokens": "49474832" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "grok-bot-default", "totalTokens": "100000000" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "GROK-bot-automation", "totalTokens": "3182562" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "claude-opus-5-thinking-high", "totalTokens": "6252288" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "Other", "totalTokens": "1929649" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 8, day: 29)))", "category": "cursor-grok-4.5-high", "totalTokens": "999999999" }
            ] }
            """
        )

        let detail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: spend))
        let table = try #require(detail.table)

        #expect(table.title == "Grok bot · this cycle")
        #expect(table.columns == ["Model", "Tokens"])
        // 名字原样保留（大小写也不改写）；非 grok 的模型与 Other 不进表；周期外的那条不算。
        #expect(table.rows.map(\.name) == ["grok-bot-default", "cursor-grok-4.6-high", "GROK-bot-automation"])
        #expect(table.rows.map(\.cells) == [["100M"], ["49.47M"], ["3.18M"]])
        #expect(table.footnote == nil)
    }

    @Test
    func theTableKeepsSixRowsAndCountsTheRest() throws {
        let rows = (1...9).map { index in
            """
            { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "grok-\(index)", "totalTokens": "\(index * 1000)" }
            """
        }.joined(separator: ",")
        let detail = try #require(make(
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            dailySpend: try dailySpend("{ \"dailySpend\": [\(rows)] }")
        ))

        let table = try #require(detail.table)
        #expect(table.rows.count == 6)
        #expect(table.rows.first?.name == "grok-9")
        #expect(table.footnote == "+3 more models")
    }

    @Test
    func noGrokUsageMeansNoTable() throws {
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "default", "totalTokens": "1000" }
            ] }
            """
        )

        let detail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: spend))

        #expect(detail.table == nil)
        #expect(detail.groups.last?.values.first?.value == "1K", "非 grok 的量仍算在汇总里")
    }

    // MARK: - bad rows and saturation

    @Test
    func malformedRowsAreIgnoredRatherThanCountedAsZero() throws {
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "not-a-number", "category": "default", "totalTokens": "1000" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "default" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "", "totalTokens": "1000" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "default", "totalTokens": "-5" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "default", "totalTokens": "7" },
              42
            ] }
            """
        )

        let detail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: spend))

        #expect(detail.groups.first?.values.first?.value == "7", "坏的整条忽略，不当 0；一行不是对象也不能带塌整个数组")
    }

    @Test
    func hostileTokenCountsSaturateInsteadOfTrapping() throws {
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "grok-a", "totalTokens": "\(Int64.max)" },
              { "day": "\(milliseconds(Self.date(year: 2026, month: 9, day: 30)))", "category": "grok-b", "totalTokens": "\(Int64.max)" }
            ] }
            """
        )

        let detail = try #require(make(cycleStart: cycleStart, cycleEnd: cycleEnd, dailySpend: spend))

        #expect(detail.groups.first?.values.first?.value.isEmpty == false, "饱和而不是 trap")
        #expect(detail.table?.rows.isEmpty == false)
    }

    // MARK: - decoding

    @Test
    func dailySpendDecodesStringsAndNumbersAlike() throws {
        let spend = try dailySpend(
            """
            { "dailySpend": [
              { "day": "1788134400000", "category": "a", "totalTokens": "49474832" },
              { "day": 1788134400000, "category": "b", "totalTokens": 1000 }
            ], "categories": ["a", "b"] }
            """
        )

        let rows = try #require(spend.dailySpend)
        #expect(rows.count == 2)
        #expect(rows[0].dayMilliseconds == 1_788_134_400_000)
        #expect(rows[0].totalTokens == 49_474_832)
        #expect(rows[1].dayMilliseconds == 1_788_134_400_000)
        #expect(rows[1].totalTokens == 1000)
    }

    @Test
    func anAbsentDailySpendArrayDecodesToNil() throws {
        #expect(try dailySpend("{}").dailySpend == nil)
        // 解不出的响应该整份作废（调用方把抛错换成 nil），而不是半份数据。
        #expect(throws: DecodingError.self) {
            try self.dailySpend(#"{"dailySpend": "nope"}"#)
        }
    }

    // MARK: - 真实接口冒烟

    /// 只断言「面板画得出来」，不断言具体数值 —— 数据每天都在变。
    /// `TOKEN_HEALTH_LIVE_CURSOR=1 bash scripts/test.sh` 才会跑。
    @Test(.enabled(if: CursorTestSupport.liveCursorCheckEnabled))
    func buildsThePanelFromTheLiveAccount() async throws {
        let today = Date()
        let inputs = try await CursorTestSupport.fetchLivePanelInputs(today: today)
        let detail = try #require(CursorUsageDetail.make(
            usages: inputs.mapped.usages,
            planBreakdown: inputs.mapped.breakdown,
            cycleStart: inputs.mapped.billingCycleStart,
            cycleEnd: inputs.mapped.billingCycleEnd,
            dailySpend: inputs.dailySpend,
            today: today
        ))

        #expect(detail.headline.contains { $0.label == "Auto + Composer" })
        #expect(detail.groups.count == 3)
        #expect(detail.series?.points.isEmpty == false)
        #expect(detail.breakdown.contains { $0.label == "Resets" })
        #expect(
            detail.table?.rows.isEmpty == false,
            "本机账号周期内有 Grok bot 用量；空表说明按天数据没接上"
        )
    }
}
