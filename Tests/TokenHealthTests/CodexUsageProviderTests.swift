import Foundation
import Testing
@testable import TokenHealth

@Suite
struct CodexUsageProviderTests {
    @Test
    func testGenericHTTPParsesWrappedTotalTokenQuota() throws {
        let data = Data(
            """
            {
              "code": true,
              "data": {
                "expires_at": 0,
                "name": "Example User",
                "object": "token_usage",
                "total_available": 298665817,
                "total_granted": 300803492,
                "total_used": 2137675,
                "unlimited_quota": false
              },
              "message": "ok"
            }
            """.utf8
        )

        let payload = try UsageJSONParser().parsePayload(data: data)

        #expect(payload.planName == "Example User")
        #expect(payload.usages.count == 1)
        #expect(payload.usages[0].window == .tokenQuota)
        #expect(payload.usages[0].label == "Usage")
        #expect(payload.usages[0].used == 2_137_675)
        #expect(payload.usages[0].limit == 300_803_492)
        #expect(payload.usages[0].resetDate == nil)
        #expect(payload.usages[0].unit == "tokens")
    }

    @Test
    func testGenericHTTPInfersTotalFromUsedAndAvailable() throws {
        let data = Data(
            """
            {
              "data": {
                "total_available": 80,
                "total_used": 20,
                "unlimited_quota": false
              }
            }
            """.utf8
        )

        let usage = try #require(UsageJSONParser().parse(data: data).first)

        #expect(usage.used == 20)
        #expect(usage.limit == 100)
    }

