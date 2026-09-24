import Foundation
import Testing
@testable import TokenHealth

struct DeepSeekUsageDetailTests {
    // 固定「今天」，让补 0 的区间可预期。
    private let period = DeepSeekUsagePeriod(year: 2026, month: 9, day: "2026-09-24")

    private func bundle(amountDays: String, costDays: String?) -> Data {
        let cost = costDays.map { "\"cost\":{\"data\":[{\"currency\":\"CNY\",\"days\":\($0)}]}" } ?? "\"cost\":{}"
        let json = "{\"summary\":{},\"amount\":{\"data\":{\"biz_data\":{\"days\":\(amountDays)}}},\(cost)}"
        return Data(json.utf8)
    }

    /// amount 响应里的一天：带四种 type。
    private func day(_ date: String, model: String, requests: Int, output: Int, hit: Int, miss: Int) -> String {
        """
        {"date":"\(date)","data":[{"model":"\(model)","usage":[
          {"type":"REQUEST","amount":"\(requests)"},
          {"type":"RESPONSE_TOKEN","amount":"\(output)"},
          {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"\(hit)"},
          {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"\(miss)"}]}]}
        """
    }

    /// cost 响应里的一天：只有金额，没有 type / tokens。
    /// **不能拿上面的 amount helper 造 cost** —— 它产出的条目求和不含金额，恒为 0，
    /// 会让「只在 cost 里出现、且真的有花费」的模型被当成全零模型丢掉。
    private func costDay(_ date: String, model: String, amount: String) -> String {
        """
        {"date":"\(date)","data":[{"model":"\(model)","usage":[{"amount":"\(amount)"}]}]}
        """
    }

    private func balances(_ pairs: [(String, String)]) -> [TokenUsage] {
        pairs.map { currency, amount in
            TokenUsage(
                window: .balance, label: "Balance \(currency)", used: 0, limit: nil,
                resetDate: nil, unit: currency, displayValue: "\(amount) \(currency)",
                amount: Decimal(string: amount)
            )
        }
    }

