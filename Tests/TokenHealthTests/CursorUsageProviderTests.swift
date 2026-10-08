import Foundation
import Testing
@testable import TokenHealth

@Suite
struct CursorUsageProviderTests {
    @Test
    func mapsMonthlyAutoAndAPIPools() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "billingCycleStart": "2026-07-30T07:13:20.000Z",
              "billingCycleEnd": "2026-08-30T07:13:20.000Z",
              "membershipType": "pro",
              "limitType": "user",
              "isUnlimited": false,
              "individualUsage": {
                "plan": {
                  "enabled": true,
                  "autoPercentUsed": 2.93,
                  "apiPercentUsed": 41.6,
                  "totalPercentUsed": 15.4
                }
              }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.planName == "Pro")
        #expect(
            mapped.usages.count == 2,
            "汇总里没有 grokbot 字段时不能拿 Auto 的数字顶上去：Grok Bot 有自己独立的池"
        )
        #expect(mapped.usages.map(\.window) == [.month, .month])
        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "API"])
        #expect(mapped.usages.map(\.used) == [3, 42])
        #expect(mapped.usages.map(\.limit) == [100, 100])
        #expect(mapped.usages.map(\.unit) == ["%", "%"])
        #expect(mapped.usages.compactMap(\.resetDate).count == 2)
        #expect(mapped.usages[0].resetDate == mapped.usages[1].resetDate)
    }

    @Test
    func mapsGrokbotPoolAsThirdMonthlyUsage() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "membershipType": "pro_plus",
              "individualUsage": {
                "plan": {
                  "autoPercentUsed": 12.5,
                  "apiPercentUsed": 5.2,
                  "grokbotPercentUsed": 33.7
                }
              }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.usages.count == 3)
        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "API", "Grokbot"])
        #expect(mapped.usages.map(\.used) == [13, 5, 34])
        #expect(mapped.usages.map(\.window) == [.month, .month, .month])
    }

    // MARK: - Grok Bot（独立的周池）

    @Test
    func mapsTheGrokBotWeeklyPoolFromItsOwnEndpoint() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "billingCycleEnd": "2026-10-30T07:13:20.000Z",
              "membershipType": "pro",
              "individualUsage": { "plan": { "autoPercentUsed": 9.94, "apiPercentUsed": 73.69 } }
            }
            """
        )
        let grokBot = try CursorTestSupport.decodeGrokBot(
            """
            {
              "currentPeriodStart": "2026-10-08T02:49:50.750Z",
              "nextResetTimestampUtc": "2026-10-15T02:49:50.750Z",
              "usagePercent": 12.768065,
              "hasAvailableUsage": true,
              "hasNonZeroIncludedLimit": true,
              "grokPlanLabel": "Grok Bot Plan",
              "cursorPlanName": "Pro"
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: grokBot)
        let grok = try #require(mapped.usages.last)

        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "API", "Grok Bot"])
        #expect(grok.window == .week, "Grok Bot 是周池，不是月池")
        #expect(grok.used == 13, "12.768 四舍五入到 13")
        #expect(grok.limit == 100)
        #expect(grok.unit == "%")
        #expect(
            grok.resetDate == Self.grokBotReset,
            "重置时间取 nextResetTimestampUtc，不是计费周期末"
        )
    }

    @Test
    func omitsTheGrokBotPoolWhenTheAccountHasNoIncludedLimit() throws {
        let response = try CursorTestSupport.decode(
            """
            { "membershipType": "pro", "individualUsage": { "plan": { "autoPercentUsed": 9.94 } } }
            """
        )
        let grokBot = try CursorTestSupport.decodeGrokBot(
            """
            { "usagePercent": 0, "hasAvailableUsage": false, "hasNonZeroIncludedLimit": false }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: grokBot)

        #expect(
            mapped.usages.map(\.label) == ["Auto + Composer"],
            "没有 Grok Bot 额度的账号不画那一行，而不是画一根 0% 的空槽"
        )
    }

    @Test
    func theEndpointPoolIsTheOnlyGrokBotRowEvenWhenTheSummaryCarriesOne() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "membershipType": "pro",
              "individualUsage": {
                "plan": { "autoPercentUsed": 9.94, "grokbotPercentUsed": 33.7 }
              }
            }
            """
        )
        let grokBot = try CursorTestSupport.decodeGrokBot(
            """
            { "nextResetTimestampUtc": "2026-10-15T02:49:50.750Z", "usagePercent": 12.768065 }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: grokBot)

        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "Grok Bot"])
        #expect(
            mapped.usages.last?.resetDate == Self.grokBotReset,
            "两个来源都在时以独立的周池接口为准，不能画出两行 Grok"
        )
    }

    private static let grokBotReset = CursorTestSupport
        .date(year: 2026, month: 10, day: 15, hour: 2, minute: 49, second: 50)
        .addingTimeInterval(0.75)

    @Test
    func acceptsFlexiblePercentagesAndFormatsPlanName() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "membershipType": "pro_plus",
              "individualUsage": {
                "plan": {
                  "autoPercentUsed": "130.2",
                  "apiPercentUsed": -4
                }
              }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.planName == "Pro Plus")
        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "API"])
        #expect(mapped.usages.map(\.used) == [100, 0])
    }

    @Test
    func fallsBackToCombinedMonthlyUsageForSinglePoolPlans() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "membershipType": "enterprise",
              "individualUsage": {
                "plan": {
                  "totalPercentUsed": 27.4
                }
              }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.planName == "Enterprise")
        #expect(mapped.usages.map(\.label) == ["Included usage"])
        #expect(mapped.usages.map(\.used) == [27])
    }

    @Test
    func rejectsUsageResponsesWithoutAnyPool() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "membershipType": "pro",
              "individualUsage": {
                "plan": {
                  "enabled": true
                }
              }
            }
            """
        )

        #expect(throws: CursorUsageError.self) {
            try CursorUsageMapper.map(response, grokBot: nil)
        }
    }

    @Test(.enabled(if: CursorTestSupport.liveCursorCheckEnabled))
    func readsLiveCursorMonthlyPools() async throws {
        let mapped = try await CursorTestSupport.fetchLiveUsage()

        #expect(mapped.usages.contains { $0.label == "Auto + Composer" })
        #expect(mapped.usages.contains { $0.label == "API" })
    }

    /// 走的就是 App 的真实请求：`GetSandUsageStatus` 带 bearer token。
    @Test(.enabled(if: CursorTestSupport.liveCursorCheckEnabled))
    func readsTheLiveGrokBotWeeklyPool() async throws {
        let grokBot = try await CursorTestSupport.fetchLiveGrokBot()

        #expect(grokBot.usagePercent != nil, "本机账号有 Grok Bot 池，取不到说明端点或凭据变了")
        #expect(grokBot.nextResetTimestampUtc != nil)
    }

    // MARK: - 周期与花费

    @Test
    func mapsTheBillingCycleAndTheSpendBreakdown() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "billingCycleStart": "2026-08-30T07:13:20.000Z",
              "billingCycleEnd": "2026-09-30T07:13:20.000Z",
              "membershipType": "pro",
              "individualUsage": {
                "plan": {
                  "autoPercentUsed": 94.87,
                  "apiPercentUsed": 100,
                  "breakdown": { "included": 2000, "bonus": 43019, "total": 45019 }
                }
              }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.billingCycleStart == CursorTestSupport.date(year: 2026, month: 8, day: 30, hour: 7, minute: 13, second: 20))
        #expect(mapped.billingCycleEnd == CursorTestSupport.date(year: 2026, month: 9, day: 30, hour: 7, minute: 13, second: 20))
        #expect(mapped.breakdown?.included == 2000)
        #expect(mapped.breakdown?.bonus == 43019)
        #expect(mapped.breakdown?.total == 45019)
    }

    @Test
    func toleratesAMissingCycleAndBreakdown() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "membershipType": "pro",
              "individualUsage": { "plan": { "autoPercentUsed": 2.93 } }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.billingCycleStart == nil)
        #expect(mapped.billingCycleEnd == nil)
        #expect(mapped.breakdown == nil, "老响应没有 breakdown 就整段不画，不该让整次映射失败")
    }

    @Test
    func toleratesAnUnparseableCycleDate() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "billingCycleStart": "whenever",
              "billingCycleEnd": "2026-09-30T07:13:20.000Z",
              "membershipType": "pro",
              "individualUsage": { "plan": { "autoPercentUsed": 2.93 } }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.billingCycleStart == nil)
        #expect(mapped.billingCycleEnd != nil)
    }

    @Test
    func aBreakdownOfTheWrongShapeOnlyCostsTheSpendRows() throws {
        let response = try CursorTestSupport.decode(
            """
            {
              "membershipType": "pro",
              "individualUsage": {
                "plan": { "autoPercentUsed": 2.93, "breakdown": "nope" }
              }
            }
            """
        )

        let mapped = try CursorUsageMapper.map(response, grokBot: nil)

        #expect(mapped.breakdown == nil)
        #expect(mapped.usages.map(\.label) == ["Auto + Composer"], "额度照常")
    }

    // MARK: - 快照

    @Test
    func snapshotCarriesTheDetailBuiltFromTheDailySpend() throws {
        let mapped = try CursorUsageMapper.map(CursorTestSupport.decode(
            """
            {
              "billingCycleEnd": "2026-09-30T07:13:20.000Z",
              "billingCycleStart": "2026-08-30T07:13:20.000Z",
              "membershipType": "pro",
              "individualUsage": {
                "plan": {
                  "autoPercentUsed": 94.87,
                  "apiPercentUsed": 100,
                  "breakdown": { "included": 2000, "bonus": 43019, "total": 45019 }
                }
              }
            }
            """
        ), grokBot: nil)
        let today = CursorTestSupport.date(year: 2026, month: 9, day: 30, hour: 12)
        let dailySpend = try JSONDecoder().decode(
            CursorDailySpendResponse.self,
            from: Data(
                """
                { "dailySpend": [
                  { "day": "\(CursorTestSupport.milliseconds(year: 2026, month: 9, day: 30))", "category": "grok-bot-default", "totalTokens": "114315895" }
                ] }
                """.utf8
            )
        )

        let snapshot = CursorUsageProvider().snapshot(
            config: ServiceConfig(displayName: "Cursor", providerKind: .cursor, authMode: .api),
            mapped: mapped,
            dailySpend: dailySpend,
            fetchedAt: today,
            today: today
        )
        let detail = try #require(snapshot.detail)

        #expect(snapshot.state == .ready)
        #expect(snapshot.planName == "Pro")
        #expect(detail.headline.map(\.label) == ["Auto + Composer", "API"])
        #expect(detail.groups.last?.values.first?.value == "114.32M")
        #expect(detail.tables.first?.rows.map(\.name) == ["grok-bot-default"])
        #expect(detail.breakdown.map(\.value) == ["$20.00", "$430.19", "$450.19", "9/30"])
    }

    @Test
    func aFailedDailySpendStillLeavesTheQuotaReady() throws {
        let mapped = try CursorUsageMapper.map(CursorTestSupport.decode(
            """
            {
              "membershipType": "pro",
              "individualUsage": { "plan": { "autoPercentUsed": 94.87 } }
            }
            """
        ), grokBot: nil)

        let snapshot = CursorUsageProvider().snapshot(
            config: ServiceConfig(displayName: "Cursor", providerKind: .cursor, authMode: .api),
            mapped: mapped,
            dailySpend: nil,
            fetchedAt: CursorTestSupport.date(year: 2026, month: 9, day: 30),
            today: CursorTestSupport.date(year: 2026, month: 9, day: 30)
        )
        let detail = try #require(snapshot.detail)

        #expect(snapshot.state == .ready)
        #expect(snapshot.usages.map(\.label) == ["Auto + Composer"])
        #expect(detail.headline.count == 1)
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.tables.isEmpty)
    }
}
