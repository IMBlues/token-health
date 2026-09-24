import Foundation
import Testing
@testable import TokenHealth

struct DeepSeekAmountTests {
    @Test
    func balanceUsagesCarryTheirNumericAmount() throws {
        let data = Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"12.34"}]}"#.utf8)
        let usages = try DeepSeekUsageParser().parsePublicBalance(data: data)

        #expect(usages.count == 1)
        #expect(usages[0].unit == "CNY")
        #expect(usages[0].amount == Decimal(string: "12.34"))
        #expect(usages[0].displayValue == "12.34 CNY")
    }

    @Test
    func platformBalancesSumTheWalletsPerCurrency() throws {
        let bundle = """
        {"summary":{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"10.00"}],
        "bonus_wallets":[{"currency":"CNY","balance":"2.50"}]}}}}
        """
        let usages = try DeepSeekUsageParser().parsePlatformBundle(
            data: Data(bundle.utf8),
            today: "2026-09-24"
        )
        let balance = try #require(usages.first { $0.window == .balance })

        #expect(balance.unit == "CNY")
        #expect(balance.amount == Decimal(string: "12.50"))
        #expect(balance.displayValue == "12.50 CNY")
    }

    @Test
    func todayCostUsagesCarryTheirNumericAmount() throws {
        let bundle = """
        {"cost":{"data":[{"currency":"CNY","days":[{"date":"2026-09-24",
        "data":[{"model":"deepseek-chat","usage":[{"amount":"0.1234"}]}]}]}]}}
        """
        let usages = try DeepSeekUsageParser().parsePlatformBundle(
            data: Data(bundle.utf8),
            today: "2026-09-24"
        )
        let total = try #require(usages.first { $0.window == .todayCost && $0.label?.contains("total") == true })

        #expect(total.amount == Decimal(string: "0.1234"))
        #expect(total.displayValue == "0.1234 CNY")
    }

    @Test
    func tokenUsagesCarryNoAmount() {
        let usage = TokenUsage(window: .fiveHours, used: 1200, limit: 5000)
        #expect(usage.amount == nil)
    }
}
