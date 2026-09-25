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