    @Test
    func buildsHeadlineFromBalances() throws {
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: bundle(amountDays: "[]", costDays: nil),
                balances: balances([("CNY", "1284.60"), ("USD", "3.00")]),
                today: period
            )
        )

        #expect(detail.headline.map(\.label) == ["CNY", "USD"])
        #expect(detail.headline.map(\.value) == ["1,284.60", "3.00"], "币种在 label 上，值里不重复")
    }

    @Test
    func sumsTodayAndTheMonthAcrossModels() throws {
        let amount = """
        [\(day("2026-09-23", model: "deepseek-chat", requests: 10, output: 100, hit: 200, miss: 50)),
         \(day("2026-09-24", model: "deepseek-chat", requests: 4, output: 40, hit: 80, miss: 20)),
         \(day("2026-09-24", model: "deepseek-reasoner", requests: 2, output: 60, hit: 10, miss: 30))]
        """
        let cost = """
        [\(costDay("2026-09-23", model: "deepseek-chat", amount: "0.40")),
         \(costDay("2026-09-24", model: "deepseek-chat", amount: "0.02"))]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: bundle(amountDays: amount, costDays: cost),
                balances: [],
                today: period
            )
        )

        let today = try #require(detail.groups.first { $0.title == "Today" })
        #expect(today.values.map(\.label) == ["Requests", "Tokens", "Cost"], "浮层文案与 App 其余部分一致，用英文")
        #expect(today.values[0].value == "6")
        #expect(today.values[1].value == "240")
        #expect(today.values[2].value == "0.02 CNY", "今日花费来自 cost 响应")

        let month = try #require(detail.groups.first { $0.title == "This month" })
        #expect(month.values[0].value == "16")
        #expect(month.values[1].value == "590")
        #expect(month.values[2].value == "0.42 CNY")
    }

    @Test
    func padsMissingDaysWithZero() throws {
        let amount = "[\(day("2026-09-01", model: "m", requests: 1, output: 10, hit: 0, miss: 0))," +
                     " \(day("2026-09-24", model: "m", requests: 1, output: 10, hit: 0, miss: 0))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let series = try #require(detail.series)
        #expect(series.title == "Tokens this month")
        #expect(series.points.count == 24, "当月 1 号到今天，逐日一个点")
        #expect(series.points.first?.value == 10)
        #expect(series.points[1].value == 0, "中间没数据的日期补 0")
        #expect(series.points.last?.value == 10)
        #expect(series.axisStart == "9/1")
        #expect(series.axisEnd == "9/24")
    }

    @Test
    func sumsDuplicateDatesInsteadOfDoubleCounting() throws {
        let amount = "[\(day("2026-09-24", model: "m", requests: 2, output: 10, hit: 0, miss: 0))," +
                     " \(day("2026-09-24", model: "m", requests: 3, output: 5, hit: 0, miss: 0))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let series = try #require(detail.series)
        #expect(series.points.count == 24)
        #expect(series.points.last?.value == 15, "同一天出现两次要相加，且只产出 1 个点")
        let today = try #require(detail.groups.first { $0.title == "Today" })
        #expect(today.values[0].value == "5")
    }

    @Test
    func skipsUnparseableAndOutOfMonthDates() throws {
        let amount = """
        [{"date":"garbage","data":[{"model":"m","usage":[{"type":"REQUEST","amount":"99"}]}]},
         \(day("2026-08-31", model: "m", requests: 7, output: 7, hit: 0, miss: 0)),
         \(day("2026-09-10", model: "m", requests: 1, output: 10, hit: 0, miss: 0))]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let month = try #require(detail.groups.first { $0.title == "This month" })
        #expect(month.values[0].value == "1", "解析不了的日子与上月都不该进合计")
        #expect(detail.series?.points.count == 24)
    }

    @Test
    func acceptsDatesWithATimeSuffix() throws {
        // 既有解析器用前缀匹配，容忍 "2026-09-24T00:00:00Z" 这类写法；详情这边口径要一致。
        let amount = """
        [{"date":"2026-09-24T00:00:00Z","data":[{"model":"m","usage":[{"type":"REQUEST","amount":"3"}]}]}]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let today = try #require(detail.groups.first { $0.title == "Today" })
        #expect(today.values[0].value == "3")
    }

    @Test
    func reportsTheTokenBreakdown() throws {
        let amount = "[\(day("2026-09-10", model: "m", requests: 1, output: 100, hit: 900, miss: 20))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        #expect(detail.breakdown.map(\.label) == ["Output", "Cache hit", "Cache miss"])
        #expect(detail.breakdown.map(\.value) == ["100", "900", "20"])
    }

    @Test
    func buildsAModelTableSortedByTokens() throws {
        let amount = """
        [\(day("2026-09-10", model: "small", requests: 1, output: 10, hit: 0, miss: 0)),
         \(day("2026-09-10", model: "big", requests: 5, output: 5_000, hit: 0, miss: 0))]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let table = try #require(detail.table)
        #expect(table.title == "By model · this month")
        #expect(table.columns == ["Model", "Requests", "Tokens", "Cost"])
        #expect(table.rows.map(\.name) == ["big", "small"])
        #expect(table.rows[0].cells.count == table.columns.count - 1)
        #expect(table.rows[0].cells == ["5", "5K", "—"], "没有 cost 数据时花费是破折号")
    }

    @Test
    func keepsModelsThatOnlyAppearInTheCostResponse() throws {
        let amount = "[\(day("2026-09-10", model: "chat", requests: 1, output: 100, hit: 0, miss: 0))]"
        // legacy 只在 cost 里出现，而且**真的有花费** —— 否则它会被「全零模型不成行」的规则丢掉。
        let cost = "[\(costDay("2026-09-10", model: "chat", amount: "0.10"))," +
                   " \(costDay("2026-09-10", model: "legacy", amount: "1.20"))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: cost), balances: [], today: period)
        )

        let table = try #require(detail.table)
        #expect(table.rows.count == 2)
        let legacy = try #require(table.rows.first { $0.name == "legacy" })
        #expect(legacy.cells[1] == "0", "只在 cost 里出现的模型仍然成行")
        #expect(legacy.cells[2] == "1.20 CNY", "它的花费来自 cost 响应")
    }

    @Test
    func dropsModelsThatHaveNothingAtAll() throws {
        let amount = "[\(day("2026-09-10", model: "real", requests: 1, output: 100, hit: 0, miss: 0))]"
        // 两边都有、但 tokens 与花费都是 0 的模型不该占掉六行里的位置。
        let cost = "[\(costDay("2026-09-10", model: "real", amount: "0.10"))," +
                   " \(costDay("2026-09-10", model: "ghost", amount: "0"))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: cost), balances: [], today: period)
        )

        #expect(detail.table?.rows.map(\.name) == ["real"])
    }

    @Test
    func mergesUnnamedModelsIntoOneRow() throws {
        let amount = """
        [{"date":"2026-09-10","data":[
            {"usage":[{"type":"RESPONSE_TOKEN","amount":"100"}]},
            {"model":"","usage":[{"type":"RESPONSE_TOKEN","amount":"50"}]}]}]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let table = try #require(detail.table)
        #expect(table.rows.map(\.name) == ["Unknown model"])
        #expect(table.rows[0].cells[1] == "150")
    }

    @Test
    func truncatesTheTableToSixRowsWithAFootnote() throws {
        let entries = (1...8).map { index in
            day("2026-09-10", model: "model-\(index)", requests: 1, output: index * 100, hit: 0, miss: 0)
        }
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: bundle(amountDays: "[\(entries.joined(separator: ","))]", costDays: nil),
                balances: [],
                today: period
            )
        )

        let table = try #require(detail.table)
        #expect(table.rows.count == 6)
        #expect(table.footnote == "+2 more models")
        #expect(table.rows.first?.name == "model-8", "按 tokens 降序")
    }

    @Test
    func joinsMultipleCurrenciesWithASeparator() throws {
        let amount = "[\(day("2026-09-24", model: "m", requests: 1, output: 10, hit: 0, miss: 0))]"
        let cost = """
        [{"currency":"USD","days":[{"date":"2026-09-24","data":[{"model":"m","usage":[{"amount":"0.30"}]}]}]},
         {"currency":"CNY","days":[{"date":"2026-09-24","data":[{"model":"m","usage":[{"amount":"41.80"}]}]}]}]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: Data("{\"amount\":{\"data\":{\"biz_data\":{\"days\":\(amount)}}},\"cost\":{\"data\":\(cost)}}".utf8),
                balances: [],
                today: period
            )
        )

        let today = try #require(detail.groups.first { $0.title == "Today" })
        #expect(today.values[2].value == "41.80 CNY · 0.30 USD", "币种按名字升序")
    }

    @Test
    func reportsNoDataForAQuietMonth() throws {
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: "[]", costDays: nil), balances: [], today: period)
        )

        #expect(detail.series?.points.count == 24)
        #expect(detail.series?.points.allSatisfy { $0.value == 0 } == true)
        #expect(detail.table == nil, "没有模型就不画表")
        #expect(detail.isEmpty == false, "趋势图还在，浮层不算空")
    }

    @Test
    func returnsNilForAMalformedBundle() {
        #expect(DeepSeekUsageDetail.make(bundle: Data("not json".utf8), balances: [], today: period) == nil)
    }
}
