import Foundation

/// 把一次刷新取回的 bundle 变成浮层要画的 `UsageDetail`。
///
/// 不抛错：解析不出来就返回 nil，让菜单栏项退回小菜单 —— 详情失败不该影响面板上的用量。
enum DeepSeekUsageDetail {
    static let tableRowLimit = 6
    static let unknownModelName = "Unknown model"

    /// 一天或一个模型的合计。
    private struct Totals: Equatable {
        var requests = 0
        var outputTokens = 0
        var cacheHitTokens = 0
        var cacheMissTokens = 0
        var costByCurrency: [String: Decimal] = [:]

        var tokens: Int { outputTokens + cacheHitTokens + cacheMissTokens }
        var hasAnything: Bool { tokens > 0 || requests > 0 || costByCurrency.values.contains { $0 > 0 } }

        mutating func add(tokens other: Totals) {
            requests += other.requests
            outputTokens += other.outputTokens
            cacheHitTokens += other.cacheHitTokens
            cacheMissTokens += other.cacheMissTokens
            for (currency, amount) in other.costByCurrency {
                costByCurrency[currency, default: Decimal(0)] += amount
            }
        }
    }

    static func make(bundle: Data, balances: [TokenUsage], today: DeepSeekUsagePeriod) -> UsageDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: bundle) as? [String: Any] else {
            return nil
        }

        // 当月 1 号到今天的日期列表，趋势图与「本月」都基于它。
        let calendar = UsageDetailSupport.utcCalendar()
        let daysInRange = UsageDetailSupport.monthToDateDayList(day: today.day, calendar: calendar)
        guard !daysInRange.isEmpty else {
            return nil
        }

        var byDay: [Date: Totals] = [:]
        var byModel: [String: Totals] = [:]
        byDay = dayTotals(fromAmount: root["amount"] as? [String: Any] ?? [:], allowed: Set(daysInRange), calendar: calendar, into: &byModel)
        var modelCosts: [String: Totals] = [:]
        let dayCosts = dayCosts(fromCost: root["cost"] as? [String: Any] ?? [:], allowed: Set(daysInRange), calendar: calendar, into: &modelCosts)
        merge(modelCosts, into: &byModel)
        merge(dayCosts, into: &byDay)

        var detail = UsageDetail()
        detail.headline = headline(from: balances)
        detail.groups = groups(today: today, daysInRange: daysInRange, byDay: byDay, calendar: calendar)
        detail.series = series(today: today, daysInRange: daysInRange, byDay: byDay, calendar: calendar)
        detail.breakdown = breakdown(byDay)
        detail.table = table(byModel)
        return detail
    }

    // MARK: - headline

    /// 余额：label 是币种代码，值只放金额 —— 币种已经在 label 上了，值里再来一遍是重复。
    private static func headline(from balances: [TokenUsage]) -> [DetailStat] {
        balances.compactMap { balance in
            guard let currency = balance.unit, !currency.isEmpty, let amount = balance.amount else {
                return nil
            }
            return DetailStat(label: currency, value: UsageAmountFormatter.moneyText(amount))
        }
    }

    // MARK: - groups

    private static func groups(
        today: DeepSeekUsagePeriod,
        daysInRange: [Date],
        byDay: [Date: Totals],
        calendar: Calendar
    ) -> [DetailGroup] {
        let todayTotals = daysInRange.last.flatMap { byDay[$0] } ?? Totals()
        var monthTotals = Totals()
        for date in daysInRange {
            monthTotals.add(tokens: byDay[date] ?? Totals())
        }
        return [
            DetailGroup(title: "Today", values: values(for: todayTotals)),
            DetailGroup(title: "This month", values: values(for: monthTotals))
        ]
    }

    private static func values(for totals: Totals) -> [DetailStat] {
        [
            DetailStat(label: "Requests", value: UsageAmountFormatter.compactAmount(totals.requests)),
            DetailStat(label: "Tokens", value: UsageAmountFormatter.compactAmount(totals.tokens)),
            DetailStat(label: "Cost", value: costText(totals.costByCurrency))
        ]
    }

    /// 花费按币种升序拼；**一个币种条目都没有**才是破折号，币种存在但为 0 照常显示。
    private static func costText(_ costByCurrency: [String: Decimal]) -> String {
        guard !costByCurrency.isEmpty else {
            return "—"
        }
        return costByCurrency.keys.sorted()
            .map { money(costByCurrency[$0] ?? 0, currency: $0) }
            .joined(separator: " · ")
    }

    // MARK: - series

    private static func series(
        today: DeepSeekUsagePeriod,
        daysInRange: [Date],
        byDay: [Date: Totals],
        calendar: Calendar
    ) -> DetailSeries {
        let points = daysInRange.map { date in
            DetailSeriesPoint(date: date, value: Double(byDay[date]?.tokens ?? 0))
        }
        let formatter = UsageDetailSupport.axisDateFormatter(calendar: calendar)
        return DetailSeries(
            title: "Tokens this month",
            points: points,
            axisStart: daysInRange.first.map { formatter.string(from: $0) } ?? "",
            axisEnd: daysInRange.last.map { formatter.string(from: $0) } ?? "",
            emptyText: "No usage this month"
        )
    }

    // MARK: - breakdown

    private static func breakdown(_ byDay: [Date: Totals]) -> [DetailStat] {
        var totals = Totals()
        for day in byDay.values {
            totals.add(tokens: day)
        }

        // 命中率的分母只有 prompt tokens（命中 + 未命中）。输出 tokens 不进缓存，
        // 混进分母会把命中率压低，看起来像缓存失效了。
        let promptTokens = totals.cacheHitTokens + totals.cacheMissTokens
        let hitRate = promptTokens > 0
            ? Double(totals.cacheHitTokens) / Double(promptTokens)
            : nil

        return [
            DetailStat(label: "Output", value: UsageAmountFormatter.compactAmount(totals.outputTokens)),
            DetailStat(label: "Cache hit", value: UsageAmountFormatter.compactAmount(totals.cacheHitTokens)),
            DetailStat(label: "Cache miss", value: UsageAmountFormatter.compactAmount(totals.cacheMissTokens)),
            DetailStat(label: "Hit rate", value: hitRate.map(percentText) ?? "—")
        ]
    }

    /// 一位小数的百分比。命中率在 97% 和 98% 之间差别很实在，整数会把它抹平。
    private static func percentText(_ ratio: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let percent = NSNumber(value: ratio * 100)
        return "\(formatter.string(from: percent) ?? "0")%"
    }

    // MARK: - table

    private static func table(_ byModel: [String: Totals]) -> DetailTable? {
        let rows = byModel
            .filter { $0.value.hasAnything }
            .sorted { lhs, rhs in
                lhs.value.tokens == rhs.value.tokens
                    ? lhs.key < rhs.key
                    : lhs.value.tokens > rhs.value.tokens
            }
        guard !rows.isEmpty else {
            return nil
        }

        let shown = rows.prefix(tableRowLimit)
        let hidden = rows.count - shown.count
        return DetailTable(
            title: "By model · this month",
            columns: ["Model", "Requests", "Tokens", "Cost"],
            rows: shown.map { name, totals in
                DetailTableRow(
                    name: name,
                    cells: [
                        UsageAmountFormatter.compactAmount(totals.requests),
                        UsageAmountFormatter.compactAmount(totals.tokens),
                        costText(totals.costByCurrency)
                    ]
                )
            },
            footnote: hidden > 0 ? "+\(hidden) more models" : nil
        )
    }

    // MARK: - 聚合

    private static func dayTotals(
        fromAmount root: [String: Any],
        allowed: Set<Date>,
        calendar: Calendar,
        into byModel: inout [String: Totals]
    ) -> [Date: Totals] {
        var byDay: [Date: Totals] = [:]
        let formatter = UsageDetailSupport.dateFormatter(calendar: calendar)
        for day in DeepSeekPayload.days(fromAmount: root) {
            guard let date = UsageDetailSupport.date(
                fromDay: DeepSeekPayload.dateText(day),
                formatter: formatter
            ), allowed.contains(date) else {
                continue
            }
            var totals = byDay[date] ?? Totals()
            for item in DeepSeekPayload.items(inDay: day) {
                var model = Totals()
                model.requests = DeepSeekPayload.intAmount(in: item, type: "REQUEST")
                model.outputTokens = DeepSeekPayload.intAmount(in: item, type: "RESPONSE_TOKEN")
                model.cacheHitTokens = DeepSeekPayload.intAmount(in: item, type: "PROMPT_CACHE_HIT_TOKEN")
                model.cacheMissTokens = DeepSeekPayload.intAmount(in: item, type: "PROMPT_CACHE_MISS_TOKEN")
                totals.add(tokens: model)

                let name = modelName(from: item)
                var known = byModel[name] ?? Totals()
                known.add(tokens: model)
                byModel[name] = known
            }
            byDay[date] = totals
        }
        return byDay
    }

    private static func dayCosts(
        fromCost root: [String: Any],
        allowed: Set<Date>,
        calendar: Calendar,
        into byModel: inout [String: Totals]
    ) -> [Date: Totals] {
        var byDay: [Date: Totals] = [:]
        let formatter = UsageDetailSupport.dateFormatter(calendar: calendar)
        for currency in DeepSeekPayload.costCurrencies(fromCost: root) {
            for day in currency.days {
                guard let date = UsageDetailSupport.date(
                    fromDay: DeepSeekPayload.dateText(day),
                    formatter: formatter
                ), allowed.contains(date) else {
                    continue
                }
                var totals = byDay[date] ?? Totals()
                for item in DeepSeekPayload.items(inDay: day) {
                    let amount = DeepSeekPayload.sumAmounts(in: item)
                    totals.costByCurrency[currency.currency, default: Decimal(0)] += amount

                    let name = modelName(from: item)
                    var known = byModel[name] ?? Totals()
                    known.costByCurrency[currency.currency, default: Decimal(0)] += amount
                    byModel[name] = known
                }
                byDay[date] = totals
            }
        }
        return byDay
    }

    private static func merge(_ source: [String: Totals], into target: inout [String: Totals]) {
        for (key, totals) in source {
            var existing = target[key] ?? Totals()
            existing.add(tokens: totals)
            target[key] = existing
        }
    }

    private static func merge(_ source: [Date: Totals], into target: inout [Date: Totals]) {
        for (key, totals) in source {
            var existing = target[key] ?? Totals()
            existing.add(tokens: totals)
            target[key] = existing
        }
    }

    private static func modelName(from item: [String: Any]) -> String {
        DeepSeekPayload.modelName(in: item) ?? unknownModelName
    }

    private static func money(_ amount: Decimal, currency: String) -> String {
        "\(UsageAmountFormatter.moneyText(amount)) \(currency)"
    }
}
