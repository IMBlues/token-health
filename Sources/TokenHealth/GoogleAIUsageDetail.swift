import Foundation

/// Turns Antigravity's quota summary and model catalogue into the `UsageDetail` the pinned-item
/// popover draws.
///
/// Never throws: a payload that cannot be read only removes the section it fed, and a detail with
/// nothing to draw is nil so the popover falls back to its error line.
enum GoogleAIUsageDetail {
    /// The two rolling pools, in the order every section lists them.
    static let windows: [(window: UsageWindow, label: String)] = [
        (.fiveHours, "5 hours"),
        (.week, "Week")
    ]

    /// How many models the popover's table names before it starts counting the rest.
    static let tableRowLimit = 8

    static func make(
        summary: Data?,
        models: Data?,
        usages: [TokenUsage],
        timeZone: TimeZone = .current
    ) -> UsageDetail? {
        var detail = UsageDetail()
        detail.headline = headline(from: usages)

        if let summary, let parsed = try? GoogleAIQuotaParser.summary(from: summary) {
            detail.groups = resetGroups(from: parsed, timeZone: timeZone)
        }
        if let models {
            detail.tables = [modelTable(GoogleAIQuotaParser.models(from: models), timeZone: timeZone)].compactMap { $0 }
        }

        return detail.isEmpty ? nil : detail
    }

    /// The same four windows the pinned menu-bar item draws bars for, named by the same helper, so
    /// the popover and the tooltip can never call one of them something else.
    private static func headline(from usages: [TokenUsage]) -> [DetailStat] {
        var seen = Set<String>()
        return UsageMetricSelection.pinnedMetrics(from: usages, kind: .googleAI).compactMap { usage in
            let label = MenuBarMetrics.shortLabel(for: usage)
            // `DetailStat.id` is the label, so two windows folding to the same name would break the
            // popover's `ForEach`. Keep the first.
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

    /// One grid row per model group, columns being the two pools. The headline already answered
    /// "how much is left", so these cells answer the other question a quota raises: when it comes
    /// back. A group missing a pool still gets a cell, or the grid's columns would slide out from
    /// under the header.
    private static func resetGroups(from summary: GoogleAIQuotaSummary, timeZone: TimeZone) -> [DetailGroup] {
        summary.groups.map { group in
            DetailGroup(
                title: GoogleAIQuotaSummary.shortTitle(group.title),
                values: windows.map { window, label in
                    let bucket = group.buckets.first { $0.window == window }
                    return DetailStat(label: label, value: resetText(bucket?.resetDate, timeZone: timeZone))
                }
            )
        }
    }

    private static func modelTable(_ models: [GoogleAIModelQuota], timeZone: TimeZone) -> DetailTable? {
        guard !models.isEmpty else {
            return nil
        }

        let shown = models.prefix(tableRowLimit)
        return DetailTable(
            title: "By model",
            columns: ["Model", "Used", "Resets"],
            rows: shown.map { model in
                DetailTableRow(
                    name: model.displayName,
                    cells: [
                        // The app reads "used" everywhere — the bars, the headline — so the table
                        // flips the endpoint's "left" rather than making the reader do it.
                        MenuBarMetrics.percentText(1 - model.remainingFraction),
                        resetText(model.resetDate, timeZone: timeZone)
                    ]
                )
            },
            footnote: models.count > tableRowLimit
                ? "+\(models.count - tableRowLimit) more models"
                : nil
        )
    }

    /// A reset is an instant, not a day bucket, so it is shown in the reader's own time zone:
    /// `2026-10-16T12:03:07Z` is 20:03 on this machine, and printing the UTC reading would send
    /// someone back to check a quota eight hours early.
    private static func resetText(_ date: Date?, timeZone: TimeZone) -> String {
        guard let date else {
            return "—"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}
