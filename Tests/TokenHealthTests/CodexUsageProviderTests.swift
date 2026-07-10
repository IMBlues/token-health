import Testing
@testable import TokenHealth

@Suite
struct CodexUsageProviderTests {
    @Test
    func testQuotaRPCUsesOnlyTheReadOnlyAllowlist() throws {
        let summary = try CodexTestSupport.rpcSummary(version: "test")

        #expect(summary.methods == ["initialize", "initialized", "account/rateLimits/read"])
        #expect(CodexAppServerClient.arguments == [
            "app-server",
            "--stdio",
            "--disable", "plugins",
            "--disable", "apps",
            "-c", "analytics.enabled=false"
        ])
        #expect(summary.keySets.count == 3)
        #expect(summary.keySets[0] == ["id", "method", "params"])
        #expect(summary.keySets[1] == ["method"])
        #expect(summary.keySets[2] == ["id", "method"])
        #expect(summary.initializeParamKeys == ["clientInfo"])
        #expect(summary.clientInfoKeys == ["name", "version"])
        #expect(summary.clientName == "token_health")
        #expect(summary.clientVersion == "test")
        for forbiddenMethod in [
            "account/read",
            "account/usage/read",
            "account/login",
            "account/logout",
            "account/rateLimitResetCredit/consume",
            "account/sendAddCreditsNudgeEmail",
            "capabilities",
            "experimentalApi",
            "thread/",
            "fs/",
            "config/",
            "plugin/"
        ] {
            #expect(!summary.wireText.contains(forbiddenMethod))
        }
    }

    @Test
    func testRateLimitMappingKeepsMainAndNamedQuotaBuckets() throws {
        let fiveHourReset: Int64 = 1_783_665_814
        let weekReset: Int64 = 1_784_252_614
        let main = CodexRateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: CodexRateLimitWindow(usedPercent: 42, windowDurationMins: 300, resetsAt: fiveHourReset),
            secondary: CodexRateLimitWindow(usedPercent: 13, windowDurationMins: 10_080, resetsAt: weekReset),
            planType: "pro",
            rateLimitReachedType: nil
        )
        let spark = CodexRateLimitSnapshot(
            limitId: "codex_spark",
            limitName: "Codex Spark",
            primary: CodexRateLimitWindow(usedPercent: 7, windowDurationMins: 300, resetsAt: fiveHourReset),
            secondary: CodexRateLimitWindow(usedPercent: 2, windowDurationMins: 10_080, resetsAt: weekReset),
            planType: "pro",
            rateLimitReachedType: nil
        )

        let mapped = CodexRateLimitsMapper.map(
            CodexRateLimitsResponse(rateLimits: main, rateLimitsByLimitId: ["codex": main, "codex_spark": spark])
        )

        #expect(mapped.planName == "Pro")
        #expect(mapped.usages.count == 4)
        #expect(mapped.usages[0].window == .fiveHours)
        #expect(mapped.usages[0].label == nil)
        #expect(mapped.usages[0].used == 42)
        #expect(mapped.usages[0].limit == 100)
        #expect(mapped.usages[0].unit == "%")
        #expect(CodexTestSupport.resetTimestamp(mapped.usages[0]) == fiveHourReset)
        #expect(mapped.usages[1].window == .week)
        #expect(mapped.usages[2].label == "Codex Spark · 5h")
        #expect(mapped.usages[3].label == "Codex Spark · Week")
    }

    @Test
    func testRateLimitMappingClampsUnexpectedPercentages() {
        let limits = CodexRateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: CodexRateLimitWindow(usedPercent: 130, windowDurationMins: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: -4, windowDurationMins: 10_080, resetsAt: nil),
            planType: "unknown",
            rateLimitReachedType: "rate_limit_reached"
        )

        let mapped = CodexRateLimitsMapper.map(
            CodexRateLimitsResponse(rateLimits: limits, rateLimitsByLimitId: nil)
        )

        #expect(mapped.planName == nil)
        #expect(mapped.usages.map(\.used) == [100, 0])
        #expect(mapped.statusMessage == "Codex quota reached")
    }

    @Test
    func testRateLimitMappingUsesActualWindowDurationsAndFlexibleNumbers() throws {
        let response = try CodexTestSupport.decodeRateLimits(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 12.5,
                  "windowDurationMins": "15",
                  "resetsAt": "1783665814"
                },
                "secondary": {
                  "usedPercent": "8",
                  "windowDurationMins": 60,
                  "resetsAt": 1784252614
                }
              }
            }
            """
        )

        let mapped = CodexRateLimitsMapper.map(response)
        #expect(mapped.usages.map(\.used) == [13, 8])
        #expect(mapped.usages.map(\.label) == ["15m", "1h"])
        #expect(CodexTestSupport.resetTimestamp(mapped.usages[0]) == 1_783_665_814)
    }

    @Test
    func testRateLimitDecodingRejectsOutOfRangeNumbersWithoutTrapping() {
        #expect(CodexTestSupport.rateLimitsDecodeFails(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": "1e500",
                  "windowDurationMins": "1e500",
                  "resetsAt": "1e500"
                }
              }
            }
            """
        ))
    }

    @Test
    func testNamedOnlyBucketKeepsItsIdentityWithoutDuplication() {
        let spark = CodexRateLimitSnapshot(
            limitId: "codex_spark",
            limitName: "Codex Spark",
            primary: CodexRateLimitWindow(usedPercent: 7, windowDurationMins: 300, resetsAt: nil),
            secondary: nil,
            planType: "pro",
            rateLimitReachedType: nil
        )

        let mapped = CodexRateLimitsMapper.map(
            CodexRateLimitsResponse(rateLimits: nil, rateLimitsByLimitId: ["codex_spark": spark])
        )

        #expect(mapped.usages.count == 1)
        #expect(mapped.usages[0].label == "Codex Spark · 5h")
    }

    @Test
    func testAppServerClientIgnoresNotificationsAndReadsExpectedResponse() async throws {
        let response = try await CodexTestSupport.fetchFromFakeAppServer()
        #expect(response.rateLimits?.limitId == "codex")
        #expect(response.rateLimits?.primary?.usedPercent == 21)
        #expect(response.rateLimits?.secondary?.usedPercent == 8)
        #expect(response.rateLimits?.planType == "plus")
    }

    @Test
    func testLiveCodexQuotaWhenExplicitlyEnabled() async throws {
        guard CodexTestSupport.liveCodexCheckEnabled else {
            return
        }
        let response = try await CodexTestSupport.fetchLiveCodexQuota()
        #expect(response.rateLimits?.primary != nil || response.rateLimits?.secondary != nil)
    }

    @Test
    func testConfigStoreMigratesToV2WithoutOverwritingV1() throws {
        let result = try CodexTestSupport.configMigrationResult()
        #expect(result.loadedLegacy)
        #expect(result.preservedLegacy)
        #expect(result.loadedCurrent)
        #expect(result.usesLocalLogin)
        #expect(!result.usesWebSession)
    }
}
