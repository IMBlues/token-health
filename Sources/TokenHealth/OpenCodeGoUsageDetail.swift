import Foundation

/// Turns one console envelope into the `UsageDetail` the pinned-item popover draws.
///
/// Never throws: an unparseable envelope returns nil and the popover falls back to its error
/// line. A single failed console call only removes that section — the meters still render.
enum OpenCodeGoUsageDetail {
    static let tableRowLimit = 6
    static let unknownModelName = "Unknown model"

    /// Headline rows, in window order. Labels are the card's copy, not `UsageWindow.title`.
    static let windowLabels: [(window: UsageWindow, label: String)] = [
        (.fiveHours, "5 hours"),
        (.week, "Week"),
        (.month, "Month")
    ]

    private struct Totals: Equatable {
        var requests = 0
        var tokens = 0
        var costMicroCents = 0

        mutating func add(_ other: Totals) {
            add(requests: other.requests, tokens: other.tokens, costMicroCents: other.costMicroCents)
        }

        mutating func add(requests: Int = 0, tokens: Int = 0, costMicroCents: Int = 0) {
            self.requests = UsageDetailSupport.saturatingAdd(self.requests, requests)
            self.tokens = UsageDetailSupport.saturatingAdd(self.tokens, tokens)
            self.costMicroCents = UsageDetailSupport.saturatingAdd(self.costMicroCents, costMicroCents)
        }
    }