    @Test
    func testTokenQuotaUsesPercentageAndExactAmountHelp() {
        let usage = TokenUsage(
            window: .tokenQuota,
            used: 2_137_675,
            limit: 300_803_492,
            resetDate: nil,
            unit: "tokens"
        )

        #expect(UsageAmountFormatter.amountText(
            usage,
            isSensitiveAmount: false,
            revealsSensitiveAmount: false
        ) == "0.71%")
        #expect(
            UsageAmountFormatter.exactAmountText(usage)
                == "2,137,675 / 300,803,492 tokens"
        )
    }

    @Test
    func testTokenQuotaWithoutValidLimitUsesTokenAmount() {
        let missingLimit = TokenUsage(
            window: .tokenQuota,
            used: 2_137_675,
            limit: nil,
            resetDate: nil,
            unit: "tokens"
        )
        let zeroLimit = TokenUsage(
            window: .tokenQuota,
            used: 2_137_675,
            limit: 0,
            resetDate: nil,
            unit: "tokens"
        )

        #expect(UsageAmountFormatter.amountText(
            missingLimit,
            isSensitiveAmount: false,
            revealsSensitiveAmount: false
        ) == "2.14M tokens")
        #expect(UsageAmountFormatter.amountText(
            zeroLimit,
            isSensitiveAmount: false,
            revealsSensitiveAmount: false
        ) == "2.14M tokens")
    }

    @Test
    func testQuotaRPCUsesOnlyTheReadOnlyAllowlist() throws {
        let summary = try CodexTestSupport.rpcSummary(version: "test")

        #expect(summary.methods == [
            "initialize",
            "initialized",
            "account/rateLimits/read",
            "account/usage/read"
        ])
        #expect(CodexAppServerClient.arguments == [
            "app-server",
            "--stdio",
            "--disable", "plugins",
            "--disable", "apps",
            "-c", "analytics.enabled=false"
        ])
        #expect(summary.keySets.count == 4)
        #expect(summary.keySets[0] == ["id", "method", "params"])
        #expect(summary.keySets[1] == ["method"])
        #expect(summary.keySets[2] == ["id", "method"])
        #expect(summary.keySets[3] == ["id", "method"])
        #expect(summary.initializeParamKeys == ["clientInfo"])
        #expect(summary.clientInfoKeys == ["name", "version"])
        #expect(summary.clientName == "token_health")
        #expect(summary.clientVersion == "test")
        // `account/usage/read` 与 `account/rateLimits/read` 同属只读账号方法，是本次有意放行的
        // 唯一一项；其余禁用项逐字保留 —— 少一条也照样全绿，所以下面再钉一次条数。
        let forbiddenMethods = [
            "account/read",
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
        ]
        #expect(forbiddenMethods.count == 11)
        for forbiddenMethod in forbiddenMethods {
            #expect(!summary.wireText.contains(forbiddenMethod))
        }
    }

    @Test
    func decodesResetCreditsAndToleratesTheDegradedShapes() throws {
        let full = try CodexTestSupport.decodeRateLimits(#"""
        {"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[
          {"id":"RateLimitResetCredit_1","resetType":"codexRateLimits","status":"available",
           "grantedAt":1790701436,"expiresAt":1793293436,
           "title":"Full reset (Weekly + 5 hr)","description":"Thanks for using Codex!"}]}}
        """#)

        #expect(full.rateLimitResetCredits?.availableCount == 1)
        #expect(full.rateLimitResetCredits?.credits?.first?.title == "Full reset (Weekly + 5 hr)")
        #expect(full.rateLimitResetCredits?.credits?.first?.expiresAt == 1793293436)

        // 后端只给数量：明细数组为 null，数量写成字符串也认。
        let countOnly = try CodexTestSupport.decodeRateLimits(
            #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":"2"}}"#
        )
        #expect(countOnly.rateLimitResetCredits?.availableCount == 2)
        #expect(countOnly.rateLimitResetCredits?.credits == nil)

        // 整段缺席是正常的：老后端 / 没有卡。
        let absent = try CodexTestSupport.decodeRateLimits(#"{"rateLimits":{}}"#)
        #expect(absent.rateLimitResetCredits == nil)

        // expiresAt 为 null = 这张卡不过期。
        let noExpiry = try CodexTestSupport.decodeRateLimits(
            #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[{"expiresAt":null}]}}"#
        )
        #expect(noExpiry.rateLimitResetCredits?.credits?.first?.expiresAt == nil)
    }

    @Test
    func theResolverKnowsBothChatGPTLayouts() {
        let paths = CodexExecutableResolver
            .candidates(homeDirectory: URL(fileURLWithPath: "/Users/example"))
            .map(\.path)

        // 2026-09-30 的 ChatGPT.app 更新（26.928）把 codex 挪进了 codex-cli/CodexCLI.app/。
        // 只认旧路径的话，卡片会报「装官方 App 并登录」，而 App 其实装着呢 —— 这次就是这么坏的。
        // 紧挨着的 codex-cli/bin/codex 是未签名的启动脚本，不走它。
        #expect(paths.contains("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        #expect(paths.contains("/Users/example/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        // 旧布局（更早的 ChatGPT.app 与 Codex.app）仍然要找。
        #expect(paths.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        #expect(paths.contains("/Applications/Codex.app/Contents/Resources/codex"))
        #expect(paths.contains("/Users/example/Applications/Codex.app/Contents/Resources/codex"))
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
            CodexRateLimitsResponse(rateLimits: main, rateLimitsByLimitId: ["codex": main, "codex_spark": spark], rateLimitResetCredits: nil)
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
    func decodesAccountUsageWithSparseBuckets() throws {
        let json = """
        {
          "summary": {
            "lifetimeTokens": 172532345, "peakDailyTokens": "117865819",
            "longestRunningTurnSec": 2550, "currentStreakDays": 3, "longestStreakDays": 3
          },
          "dailyUsageBuckets": [
            { "startDate": "2026-06-17", "tokens": 283242 },
            { "startDate": "2026-09-23", "tokens": "117865819" }
          ]
        }
        """

        let response = try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data(json.utf8))

        // 别写成 `== 172532545 - 200`：`#expect` 遇到行内算式会把右侧推成 AnyHashable，
        // `Optional<Int64>` 与 `Int64` 各自包装后比较恒假，而两边渲染出来是同一个数字。
        #expect(response.summary?.lifetimeTokens == 172532345)
        // summary 里的数字同样宽容：fixture 里这个字段是字符串。
        #expect(response.summary?.peakDailyTokens == 117865819)
        #expect(response.summary?.longestRunningTurnSec == 2550)
        #expect(response.summary?.currentStreakDays == 3)
        // 数字写成字符串也收（console 与 RPC 都可能这么给）。
        #expect(response.dailyUsageBuckets?.map(\.tokens) == [283242, 117865819])
        #expect(response.dailyUsageBuckets?.map(\.startDate) == ["2026-06-17", "2026-09-23"])
    }

    @Test
    func accountUsageToleratesMissingAndMalformedFields() throws {
        // 整份响应里什么都不认得的键 → 三个字段全 nil，但解码本身不抛。
        let empty = try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data("{}".utf8))
        #expect(empty.summary == nil)
        #expect(empty.dailyUsageBuckets == nil)

        // 数组里混进一个非对象元素：那一条退化成「日期与 tokens 都缺」，其余照常解出来。
        let mixed = """
        { "dailyUsageBuckets": [ "nonsense", { "startDate": "2026-09-25", "tokens": 5 } ] }
        """
        let response = try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data(mixed.utf8))
        #expect(response.dailyUsageBuckets?.count == 2)
        #expect(response.dailyUsageBuckets?.first?.startDate == nil)
        #expect(response.dailyUsageBuckets?.first?.tokens == nil)
        #expect(response.dailyUsageBuckets?.last?.tokens == 5)
    }

    @Test
    func aMalformedSummaryDecodesToAllNilInsteadOfFailingTheEnvelope() throws {
        // `summary` 不是对象时不该连带把 buckets 一起丢掉：它解成一个「什么都不知道」的
        // summary（四个字段全 nil），buckets 照常。
        let response = try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data(#"""
        {"summary":"not an object","dailyUsageBuckets":[{"startDate":"2026-09-25","tokens":5}]}
        """#.utf8))

        #expect(response.summary != nil)
        #expect(response.summary?.lifetimeTokens == nil)
        #expect(response.summary?.currentStreakDays == nil)
        #expect(response.dailyUsageBuckets?.count == 1)

        // 反过来，真正让整份响应解不出的是 buckets 本身类型不对 —— 调用方那时把
        // accountUsage 当 nil（详情少画用量区块）。
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                CodexAccountUsageResponse.self,
                from: Data(#"{"dailyUsageBuckets":"not an array"}"#.utf8)
            )
        }
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
            CodexRateLimitsResponse(rateLimits: limits, rateLimitsByLimitId: nil, rateLimitResetCredits: nil)
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
            CodexRateLimitsResponse(rateLimits: nil, rateLimitsByLimitId: ["codex_spark": spark], rateLimitResetCredits: nil)
        )

        #expect(mapped.usages.count == 1)
        #expect(mapped.usages[0].label == "Codex Spark · 5h")
    }

    @Test
    func testAppServerClientIgnoresNotificationsAndReadsExpectedResponse() async throws {
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer()
        #expect(bundle.rateLimits.rateLimits?.limitId == "codex")
        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.rateLimits.rateLimits?.secondary?.usedPercent == 8)
        #expect(bundle.rateLimits.rateLimits?.planType == "plus")
        #expect(bundle.accountUsage?.summary?.currentStreakDays == 3)
    }

    @Test
    func testLiveCodexQuotaWhenExplicitlyEnabled() async throws {
        guard CodexTestSupport.liveCodexCheckEnabled else {
            return
        }
        let bundle = try await CodexTestSupport.fetchLiveCodexQuota()
        #expect(bundle.rateLimits.rateLimits?.primary != nil || bundle.rateLimits.rateLimits?.secondary != nil)
    }

    @Test
    func rejectedUsageReadOnlyDropsTheUsageHalf() async throws {
        // 老版本 Codex 不认识这个方法，会回 -32601。
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            CodexTestSupport.fakeQuotaReply,
            #"{"id":2,"error":{"code":-32601,"message":"Method not found"}}"#
        ])

        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.accountUsage == nil)
    }

    @Test
    func unreadableUsageResultOnlyDropsTheUsageHalf() async throws {
        // buckets 不是数组 → 整份用量响应解不出（`summary` 类型不对不会走到这里，它只是解成
        // 四个字段全 nil，见 Task 1 的 `aMalformedSummaryDecodesToAllNilInsteadOfFailingTheEnvelope`）。
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            CodexTestSupport.fakeQuotaReply,
            #"{"id":2,"result":{"dailyUsageBuckets":"not an array"}}"#
        ])

        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.accountUsage == nil)
    }

    @Test
    func unreadableQuotaResultFailsTheFetch() async throws {
        do {
            _ = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
                #"{"id":1,"result":{"rateLimits":"not an object"}}"#,
                CodexTestSupport.fakeUsageReply
            ])
            Issue.record("expected an invalidResponse error")
        } catch let error as CodexAppServerError {
            guard case .invalidResponse = error else {
                Issue.record("expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func anUnansweredUsageReadTimesTheSessionOut() async throws {
        // 只回 id=1：会话等不齐就只能在超时上结束，整次取数失败 —— 与「有应答但报错」不是一回事。
        do {
            _ = try await CodexTestSupport.fetchFromFakeAppServer(
                replies: [CodexTestSupport.fakeQuotaReply],
                timeout: 2
            )
            Issue.record("expected a timeout error")
        } catch let error as CodexAppServerError {
            guard case .timeout = error else {
                Issue.record("expected .timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func aServerInitiatedRequestWithACollidingIdIsNotMistakenForAReply() async throws {
        // 服务端主动发来的请求同样带 id：只按 id 匹配会把它吃成额度应答，随后解不出 →
        // 整次刷新失败。靠「应答必带 result / error」把它排除掉。
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            #"{"method":"item/commandExecution/requestApproval","id":1,"params":{}}"#,
            CodexTestSupport.fakeQuotaReply,
            CodexTestSupport.fakeUsageReply
        ])

        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.accountUsage?.summary?.currentStreakDays == 3)
    }

    @Test
    func aNumericStringResponseIdStillCounts() async throws {
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            CodexTestSupport.fakeQuotaReply.replacingOccurrences(of: #""id":1"#, with: #""id":"1""#),
            CodexTestSupport.fakeUsageReply.replacingOccurrences(of: #""id":2"#, with: #""id":"2""#)
        ])

        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.accountUsage?.summary?.currentStreakDays == 3)
    }

    @Test
    func repliesMayArriveInAnyOrder() async throws {
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            CodexTestSupport.fakeUsageReply,
            CodexTestSupport.fakeQuotaReply
        ])

        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.accountUsage?.summary?.currentStreakDays == 3)
    }

    @Test
    func aDuplicatedReplyDoesNotCompleteTheSessionEarly() async throws {
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            CodexTestSupport.fakeQuotaReply,
            CodexTestSupport.fakeQuotaReply,
            CodexTestSupport.fakeUsageReply
        ])

        #expect(bundle.accountUsage?.summary?.currentStreakDays == 3)
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

    // MARK: - 快照接缝

    private func bundle(usageJSON: String?) throws -> CodexQuotaBundle {
        let quota = try CodexTestSupport.decodeRateLimits(#"""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1790337941},
        "secondary":{"usedPercent":58,"windowDurationMins":10080,"resetsAt":1790754811},"planType":"plus"}}
        """#)
        let usage = try usageJSON.map {
            try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data($0.utf8))
        }
        return CodexQuotaBundle(rateLimits: quota, accountUsage: usage)
    }

    private var fetchDay: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    private func codexConfig() -> ServiceConfig {
        ServiceConfig(displayName: "Codex", providerKind: .codex, authMode: .api)
    }

    @Test
    func theSnapshotSeamCarriesTheDetail() throws {
        let snapshot = CodexUsageProvider().snapshot(
            config: codexConfig(),
            bundle: try bundle(usageJSON: #"""
            {"summary":{"lifetimeTokens":172532345,"peakDailyTokens":117865819,
            "longestRunningTurnSec":2550,"currentStreakDays":3},
            "dailyUsageBuckets":[{"startDate":"2026-09-25","tokens":2000000}]}
            """#),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
            today: fetchDay
        )

        #expect(snapshot.state == .ready)
        #expect(snapshot.planName == "Plus")
        #expect(snapshot.usages.map(\.window) == [.fiveHours, .week])

        let detail = try #require(snapshot.detail)
        #expect(detail.headline.map(\.value) == ["12%", "58%"])
        #expect(detail.groups.map { $0.values[0].value } == ["2M", "2M", "2M"])
        #expect(detail.series?.points.count == 30)
        #expect(detail.breakdown.map(\.label) == ["Lifetime", "Peak day", "Streak", "Longest turn"])
    }

    @Test
    func theSnapshotSeamCarriesTheResetCards() throws {
        // 重置卡在**额度**那半（rateLimits）里，不是用量那半 —— 接缝必须把它传给构建器，
        // 否则「浮层里看不到卡」这种静默丢失没人会发现。
        let quota = try CodexTestSupport.decodeRateLimits(#"""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300},"planType":"plus"},
         "rateLimitResetCredits":{"availableCount":1,"credits":[
           {"title":"Full reset (Weekly + 5 hr)","expiresAt":1793293436}]}}
        """#)

        let snapshot = CodexUsageProvider().snapshot(
            config: codexConfig(),
            bundle: CodexQuotaBundle(rateLimits: quota, accountUsage: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
            today: fetchDay
        )

        let table = try #require(snapshot.detail?.table)
        #expect(table.rows.map(\.name) == ["Full reset (Weekly + 5 hr)"])
    }

    @Test
    func aMissingUsageHalfStillYieldsAReadySnapshotWithAQuotaOnlyDetail() throws {
        let snapshot = CodexUsageProvider().snapshot(
            config: codexConfig(),
            bundle: try bundle(usageJSON: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
            today: fetchDay
        )

        #expect(snapshot.state == .ready)
        let detail = try #require(snapshot.detail)
        #expect(detail.headline.map(\.label) == ["5h", "Week"])
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
    }

    @Test
    func aBundleWithoutQuotaWindowsIsUnavailableAndCarriesNoDetail() throws {
        let empty = try CodexTestSupport.decodeRateLimits(#"{"rateLimitsByLimitId":{}}"#)
        let snapshot = CodexUsageProvider().snapshot(
            config: codexConfig(),
            bundle: CodexQuotaBundle(
                rateLimits: empty,
                accountUsage: try JSONDecoder().decode(
                    CodexAccountUsageResponse.self,
                    from: Data(#"{"summary":{"lifetimeTokens":1}}"#.utf8)
                )
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
            today: fetchDay
        )

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.detail == nil)
    }

    @Test
    func aSecondFetchWithinTheMinuteReusesTheCachedBundleWithoutSpawning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        IFS= read -r _
        IFS= read -r _
        IFS= read -r _
        IFS= read -r _
        printf '%s\\n' '\(CodexTestSupport.fakeQuotaReply)'
        printf '%s\\n' '\(CodexTestSupport.fakeUsageReply)'
        while IFS= read -r _; do :; done
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = CodexAppServerClient(testExecutableURL: executable)
        let provider = CodexUsageProvider(client: client)
        let config = ServiceConfig(displayName: "Codex", providerKind: .codex, authMode: .api)

        let first = await provider.fetchUsage(config: config, secrets: .empty)
        #expect(first.state == .ready)
        #expect(first.detail?.headline.isEmpty == false)

        // 把可执行文件删掉：再取一次还能拿到同一份数字，说明走的是缓存、没有起进程。
        try FileManager.default.removeItem(at: executable)
        let second = await provider.fetchUsage(config: config, secrets: .empty)
        #expect(second.state == .ready)
        #expect(second.detail == first.detail)
        #expect(second.updatedAt == first.updatedAt)
    }
}
