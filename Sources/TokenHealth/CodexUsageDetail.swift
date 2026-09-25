import Foundation

/// Turns one account usage response plus the snapshot's quota usages into the `UsageDetail` the
/// pinned-item popover draws.
///
/// Never throws: a missing response or a missing field only removes the matching section, and a
/// detail with nothing to draw is nil so the popover falls back to its error line.
enum CodexUsageDetail {
    static let dayFormat = "yyyy-MM-dd"
    static let axisDateFormat = "M/d"
    static let rangeDays = 30

    static func make(
        usage: CodexAccountUsageResponse?,
        usages: [TokenUsage],
        today: Date
    ) -> UsageDetail? {
        var detail = UsageDetail()
        detail.headline = headline(from: usages)

        // `nil` means the usage read failed or an old backend omits it: no window to draw.
        // An empty array means "no usage in these 30 days" and draws zero rows.
        if let buckets = usage?.dailyUsageBuckets {
            let calendar = utcCalendar()
            let dayRange = dayList(today: today, calendar: calendar)
            if !dayRange.isEmpty {
                let byDay = dayTotals(from: buckets, allowed: Set(dayRange), calendar: calendar)
                detail.groups = groups(dayRange: dayRange, byDay: byDay)
                detail.series = series(dayRange: dayRange, byDay: byDay, calendar: calendar)
            }
        }
        detail.breakdown = breakdown(usage?.summary)

        return detail.isEmpty ? nil : detail
    }

    // MARK: - headline

    /// The same windows the pinned menu-bar item draws bars for, formatted by the same helpers,
    /// so the popover and the tooltip can never disagree.
    private static func headline(from usages: [TokenUsage]) -> [DetailStat] {
        var seen = Set<String>()
        return UsageMetricSelection.pinnedMetrics(from: usages, kind: .codex).compactMap { usage in
            let label = MenuBarMetrics.shortLabel(for: usage)
            // `DetailStat.id` is the label, so two windows folding to the same name would break
            // the popover's `ForEach`. Keep the first.
            guard seen.insert(label).inserted else {
                return nil
            }
            return DetailStat(label: label, value: UsageAmountFormatter.exactAmountText(usage))
        }
    }

    // MARK: - groups and series

    private static func groups(dayRange: [Date], byDay: [Date: Int]) -> [DetailGroup] {
        guard let today = dayRange.last else {
            return []
        }

        var last7 = 0
        var last30 = 0
        for (index, date) in dayRange.enumerated() {
            let tokens = byDay[date] ?? 0
            last30 = saturatingAdd(last30, tokens)
            if index >= dayRange.count - 7 {
                last7 = saturatingAdd(last7, tokens)
            }
        }

        return [
            DetailGroup(title: "Today", values: values(byDay[today] ?? 0)),
            DetailGroup(title: "7 days", values: values(last7)),
            DetailGroup(title: "30 days", values: values(last30))
        ]
    }

    private static func values(_ tokens: Int) -> [DetailStat] {
        [DetailStat(label: "Tokens", value: UsageAmountFormatter.compactAmount(tokens))]
    }

    private static func series(dayRange: [Date], byDay: [Date: Int], calendar: Calendar) -> DetailSeries {
        let points = dayRange.map { date in
            DetailSeriesPoint(date: date, value: Double(byDay[date] ?? 0))
        }
        let formatter = axisDateFormatter(calendar: calendar)
        return DetailSeries(
            title: "Tokens · last 30 days",
            points: points,
            axisStart: dayRange.first.map { formatter.string(from: $0) } ?? "",
            axisEnd: dayRange.last.map { formatter.string(from: $0) } ?? "",
            emptyText: "No usage in the last 30 days"
        )
    }

    // MARK: - aggregation and dates

    private static func dayTotals(
        from buckets: [CodexAccountUsageDay],
        allowed: Set<Date>,
        calendar: Calendar
    ) -> [Date: Int] {
        var byDay: [Date: Int] = [:]
        for bucket in buckets {
            // A bucket missing its date or its tokens is dropped, not counted as zero: zero means
            // "no usage that day", a missing field means "unknown".
            guard let tokens = bucket.tokens,
                  let date = date(fromDay: bucket.startDate, calendar: calendar),
                  allowed.contains(date) else {
                continue
            }
            byDay[date] = saturatingAdd(byDay[date] ?? 0, Int(clamping: tokens))
        }
        return byDay
    }

    /// A malformed or hostile bucket must degrade, never trap — the builder promises not to crash
    /// on data it did not produce.
    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs > 0 ? Int.max : Int.min) : sum
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
    private static func date(fromDay value: String?, calendar: Calendar) -> Date? {
        guard let value, value.count >= 10 else {
            return nil
        }
        return dateFormatter(calendar: calendar).date(from: String(value.prefix(10)))
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

    // MARK: - breakdown

    private static func breakdown(_ summary: CodexAccountUsageSummary?) -> [DetailStat] {
        guard let summary else {
            return []
        }

        var stats: [DetailStat] = []
        if let lifetime = nonNegative(summary.lifetimeTokens) {
            stats.append(DetailStat(label: "Lifetime", value: UsageAmountFormatter.compactAmount(lifetime)))
        }
        if let peak = nonNegative(summary.peakDailyTokens) {
            stats.append(DetailStat(label: "Peak day", value: UsageAmountFormatter.compactAmount(peak)))
        }
        if let streak = nonNegative(summary.currentStreakDays) {
            stats.append(DetailStat(label: "Streak", value: "\(streak)d"))
        }
        if let seconds = nonNegative(summary.longestRunningTurnSec) {
            stats.append(DetailStat(label: "Longest turn", value: durationText(seconds: seconds)))
        }
        return stats
    }

    /// A negative count is bad data, not a small number: it drops the row instead of rendering
    /// `-3d`. Zero is real and stays.
    private static func nonNegative(_ value: Int64?) -> Int? {
        guard let value, value >= 0, let converted = Int(exactly: value) else {
            return nil
        }
        return converted
    }

    /// `42s` below a minute, `42m` below an hour, then `1h` / `1h 5m`.
    private static func durationText(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m"
        }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
    }
}
