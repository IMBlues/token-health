import Foundation

/// Turns one usage-summary mapping plus one daily-spend response into the `UsageDetail` the
/// pinned-item popover draws.
///
/// Never throws: a missing response or a missing field only removes the matching section, and a
/// detail with nothing to draw is nil so the popover falls back to its error line.
enum CursorUsageDetail {
    static let tableRowLimit = 6
    /// The one substring that decides what counts as Grok bot usage. Cursor reports the pool as
    /// `grok-bot-default` / `grok-bot-automation` and the Grok models inside the Auto bucket as
    /// `cursor-grok-4.6-high` / `grok-4.7-high`; the card is about the pool, so both spellings
    /// count and the row names stay exactly as Cursor wrote them.
    static let grokModelNeedle = "grok"
    /// How many days the rolling window covers, and the shortest window the dated sections are
    /// ever cut with. A billing cycle younger than this falls back to the rolling window:
    /// cutting to a day-old cycle draws a single full-width bar under a `9/30 … 9/30` axis,
    /// which reads as a broken chart rather than as a cycle that just started.
    static let minimumRangeDays = 30
    /// The `Today` row's neighbours: `[today - 6, today]`.
    static let trailingWeekDays = 7

    /// The window every dated section is cut with, and the range the daily-spend request asks
    /// for. Both come from one value so the request and the sections can never disagree.
    struct Window: Equatable, Sendable {
        /// First day of the window, UTC midnight.
        var start: Date
        /// Last day of the window, UTC midnight. Never past today.
        var end: Date
        /// True when the window is the billing cycle itself, false when it is the rolling one —
        /// either because the cycle is unknown or because it is younger than `minimumRangeDays`.
        var isCycle: Bool
        /// What to ask the backend for: the window, ending at `today` (an instant, not a
        /// midnight — the request is a timestamp range).
        var fetchStart: Date
        var fetchEnd: Date
        /// One entry per UTC day of `start ... end`.
        var days: [Date]

        var groupTitle: String { isCycle ? "Billing cycle" : "30 days" }
        var seriesTitle: String { isCycle ? "Tokens · billing cycle" : "Tokens · last 30 days" }
        var seriesEmptyText: String { isCycle ? "No usage in this billing cycle" : "No usage in the last 30 days" }
        var tableTitle: String { isCycle ? "Grok bot · this cycle" : "Grok bot · last 30 days" }
    }

    /// The window and the request range for one refresh. `today` is the anchor instant; both
    /// halves of the cycle are required, because a cycle with a missing end cannot be cut.
    static func window(
        cycleStart: Date?,
        cycleEnd: Date?,
        today: Date,
        calendar: Calendar
    ) -> Window {
        let todayStart = calendar.startOfDay(for: today)
        let rollingStart = calendar.date(
            byAdding: .day,
            value: -(minimumRangeDays - 1),
            to: todayStart
        ) ?? todayStart

        var start = rollingStart
        var end = todayStart
        var isCycle = false
        if let cycleStart, let cycleEnd {
            let cycleStartStart = calendar.startOfDay(for: cycleStart)
            let cycleEndStart = calendar.startOfDay(for: cycleEnd)
            // A cycle whose end precedes its start is bad data, not a one-day cycle; a cycle
            // younger than the rolling window keeps the rolling window instead of shrinking
            // to it.
            if cycleEndStart >= cycleStartStart, cycleStartStart <= rollingStart {
                start = cycleStartStart
                end = min(cycleEndStart, todayStart)
                isCycle = true
            }
        }

        return Window(
            start: start,
            end: end,
            isCycle: isCycle,
            fetchStart: start,
            fetchEnd: max(end, today),
            days: UsageDetailSupport.dayList(from: start, through: end, calendar: calendar)
        )
    }

