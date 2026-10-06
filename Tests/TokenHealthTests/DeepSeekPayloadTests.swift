import Foundation
import Testing
@testable import TokenHealth

struct DeepSeekPayloadTests {
    @Test
    func walksTheAmountEnvelopeDownToItsDays() {
        let root: [String: Any] = [
            "code": 0,
            "data": ["biz_data": ["days": [["date": "2026-09-24", "data": []]]]]
        ]
        let days = DeepSeekPayload.days(fromAmount: root)
        #expect(days.count == 1)
        #expect(DeepSeekPayload.dateText(days[0]) == "2026-09-24")
    }

    @Test
    func walksTheCostEnvelopePerCurrency() {
        let root: [String: Any] = [
            "data": [
                ["currency": "CNY", "days": [["date": "2026-09-24", "data": []]]],
                ["currency": "USD", "days": [["date": "2026-09-24", "data": []]]]
            ]
        ]
        let items = DeepSeekPayload.costCurrencies(fromCost: root)
        #expect(items.map(\.currency) == ["CNY", "USD"])
        #expect(DeepSeekPayload.dateText(items[0].days[0]) == "2026-09-24")
    }

    /// 解析器原来就对缺币种的条目默认 CNY，走查函数必须保留这个宽容度 ——
    /// 顺手改成丢弃会让解析器在畸形响应上悄悄变行为。
    @Test
    func defaultsAMissingCurrencyToCNY() {
        let root: [String: Any] = ["data": [["days": []]]]
        let items = DeepSeekPayload.costCurrencies(fromCost: root)
        #expect(items.map(\.currency) == ["CNY"])
    }

    /// 走查不做排序 —— 币种顺序是展示决定，属于详情构建器。
    @Test
    func preservesTheOrderItWalked() {
        let root: [String: Any] = [
            "data": [["currency": "USD", "days": []], ["currency": "CNY", "days": []]]
        ]
        #expect(DeepSeekPayload.costCurrencies(fromCost: root).map(\.currency) == ["USD", "CNY"])
    }

    @Test
    func readsTypedAmountsAndIgnoresUnknownTypes() {
        let item: [String: Any] = [
            "model": "deepseek-chat",
            "usage": [
                ["type": "REQUEST", "amount": "12"],
                ["type": "RESPONSE_TOKEN", "amount": "340"],
                ["type": "SOMETHING_ELSE", "amount": "999"]
            ]
        ]
        #expect(DeepSeekPayload.intAmount(in: item, type: "REQUEST") == 12)
        #expect(DeepSeekPayload.intAmount(in: item, type: "RESPONSE_TOKEN") == 340)
        #expect(DeepSeekPayload.intAmount(in: item, type: "MISSING") == 0)
    }

    @Test
    func sumsEveryAmountInAnItem() {
        let item: [String: Any] = [
            "usage": [["amount": "0.5"], ["amount": "0.25"], ["amount": "abc"]]
        ]
        #expect(DeepSeekPayload.sumAmounts(in: item) == Decimal(string: "0.75"))
    }

    @Test
    func readsNumbersFromStringsIntsAndDoubles() {
        #expect(DeepSeekPayload.decimal("12.5") == Decimal(string: "12.5"))
        #expect(DeepSeekPayload.decimal(12) == Decimal(12))
        #expect(DeepSeekPayload.decimal(12.5) == Decimal(string: "12.5"))
        #expect(DeepSeekPayload.decimal("1,234.5") == Decimal(string: "1234.5"))
        #expect(DeepSeekPayload.decimal("abc") == nil)
        #expect(DeepSeekPayload.decimal(nil) == nil)
    }

    @Test
    func toleratesMissingLayers() {
        #expect(DeepSeekPayload.days(fromAmount: [:]).isEmpty)
        #expect(DeepSeekPayload.costCurrencies(fromCost: [:]).isEmpty)
        #expect(DeepSeekPayload.items(inDay: [:]).isEmpty)
    }

