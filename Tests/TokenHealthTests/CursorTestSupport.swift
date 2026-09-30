import Foundation
@testable import TokenHealth

enum CursorTestSupport {
    static var liveCursorCheckEnabled: Bool {
        ProcessInfo.processInfo.environment["TOKEN_HEALTH_LIVE_CURSOR"] == "1"
    }

    static func decode(_ json: String) throws -> CursorUsageSummary {
        try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
    }

    static func fetchLiveUsage() async throws -> CursorMappedUsage {
        let token = try CursorLocalSessionReader().readAccessToken()
        let response = try await CursorUsageClient().fetchUsage(accessToken: token)
        return try CursorUsageMapper.map(response)
    }

    /// One live refresh's worth of data: the summary mapping plus the daily read the detail needs.
    static func fetchLivePanelInputs(today: Date = Date()) async throws -> (
        mapped: CursorMappedUsage,
        dailySpend: CursorDailySpendResponse?
    ) {
        let token = try CursorLocalSessionReader().readAccessToken()
        let response = try await CursorUsageClient().fetchUsage(accessToken: token)
        let mapped = try CursorUsageMapper.map(response)
        let range = CursorUsageProvider.dailySpendRange(mapped: mapped, today: today)
        let dailySpend = try? await CursorUsageClient().fetchDailySpend(
            accessToken: token,
            periodStartMilliseconds: range.start,
            periodEndMilliseconds: range.end
        )
        return (mapped, dailySpend)
    }

    /// A fixed UTC instant, so no test races a UTC midnight or depends on the machine's zone.
    static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    /// The epoch-milliseconds spelling the daily-spend response uses for its days.
    static func milliseconds(year: Int, month: Int, day: Int) -> Int64 {
        Int64((date(year: year, month: month, day: day).timeIntervalSince1970 * 1000).rounded())
    }
}
