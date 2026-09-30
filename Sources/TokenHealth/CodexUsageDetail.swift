import Foundation

/// Turns one account usage response plus the snapshot's quota usages into the `UsageDetail` the
/// pinned-item popover draws.
///
/// Never throws: a missing response or a missing field only removes the matching section, and a
/// detail with nothing to draw is nil so the popover falls back to its error line.
enum CodexUsageDetail {
    static let resetRowLimit = 6

    static func make(
        usage: CodexAccountUsageResponse?,
        resetCredits: CodexResetCreditsSummary?,
        usages: [TokenUsage],
        today: Date
    ) -> UsageDetail? {
        var detail = UsageDetail()
        detail.headline = headline(from: usages)

        // `nil` means the usage read failed or an old backend omits it: no window to draw.
        // An empty array means "no usage in these 30 days" and draws zero rows.
        if let buckets = usage?.dailyUsageBuckets {
            let calendar = UsageDetailSupport.utcCalendar()
            let dayRange = UsageDetailSupport.trailingDayList(today: today, calendar: calendar)
            if !dayRange.isEmpty {
                let byDay = dayTotals(from: buckets, allowed: Set(dayRange), calendar: calendar)
                detail.groups = groups(dayRange: dayRange, byDay: byDay)
                detail.series = series(dayRange: dayRange, byDay: byDay, calendar: calendar)
            }
        }
        detail.breakdown = breakdown(usage?.summary)
        detail.table = resetCardTable(resetCredits)

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
            return DetailStat(
                label: label,
                value: UsageAmountFormatter.exactAmountText(usage),
                ratio: usage.ratio
            )
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
            last30 = UsageDetailSupport.saturatingAdd(last30, tokens)
            if index >= dayRange.count - 7 {
                last7 = UsageDetailSupport.saturatingAdd(last7, tokens)
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
        let formatter = UsageDetailSupport.axisDateFormatter(calendar: calendar)
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
        // One formatter for the whole loop: a bad response can carry tens of thousands of buckets.
        let formatter = UsageDetailSupport.dateFormatter(calendar: calendar)
        for bucket in buckets {
            // A bucket missing its date or its tokens — or carrying a negative count, which is bad
            // data rather than a small day — is dropped, not counted as zero.
            guard let tokens = bucket.tokens, tokens >= 0,
                  let date = UsageDetailSupport.date(fromDay: bucket.startDate, formatter: formatter),
                  allowed.contains(date) else {
                continue
            }
            byDay[date] = UsageDetailSupport.saturatingAdd(byDay[date] ?? 0, Int(clamping: tokens))
        }
        return byDay
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

    // MARK: - reset cards

    /// The reset cards the account can spend to clear a rate limit. A card's deadline is a
    /// wall-clock moment for the person reading it, so it formats in the local time zone — not
    /// the UTC the day buckets are cut on. Cards are drawn soonest-first because the one closest
    /// to expiring is the one worth remembering.
    private static func resetCardTable(_ credits: CodexResetCreditsSummary?) -> DetailTable? {
        guard let credits else {
            return nil
        }

        if let cards = credits.credits, !cards.isEmpty {
            let sorted = cards.sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (left?, right?):
                    left < right
                case (nil, _?):
                    false
                case (_?, nil):
                    true
                case (nil, nil):
                    false
                }
            }
            let shown = sorted.prefix(resetRowLimit)
            // The count is authoritative: the backend may cap the detail array, so the footnote
            // has to be measured against `availableCount` rather than the array we got.
            let total = credits.availableCount ?? Int64(sorted.count)
            let hidden = total - Int64(shown.count)
            return DetailTable(
                title: "Reset cards",
                columns: ["Card", "Expires"],
                rows: shown.map { card in
                    DetailTableRow(name: resetCardName(card), cells: [expiryText(card.expiresAt)])
                },
                footnote: hidden > 0 ? "+\(hidden) more cards" : nil
            )
        }

        // The backend reported a count without details: still worth a row, but there is no
        // expiry to show.
        if let count = credits.availableCount, count > 0 {
            return DetailTable(
                title: "Reset cards",
                columns: ["Card", "Expires"],
                rows: [DetailTableRow(name: "\(count) available", cells: ["—"])],
                footnote: nil
            )
        }

        return nil
    }

    private static func resetCardName(_ card: CodexResetCredit) -> String {
        for candidate in [card.title, card.description] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "Reset"
    }

    /// `M/d` in the local time zone; `Never` for a card the backend says does not expire.
    private static func expiryText(_ expiresAt: Int64?) -> String {
        guard let expiresAt else {
            return "Never"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(expiresAt)))
    }
}