    static func make(
        usages: [TokenUsage],
        planBreakdown: CursorPlanBreakdown?,
        cycleStart: Date?,
        cycleEnd: Date?,
        dailySpend: CursorDailySpendResponse?,
        today: Date
    ) -> UsageDetail? {
        let calendar = UsageDetailSupport.utcCalendar()
        let window = window(cycleStart: cycleStart, cycleEnd: cycleEnd, today: today, calendar: calendar)

        var detail = UsageDetail()
        detail.headline = headline(from: usages)
        if let dailySpend, let byDay = dayTotals(from: dailySpend, calendar: calendar) {
            detail.groups = groups(window: window, byDay: byDay, today: today, calendar: calendar)
            detail.series = series(window: window, byDay: byDay, calendar: calendar)
            detail.table = table(window: window, byDay: byDay)
        }
        detail.breakdown = breakdown(planBreakdown, cycleEnd: cycleEnd, calendar: calendar)

        return detail.isEmpty ? nil : detail
    }

    // MARK: - headline

    /// The same windows the pinned menu-bar item draws bars for, formatted by the same helpers,
    /// so the popover and the tooltip can never disagree. Cursor's three pools carry their own
    /// labels (`Auto + Composer` / `API` / `Grokbot`), which is what separates them.
    private static func headline(from usages: [TokenUsage]) -> [DetailStat] {
        var seen = Set<String>()
        return UsageMetricSelection.pinnedMetrics(from: usages, kind: .cursor).compactMap { usage in
            let label = MenuBarMetrics.shortLabel(for: usage)
            // `DetailStat.id` is the label, so two pools folding to the same name would break
            // the popover's `ForEach`. Keep the first.
            guard seen.insert(label).inserted else {
                return nil
            }
            return DetailStat(
                label: label,
                value: UsageAmountFormatter.exactAmountText(usage),
                ratio: usage.ratio
            )
        }
    }

    // MARK: - groups, series and table

    private static func groups(
        window: Window,
        byDay: [Date: DayTotals],
        today: Date,
        calendar: Calendar
    ) -> [DetailGroup] {
        let todayStart = calendar.startOfDay(for: today)
        let trailingWeek = calendar.date(
            byAdding: .day,
            value: -(trailingWeekDays - 1),
            to: todayStart
        ) ?? todayStart
        let weekDays = UsageDetailSupport.dayList(from: trailingWeek, through: todayStart, calendar: calendar)

        return [
            DetailGroup(title: "Today", values: values(tokens(over: [todayStart], byDay))),
            DetailGroup(title: "7 days", values: values(tokens(over: weekDays, byDay))),
            DetailGroup(title: window.groupTitle, values: values(tokens(over: window.days, byDay)))
        ]
    }

    private static func values(_ tokens: Int) -> [DetailStat] {
        [DetailStat(label: "Tokens", value: UsageAmountFormatter.compactAmount(tokens))]
    }

    private static func series(
        window: Window,
        byDay: [Date: DayTotals],
        calendar: Calendar
    ) -> DetailSeries {
        let points = window.days.map { date in
            DetailSeriesPoint(date: date, value: Double(byDay[date]?.tokens ?? 0))
        }
        let formatter = UsageDetailSupport.axisDateFormatter(calendar: calendar)
        return DetailSeries(
            title: window.seriesTitle,
            points: points,
            axisStart: window.days.first.map { formatter.string(from: $0) } ?? "",
            axisEnd: window.days.last.map { formatter.string(from: $0) } ?? "",
            emptyText: window.seriesEmptyText
        )
    }

