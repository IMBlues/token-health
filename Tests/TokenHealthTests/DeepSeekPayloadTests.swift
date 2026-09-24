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
}
