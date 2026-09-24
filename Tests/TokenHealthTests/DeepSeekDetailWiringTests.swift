import Foundation
import Testing
@testable import TokenHealth

struct DeepSeekDetailWiringTests {
    private let period = DeepSeekUsagePeriod(year: 2026, month: 9, day: "2026-09-24")

    private func config(auth: AuthMode) -> ServiceConfig {
        ServiceConfig(displayName: "DeepSeek", providerKind: .deepSeek, authMode: auth)
    }

    private var bundle: Data {
        Data(#"""
        {"summary":{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"1284.60"}]}}},
         "amount":{"data":{"biz_data":{"days":[{"date":"2026-09-24","data":[
           {"model":"deepseek-chat","usage":[
             {"type":"REQUEST","amount":"4"},
             {"type":"RESPONSE_TOKEN","amount":"40"},
             {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"80"},
             {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"20"}]}]}]}}},
         "cost":{"data":[{"currency":"CNY","days":[{"date":"2026-09-24","data":[
           {"model":"deepseek-chat","usage":[{"amount":"0.02"}]}]}]}]}}
        """#.utf8)
    }

    @Test
    func aPlatformBundleProducesAReadySnapshotWithDetail() throws {
        let snapshot = DeepSeekUsageProvider().platformSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundle,
            period: period,
            accountName: "blues"
        )

        #expect(snapshot.state == .ready)
        #expect(!snapshot.usages.isEmpty)
        #expect(snapshot.planName == "blues")

        let detail = try #require(snapshot.detail)
        #expect(detail.headline == [DetailStat(label: "CNY", value: "1,284.60")])
        let today = try #require(detail.groups.first { $0.title == "Today" })
        #expect(today.values.map(\.value) == ["4", "140", "0.02 CNY"])
    }

    @Test
    func detailBalancesMatchTheSnapshotsBalances() throws {
        let snapshot = DeepSeekUsageProvider().platformSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundle,
            period: period,
            accountName: nil
        )

        let balances = snapshot.usages.filter { $0.window == .balance }
        let detail = try #require(snapshot.detail)
        #expect(detail.headline.count == balances.count, "headline 就是那些 balance，不该另解析一遍")
    }

    @Test
    func aMalformedBundleStillYieldsAnUnavailableSnapshot() {
        let snapshot = DeepSeekUsageProvider().platformSnapshot(
            config: config(auth: .browserLogin),
            bundle: Data("not json".utf8),
            period: period,
            accountName: nil
        )

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.detail == nil)
    }

    @Test
    func aValidButEmptyBundleYieldsZerosRatherThanFailing() throws {
        // 解析器总会产出「今日」两条总量，所以合法但空的响应**不会**抛错。
        // 浮层那边要能把它显示成「这个月没有用量」，而不是崩掉或报错。
        let snapshot = DeepSeekUsageProvider().platformSnapshot(
            config: config(auth: .browserLogin),
            bundle: Data(#"{"summary":{},"amount":{},"cost":{}}"#.utf8),
            period: period,
            accountName: nil
        )

        #expect(snapshot.state == .ready)
        let detail = try #require(snapshot.detail)
        #expect(
            detail.series?.points.allSatisfy { $0.value == 0 } == true,
            "全零的月份交给视图去说 No usage this month"
        )
        #expect(detail.table == nil, "没有模型就不画表")
    }
}
