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

        let mapped = try CursorUsageMapper.map(response)

        #expect(mapped.planName == "Pro")
        #expect(mapped.usages.count == 3)
        #expect(mapped.usages.map(\.window) == [.month, .month, .month])
        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "API", "Grokbot (included in Auto)"])
        #expect(mapped.usages.map(\.used) == [3, 42, 3])
        #expect(mapped.usages.map(\.limit) == [100, 100, 100])
        #expect(mapped.usages.map(\.unit) == ["%", "%", "%"])
        #expect(mapped.usages.compactMap(\.resetDate).count == 3)
        #expect(mapped.usages[0].resetDate == mapped.usages[1].resetDate)
        #expect(mapped.usages[0].resetDate == mapped.usages[2].resetDate)
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

        let mapped = try CursorUsageMapper.map(response)

        #expect(mapped.usages.count == 3)
        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "API", "Grokbot"])
        #expect(mapped.usages.map(\.used) == [13, 5, 34])
        #expect(mapped.usages.map(\.window) == [.month, .month, .month])
    }

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

        let mapped = try CursorUsageMapper.map(response)

        #expect(mapped.planName == "Pro Plus")
        #expect(mapped.usages.map(\.label) == ["Auto + Composer", "API", "Grokbot (included in Auto)"])
        #expect(mapped.usages.map(\.used) == [100, 0, 100])
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

        let mapped = try CursorUsageMapper.map(response)

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
            try CursorUsageMapper.map(response)
        }
    }

    @Test(.enabled(if: CursorTestSupport.liveCursorCheckEnabled))
    func readsLiveCursorMonthlyPools() async throws {
        let mapped = try await CursorTestSupport.fetchLiveUsage()

        #expect(mapped.usages.contains { $0.label == "Auto + Composer" })
        #expect(mapped.usages.contains { $0.label == "API" })
    }
}
