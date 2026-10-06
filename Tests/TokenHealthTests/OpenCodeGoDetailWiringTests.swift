import Foundation
import Testing
@testable import TokenHealth

struct OpenCodeGoDetailWiringTests {
    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    private func config(auth: AuthMode) -> ServiceConfig {
        ServiceConfig(displayName: "OpenCode Go", providerKind: .openCodeGo, authMode: auth)
    }

    /// 一份完整的信封：新形状额度 + 三份用量响应。
    private var bundle: Data {
        Data(#"""
        {
          "ok": true, "status": 200, "text": "", "hasSession": true,
          "goStatus": { "access": { "endsAt": "2026-10-01T00:00:00.000Z", "meters": {
            "fiveHour": { "limitMicroCents": 1200000000, "usedMicroCents": 32000000 },
            "week": { "limitMicroCents": 3000000000, "usedMicroCents": 95000000 },
            "month": { "limitMicroCents": 6000000000, "usedMicroCents": 222000000 }
          } } },
          "workspaceId": "wrk_1",
          "usageSummary": { "totalInputTokens": 44000000, "totalOutputTokens": 9000000, "totalCacheReadTokens": 33000000, "totalCacheWrite5mTokens": 1500000, "totalCacheWrite1hTokens": 500000, "totalCostMicroCents": 1986000000 },
          "usageByDay": [ { "date": "2026-09-25", "totalRequests": 12, "totalTokens": 1200000, "totalCostMicroCents": 41000000 } ],
          "usageModels": { "items": [ { "model": "claude-sonnet-5", "provider": "anthropic", "totalRequests": 402, "totalInputTokens": 20000000, "totalOutputTokens": 3000000, "totalCacheReadTokens": 18000000, "totalCacheWrite5mTokens": 100000, "totalCacheWrite1hTokens": 100000, "totalCostMicroCents": 819000000 } ] }
        }
        """#.utf8)
    }

    @Test
    func aConsoleEnvelopeProducesAReadySnapshotWithDetail() throws {
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundle,
            accountName: "blues",
            today: today
        )

        #expect(snapshot.state == .ready)
        // The access.meters shape carries no price, so the parser pins the plan name to "Go";
        // accountName is only the fallback for shapes that have no plan name at all.
        #expect(snapshot.planName == "Go")
        #expect(snapshot.usages.map(\.window) == [.fiveHours, .week, .month])

        let detail = try #require(snapshot.detail)
        #expect(detail.headline.map(\.value) == ["$0.32 / $12.00", "$0.95 / $30.00", "$2.22 / $60.00"])
        #expect(detail.series?.points.count == 30)
    }

    @Test
    func headlineMatchesTheSnapshotsQuotaUsages() throws {
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundle,
            accountName: nil,
            today: today
        )

        let quota = snapshot.usages.filter { [.fiveHours, .week, .month].contains($0.window) }
        let detail = try #require(snapshot.detail)
        #expect(detail.headline.count == 3)
        #expect(detail.headline.count == quota.count, "headline 就是那三条额度，不该另解析一遍")
        #expect(detail.headline.map(\.value) == quota.compactMap(\.displayValue))
    }

    @Test
    func aMalformedEnvelopeStillYieldsAnUnavailableSnapshot() {
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: Data("not json".utf8),
            accountName: nil,
            today: today
        )

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.detail == nil)
    }

    @Test
    func anEnvelopeWithNoUsableMetersSaysNotSubscribed() {
        let noMeters = Data(#"{"ok":true,"goStatus":{"access":{"meters":{}}}}"#.utf8)
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: noMeters,
            accountName: nil,
            today: today
        )

        #expect(snapshot.state == .unavailable)
        // parser 的 not-subscribed 文案只有走这一层才会变成用户看得见的状态行。
        #expect(snapshot.statusMessage.contains("not subscribed"))
    }

    @Test
    func usageSectionsAreAbsentWhenTheUsageKeysAreMissing() throws {
        let metersOnly = Data(#"{"ok":true,"goStatus":{"access":{"meters":{"fiveHour":{"limitMicroCents":1200000000,"usedMicroCents":32000000}}}}}"#.utf8)
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: metersOnly,
            accountName: nil,
            today: today
        )

        #expect(snapshot.state == .ready)
        let detail = try #require(snapshot.detail)
        #expect(detail.headline.count == 1)
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.tables.isEmpty)
    }
}