    static func make(bundle: Data, usages: [TokenUsage], today: Date) -> UsageDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: bundle) as? [String: Any] else {
            return nil
        }

        var detail = UsageDetail()
        detail.headline = headline(from: usages)

        let calendar = UsageDetailSupport.utcCalendar()
        let dayRange = UsageDetailSupport.trailingDayList(today: today, calendar: calendar)
        if let rows = root["usageByDay"] as? [[String: Any]], !dayRange.isEmpty {
            let byDay = dayTotals(from: rows, allowed: Set(dayRange), calendar: calendar)
            detail.groups = groups(dayRange: dayRange, byDay: byDay)
            detail.series = series(dayRange: dayRange, byDay: byDay, calendar: calendar)
        }
        if let summary = root["usageSummary"] as? [String: Any] {
            detail.breakdown = breakdown(summary)
        }
        if let models = root["usageModels"] as? [String: Any],
           let items = models["items"] as? [[String: Any]] {
            detail.table = table(items)
        }

        return detail.isEmpty ? nil : detail
    }

    // MARK: - headline

    private static func headline(from usages: [TokenUsage]) -> [DetailStat] {
        windowLabels.compactMap { window, label in
            guard let usage = usages.first(where: { $0.window == window }),
                  let value = usage.displayValue, !value.isEmpty else {
                return nil
            }
            return DetailStat(label: label, value: value, ratio: usage.ratio)
        }
    }

    // MARK: - groups

    private static func groups(dayRange: [Date], byDay: [Date: Totals]) -> [DetailGroup] {
        guard let today = dayRange.last else {
            return []
        }

        let todayTotals = byDay[today] ?? Totals()
        var last7 = Totals()
        var last30 = Totals()
        for (index, date) in dayRange.enumerated() {
            let totals = byDay[date] ?? Totals()
            last30.add(totals)
            if index >= dayRange.count - 7 {
                last7.add(totals)
            }
        }

        return [
            DetailGroup(title: "Today", values: values(todayTotals)),
            DetailGroup(title: "7 days", values: values(last7)),
            DetailGroup(title: "30 days", values: values(last30))
        ]
    }

    private static func values(_ totals: Totals) -> [DetailStat] {
        [
            DetailStat(label: "Requests", value: UsageAmountFormatter.compactAmount(totals.requests)),
            DetailStat(label: "Tokens", value: UsageAmountFormatter.compactAmount(totals.tokens)),
            DetailStat(label: "Cost", value: OpenCodeGoUsageParser.dollarsText(totals.costMicroCents))
        ]
    }

    // MARK: - series

    private static func series(dayRange: [Date], byDay: [Date: Totals], calendar: Calendar) -> DetailSeries {
        let points = dayRange.map { date in
            DetailSeriesPoint(date: date, value: OpenCodeGoUsageParser.dollars(byDay[date]?.costMicroCents ?? 0))
        }
        let formatter = UsageDetailSupport.axisDateFormatter(calendar: calendar)
        return DetailSeries(
            title: "Cost · last 30 days",
            points: points,
            axisStart: dayRange.first.map { formatter.string(from: $0) } ?? "",
            axisEnd: dayRange.last.map { formatter.string(from: $0) } ?? "",
            emptyText: "No usage in the last 30 days"
        )
    }

    // MARK: - breakdown

    private static func breakdown(_ summary: [String: Any]) -> [DetailStat] {
        // The two cache-write windows are one line; folded through `Totals` so a hostile pair of
        // near-`Int.max` fields saturates instead of trapping.
        var cacheWrite = Totals()
        cacheWrite.add(tokens: intValue(summary["totalCacheWrite5mTokens"]) ?? 0)
        cacheWrite.add(tokens: intValue(summary["totalCacheWrite1hTokens"]) ?? 0)
        return [
            DetailStat(label: "Input", value: UsageAmountFormatter.compactAmount(intValue(summary["totalInputTokens"]) ?? 0)),
            DetailStat(label: "Output", value: UsageAmountFormatter.compactAmount(intValue(summary["totalOutputTokens"]) ?? 0)),
            DetailStat(label: "Cache read", value: UsageAmountFormatter.compactAmount(intValue(summary["totalCacheReadTokens"]) ?? 0)),
            DetailStat(label: "Cache write", value: UsageAmountFormatter.compactAmount(cacheWrite.tokens))
        ]
    }

    // MARK: - table

    private static func table(_ items: [[String: Any]]) -> DetailTable? {
        var byModel: [String: Totals] = [:]
        for item in items {
            let name = modelName(from: item)
            var totals = byModel[name] ?? Totals()
            totals.add(
                requests: intValue(item["totalRequests"]) ?? 0,
                tokens: tokens(in: item),
                costMicroCents: intValue(item["totalCostMicroCents"]) ?? 0
            )
            byModel[name] = totals
        }

        // Rows with neither tokens nor cost are dropped: they would eat one of the six slots and
        // inflate the footnote count.
        let rows = byModel
            .filter { $0.value.tokens > 0 || $0.value.costMicroCents > 0 }
            .sorted { lhs, rhs in
                lhs.value.costMicroCents == rhs.value.costMicroCents
                    ? lhs.key < rhs.key
                    : lhs.value.costMicroCents > rhs.value.costMicroCents
            }
        guard !rows.isEmpty else {
            return nil
        }

        let shown = rows.prefix(tableRowLimit)
        let hidden = rows.count - shown.count
        return DetailTable(
            title: "By model · last 30 days",
            columns: ["Model", "Requests", "Tokens", "Cost"],
            rows: shown.map { name, totals in
                DetailTableRow(
                    name: name,
                    cells: [
                        UsageAmountFormatter.compactAmount(totals.requests),
                        UsageAmountFormatter.compactAmount(totals.tokens),
                        OpenCodeGoUsageParser.dollarsText(totals.costMicroCents)
                    ]
                )
            },
            footnote: hidden > 0 ? "+\(hidden) more models" : nil
        )
    }

    /// The console has no total field: tokens are the sum of the five components, matching the
    /// console's own `totalTokens` getter. Folded through `Totals` so hostile values saturate
    /// instead of trapping.
    private static func tokens(in item: [String: Any]) -> Int {
        var totals = Totals()
        for key in [
            "totalInputTokens",
            "totalOutputTokens",
            "totalCacheReadTokens",
            "totalCacheWrite5mTokens",
            "totalCacheWrite1hTokens"
        ] {
            totals.add(tokens: intValue(item[key]) ?? 0)
        }
        return totals.tokens
    }

    private static func modelName(from item: [String: Any]) -> String {
        guard let name = item["model"] as? String else {
            return unknownModelName
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? unknownModelName : trimmed
    }

    // MARK: - aggregation and dates

    private static func dayTotals(
        from rows: [[String: Any]],
        allowed: Set<Date>,
        calendar: Calendar
    ) -> [Date: Totals] {
        var byDay: [Date: Totals] = [:]
        // One formatter for the whole loop: a bad response can carry tens of thousands of rows.
        let formatter = UsageDetailSupport.dateFormatter(calendar: calendar)
        for row in rows {
            guard let date = UsageDetailSupport.date(fromDay: row["date"] as? String, formatter: formatter),
                  allowed.contains(date) else {
                continue
            }
            var totals = byDay[date] ?? Totals()
            totals.add(
                requests: intValue(row["totalRequests"]) ?? 0,
                tokens: intValue(row["totalTokens"]) ?? 0,
                costMicroCents: intValue(row["totalCostMicroCents"]) ?? 0
            )
            byDay[date] = totals
        }
        return byDay
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            guard double.isFinite, let converted = Int(exactly: double.rounded(.towardZero)) else {
                return nil
            }
            return converted
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}