    /// The Grok bot rows: every model the window used whose category mentions Grok, summed over
    /// the window's days. Nothing is drawn when the account used none of them.
    private static func table(window: Window, byDay: [Date: DayTotals]) -> DetailTable? {
        var byModel: [String: Int] = [:]
        for date in window.days {
            for (model, tokens) in byDay[date]?.byModel ?? [:] where model.lowercased().contains(grokModelNeedle) {
                byModel[model] = UsageDetailSupport.saturatingAdd(byModel[model] ?? 0, tokens)
            }
        }
        guard !byModel.isEmpty else {
            return nil
        }

        // Tokens descending, ties by name: a stable order the tests can assert on.
        let rows = byModel.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        let shown = rows.prefix(tableRowLimit)
        let hidden = rows.count - shown.count
        return DetailTable(
            title: window.tableTitle,
            columns: ["Model", "Tokens"],
            rows: shown.map { name, tokens in
                DetailTableRow(name: name, cells: [UsageAmountFormatter.compactAmount(tokens)])
            },
            footnote: hidden > 0 ? "+\(hidden) more models" : nil
        )
    }

    // MARK: - breakdown

    private static func breakdown(
        _ breakdown: CursorPlanBreakdown?,
        cycleEnd: Date?,
        calendar: Calendar
    ) -> [DetailStat] {
        var stats: [DetailStat] = []
        // The three amounts are cents (20_00 = $20), and a negative one is bad data rather than
        // a credit: it drops the row instead of rendering `-$3.00`.
        if let included = nonNegative(breakdown?.included) {
            stats.append(DetailStat(label: "Included", value: dollarsText(cents: included)))
        }
        if let bonus = nonNegative(breakdown?.bonus) {
            stats.append(DetailStat(label: "Bonus", value: dollarsText(cents: bonus)))
        }
        if let total = nonNegative(breakdown?.total) {
            stats.append(DetailStat(label: "Total", value: dollarsText(cents: total)))
        }
        if let cycleEnd {
            let formatter = UsageDetailSupport.axisDateFormatter(calendar: calendar)
            stats.append(DetailStat(label: "Resets", value: formatter.string(from: cycleEnd)))
        }
        return stats
    }

    /// Cents to dollars. `moneyText` carries no unit by design, so the `$` is the caller's.
    private static func dollarsText(cents: Int) -> String {
        "$" + UsageAmountFormatter.moneyText(Decimal(cents) / 100)
    }

    private static func nonNegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else {
            return nil
        }
        return value
    }

    // MARK: - per-day aggregation

    private struct DayTotals {
        var tokens = 0
        var byModel: [String: Int] = [:]
    }

    /// `nil` when the response carried no per-day array at all — that is a failed call, and the
    /// dated sections are then not drawn. An empty array means "no usage on these days" and
    /// draws zero rows.
    private static func dayTotals(
        from response: CursorDailySpendResponse,
        calendar: Calendar
    ) -> [Date: DayTotals]? {
        guard let rows = response.dailySpend else {
            return nil
        }

        var byDay: [Date: DayTotals] = [:]
        for row in rows {
            // A row missing its day, its tokens, or its category is dropped, not counted as
            // zero: 0 is "no usage that day", a missing field is "unknown". A negative token
            // count is bad data, not a small day.
            guard let tokens = row.totalTokens, tokens >= 0,
                  let date = day(fromMilliseconds: row.dayMilliseconds, calendar: calendar),
                  let category = row.category?.trimmingCharacters(in: .whitespaces),
                  !category.isEmpty else {
                continue
            }
            let clamped = Int(clamping: tokens)
            var totals = byDay[date] ?? DayTotals()
            totals.tokens = UsageDetailSupport.saturatingAdd(totals.tokens, clamped)
            totals.byModel[category] = UsageDetailSupport.saturatingAdd(totals.byModel[category] ?? 0, clamped)
            byDay[date] = totals
        }
        return byDay
    }

    private static func tokens(over days: [Date], _ byDay: [Date: DayTotals]) -> Int {
        var total = 0
        for date in days {
            total = UsageDetailSupport.saturatingAdd(total, byDay[date]?.tokens ?? 0)
        }
        return total
    }

    /// The backend reports each day as the epoch milliseconds of its UTC midnight.
    private static func day(fromMilliseconds value: Int64?, calendar: Calendar) -> Date? {
        guard let value else {
            return nil
        }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: Double(value) / 1000))
    }
}
