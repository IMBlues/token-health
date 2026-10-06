import Foundation
import Testing
@testable import TokenHealth

struct UsageDetailSupportTests {
    private let calendar = UsageDetailSupport.utcCalendar()

    private func instant(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: text))
    }

    private func date(_ text: String) throws -> Date {
        try #require(UsageDetailSupport.dateFormatter(calendar: calendar).date(from: text))
    }

    @Test
    func windowStartsOnTheFirstOfTheMonthAndEndsTomorrow() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-09-24T13:45:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-09-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2026-09-25").timeIntervalSince1970), "上界排他，覆盖到今天整天")
    }

    @Test
    func windowOnTheFirstSpansOneDay() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-09-01T00:00:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-09-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2026-09-02").timeIntervalSince1970))
    }

    @Test
    func windowCrossesTheYearBoundary() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-12-31T23:59:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-12-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2027-01-01").timeIntervalSince1970))
    }

    @Test
    func windowAtAMonthEndRollsIntoTheNextMonth() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-01-31T12:00:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-01-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2026-02-01").timeIntervalSince1970))
    }
}
