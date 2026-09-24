import Foundation
import Testing
@testable import TokenHealth

struct UsageAmountFormatterTests {
    /// 既有测试只覆盖了 M 与精确值两个分支，K 与 B 没人守。
    @Test
    func abbreviatesLargeCounts() {
        #expect(UsageAmountFormatter.compactAmount(999) == "999")
        #expect(UsageAmountFormatter.compactAmount(1_000) == "1K")
        #expect(UsageAmountFormatter.compactAmount(12_500) == "12.5K")
        #expect(UsageAmountFormatter.compactAmount(1_000_000) == "1M")
        #expect(UsageAmountFormatter.compactAmount(2_140_000) == "2.14M")
        #expect(UsageAmountFormatter.compactAmount(1_000_000_000) == "1B")
        #expect(UsageAmountFormatter.compactAmount(3_500_000_000) == "3.5B")
    }

    @Test
    func groupsAndRoundsMoneyToTwoDecimals() {
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "1284.6")!) == "1,284.60")
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "0.1234")!) == "0.12")
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "0")!) == "0.00")
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "1234567.891")!) == "1,234,567.89")
    }

    /// 搬家不能改变面板的显示。
    @Test
    func amountTextStillReadsTheSame() {
        let usage = TokenUsage(window: .fiveHours, used: 2_140_000, limit: 9_000_000)
        let text = UsageAmountFormatter.amountText(usage, isSensitiveAmount: false, revealsSensitiveAmount: true)
        #expect(text == "2.14M / 9M")
    }
}
