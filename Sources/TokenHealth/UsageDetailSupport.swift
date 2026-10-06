import Foundation

/// The date and aggregation helpers the detail builders share
/// (`DeepSeekUsageDetail`, `OpenCodeGoUsageDetail`, `CodexUsageDetail`, `CursorUsageDetail`).
///
/// Every window here is cut on UTC days. The backends report per-day keys as UTC dates and the
/// production path anchors on the current instant, so a local calendar would slide the whole
/// window — and every date's day — by the machine's offset. See `utcCalendar()`.
enum UsageDetailSupport {
    /// The day format the backends report. `date(fromDay:formatter:)` reads only the first 10
    /// characters, so `"2026-09-25T00:00:00Z"` works too.
    static let dayFormat = "yyyy-MM-dd"
    /// The trend chart's two edge labels.
    static let axisDateFormat = "M/d"

    /// The one calendar the detail windows are cut with: Gregorian, fixed to UTC.
    ///
    /// Never `.current`: the anchor the production path passes is the current instant and the
    /// per-day keys are UTC dates, so a local calendar puts `startOfDay` on the local midnight
    /// and the last day of the window stops being the day the backend just reported.
    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    /// Parses a backend day string, reading only the first 10 characters.
    ///
    /// Takes a formatter rather than a calendar so callers build it once outside their bucket
    /// loop: the session cap is 2 MB, and one bad response can carry tens of thousands of
    /// buckets.
    static func date(fromDay text: String?, formatter: DateFormatter) -> Date? {
        guard let text, text.count >= 10 else {
            return nil
        }
        return formatter.date(from: String(text.prefix(10)))
    }

    /// `[today - (rangeDays - 1), today]`, one entry per UTC day.
    static func trailingDayList(today: Date, rangeDays: Int = 30, calendar: Calendar) -> [Date] {
        let last = calendar.startOfDay(for: today)
        guard let first = calendar.date(byAdding: .day, value: -(rangeDays - 1), to: last) else {
            return []
        }
        return dayList(from: first, through: last, calendar: calendar)
    }

    /// The first of `day`'s month through `day` itself, one entry per UTC day.
    ///
    /// `day` is a backend `yyyy-MM-dd` string rather than a `Date` because that is the shape the
    /// period arrives in; an unparseable one yields no days at all.
    static func monthToDateDayList(day: String, calendar: Calendar) -> [Date] {
        guard let today = dateFormatter(calendar: calendar).date(from: day) else {
            return []
        }
        let components = calendar.dateComponents([.year, .month], from: today)
        guard let first = calendar.date(
            from: DateComponents(year: components.year, month: components.month, day: 1)
        ) else {
            return []
        }
        return dayList(from: first, through: today, calendar: calendar)
    }

    /// `[本月 1 日 00:00, 明日 00:00)` 的 unix 秒窗口，上界排他（覆盖到今天整天）。
    ///
    /// 给 by_api_key 那两个只认 `start`/`end`/`tz` 的端点用。`end` 取明日而不是今天，
    /// 是因为接口把 `end` 当排他上界 —— 传今天零点会把今天一整天切掉。
    /// 算不出日期时返回 nil，调用方据此放弃这次可选请求。
    static func monthToDateWindow(now: Date, calendar: Calendar) -> (start: Int, end: Int)? {
        let today = calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.year, .month], from: today)
        guard let first = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return nil
        }
        return (start: Int(first.timeIntervalSince1970), end: Int(tomorrow.timeIntervalSince1970))
    }

    /// `first ... last`, both ends included, one entry per day; empty when `last` precedes `first`.
    ///
    /// Both ends are snapped to `startOfDay` first: the Cursor billing cycle arrives with a time
    /// of day, and an un-snapped start would key the window's first day at 07:13 while the
    /// per-day data keys it at midnight — the day would silently drop out of the list.
    static func dayList(from first: Date, through last: Date, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: first)
        let end = calendar.startOfDay(for: last)
        while cursor <= end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return days
    }

    static func dateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dayFormat
        return formatter
    }

    static func axisDateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = dateFormatter(calendar: calendar)
        formatter.dateFormat = axisDateFormat
        return formatter
    }

    /// Saturating add: a malformed or hostile response must degrade, never trap — the builders
    /// promise not to crash on remote data.
    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs > 0 ? Int.max : Int.min) : sum
    }
}