    @Test
    func walksTheByKeyAmountEnvelopeDownToItsBuckets() {
        let root: [String: Any] = [
            "code": 0,
            "data": ["biz_data": ["series": [[
                "api_key": ["name": "prod", "tracking_id": "sk-abc"],
                "model": "deepseek-chat",
                "buckets": [["time": 1_759_276_800, "usage": ["REQUEST": "128"]]]
            ]]]]
        ]

        let series = DeepSeekPayload.apiKeyAmountSeries(fromAmount: root)
        #expect(series.count == 1)
        #expect(series[0].apiKey?.keyID == "sk-abc")
        #expect(series[0].apiKey?.displayName == "prod")
        #expect(series[0].model == "deepseek-chat")
        #expect(series[0].buckets.count == 1)
    }

    /// cost 侧的 api_key 是裸字符串 —— 与 amount 侧的对象形态必须落到同一个身份上。
    @Test
    func aBareStringAPIKeyIdentifiesItself() {
        let root: [String: Any] = [
            "data": ["biz_data": ["data": [[
                "currency": "CNY",
                "series": [[
                    "api_key": "sk-abc",
                    "model": "deepseek-chat",
                    "buckets": [["time": 1_759_276_800, "cost": "1.2843"]]
                ]]
            ]]]]
        ]

        let currencies = DeepSeekPayload.apiKeyCostCurrencies(fromCost: root)
        #expect(currencies.map(\.currency) == ["CNY"])
        #expect(currencies[0].series[0].apiKey?.keyID == "sk-abc", "裸字符串用自己当 tracking id")
        #expect(currencies[0].series[0].apiKey?.displayName == "sk-abc")
    }

    @Test
    func identityFallsBackInOrderOfConfidence() {
        #expect(DeepSeekPayload.apiKeyIdentity(from: ["name": "prod"])?.keyID == "prod")
        #expect(DeepSeekPayload.apiKeyIdentity(from: ["tracking_id": "sk-x"])?.displayName == "sk-x")
        #expect(DeepSeekPayload.apiKeyIdentity(from: [:]) == nil)
        #expect(DeepSeekPayload.apiKeyIdentity(from: NSNull()) == nil)
        #expect(DeepSeekPayload.apiKeyIdentity(from: 42) == nil)
        #expect(DeepSeekPayload.apiKeyIdentity(from: "  ") == nil)
    }

    @Test
    func readsUsageFromTheBucketDictionary() {
        let usage: [String: Any] = [
            "REQUEST": "128",
            "RESPONSE_TOKEN": 40_211,
            "PROMPT_CACHE_HIT_TOKEN": NSNull(),
            "PROMPT_CACHE_MISS_TOKEN": "-7"
        ]

        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "REQUEST") == 128)
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "RESPONSE_TOKEN") == 40_211)
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "PROMPT_CACHE_HIT_TOKEN") == 0, "null 当 0")
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "PROMPT_CACHE_MISS_TOKEN") == 0, "负数夹到 0")
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "ABSENT") == 0)
        #expect(DeepSeekPayload.intAmount(inUsageDict: nil, type: "REQUEST") == 0)
    }

    @Test
    func readsBucketTimeAndCost() {
        #expect(DeepSeekPayload.time(inBucket: ["time": 1_759_276_800]) == 1_759_276_800)
        #expect(DeepSeekPayload.time(inBucket: ["time": "1759276800"]) == 1_759_276_800)
        #expect(DeepSeekPayload.time(inBucket: [:]) == nil)
        #expect(DeepSeekPayload.costAmount(inBucket: ["cost": "1.2843"]) == Decimal(string: "1.2843"))
        #expect(DeepSeekPayload.costAmount(inBucket: ["cost": NSNull()]) == 0)
        #expect(DeepSeekPayload.costAmount(inBucket: ["cost": "-5"]) == 0)
    }

    @Test
    func missingShapesYieldEmptyRatherThanCrashing() {
        #expect(DeepSeekPayload.apiKeyAmountSeries(fromAmount: [:]).isEmpty)
        #expect(DeepSeekPayload.apiKeyAmountSeries(fromAmount: ["data": ["biz_data": [:]]]).isEmpty)
        #expect(DeepSeekPayload.apiKeyCostCurrencies(fromCost: [:]).isEmpty)
        #expect(DeepSeekPayload.apiKeyCostCurrencies(fromCost: ["data": ["biz_data": ["data": []]]]).isEmpty)
    }
}
