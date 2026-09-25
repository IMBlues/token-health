import Foundation

/// Turns one console envelope into the `UsageDetail` the pinned-item popover draws.
///
/// Never throws: an unparseable envelope returns nil and the popover falls back to its error
/// line. A single failed console call only removes that section — the meters still render.
enum OpenCodeGoUsageDetail {
    static let tableRowLimit = 6
    static let unknownModelName = "Unknown model"
    static let dayFormat = "yyyy-MM-dd"
    static let axisDateFormat = "M/d"
    static let rangeDays = 30

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
            self.requests = Self.saturatingAdd(self.requests, requests)
            self.tokens = Self.saturatingAdd(self.tokens, tokens)
            self.costMicroCents = Self.saturatingAdd(self.costMicroCents, costMicroCents)
        }

        /// Saturating add: a malformed or hostile response must degrade, never trap — the builder
        /// promises not to crash on remote data.
        private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? (rhs > 0 ? Int.max : Int.min) : sum
        }
    }

    static func make(bundle: Data, usages: [TokenUsage], today: Date) -> UsageDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: bundle) as? [String: Any] else {
            return nil
        }

        var detail = UsageDetail()
        detail.headline = headline(from: usages)

        let calendar = utcCalendar()
        let dayRange = dayList(today: today, calendar: calendar)
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
            return DetailStat(label: label, value: value)
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
        let formatter = axisDateFormatter(calendar: calendar)
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
        for row in rows {
            guard let date = date(fromDay: row["date"], calendar: calendar), allowed.contains(date) else {
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

    /// `[today - 29, today]`, one entry per UTC day.
    private static func dayList(today: Date, calendar: Calendar) -> [Date] {
        let last = calendar.startOfDay(for: today)
        guard let first = calendar.date(byAdding: .day, value: -(rangeDays - 1), to: last) else {
            return []
        }

        var days: [Date] = []
        var cursor = first
        while cursor <= last {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return days
    }

    /// Parses the first 10 characters, so `"2026-09-25T00:00:00Z"` works too.
    private static func date(fromDay value: Any?, calendar: Calendar) -> Date? {
        guard let text = value as? String, text.count >= 10 else {
            return nil
        }
        return dateFormatter(calendar: calendar).date(from: String(text.prefix(10)))
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private static func dateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dayFormat
        return formatter
    }

    private static func axisDateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = axisDateFormat
        return formatter
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
