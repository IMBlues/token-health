import Foundation
import SwiftUI

/// 用量数字与金额的显示格式。面板、菜单栏项与详情浮层共用同一套。
enum UsageAmountFormatter {
    static func amountText(
        _ usage: TokenUsage,
        isSensitiveAmount: Bool,
        revealsSensitiveAmount: Bool
    ) -> String {
        if isSensitiveAmount && !revealsSensitiveAmount {
            return "¥¥¥"
        }
        if let displayValue = usage.displayValue, !displayValue.isEmpty {
            return displayValue
        }
        if usage.window == .tokenQuota {
            if let ratio = usage.ratio {
                return "\(trimmedDecimal(ratio * 100))%"
            }
            let used = compactAmount(usage.used)
            return unitText(for: usage).map { "\(used) \($0)" } ?? used
        }
        if usage.unit == "%" {
            return "\(usage.used)%"
        }

        let used = compactAmount(usage.used)
        guard let limit = usage.limit else {
            return unitText(for: usage).map { "\(used) \($0)" } ?? used
        }
        let amount = "\(used) / \(compactAmount(limit))"
        return unitText(for: usage).map { "\(amount) \($0)" } ?? amount
    }

    static func exactAmountText(_ usage: TokenUsage) -> String {
        if let displayValue = usage.displayValue, !displayValue.isEmpty {
            return displayValue
        }
        if usage.unit == "%" {
            return "\(usage.used)%"
        }

        let used = formatExactAmount(usage.used)
        guard let limit = usage.limit else {
            return unitText(for: usage).map { "\(used) \($0)" } ?? used
        }
        let amount = "\(used) / \(formatExactAmount(limit))"
        return unitText(for: usage).map { "\(amount) \($0)" } ?? amount
    }

    static func tint(for usage: TokenUsage) -> Color {
        guard let ratio = usage.ratio else {
            return .accentColor
        }
        if ratio >= 0.9 {
            return .red
        }
        if ratio >= 0.7 {
            return .orange
        }
        return .green
    }

    /// 紧凑数字：`1.2K` / `3.4M` / `5.6B`，一千以下给精确值。面板与详情浮层共用。
    static func compactAmount(_ value: Int) -> String {
        let number = Double(value)
        let magnitude = abs(number)
        if magnitude >= 1_000_000_000 {
            return "\(trimmedDecimal(number / 1_000_000_000))B"
        }
        if magnitude >= 1_000_000 {
            return "\(trimmedDecimal(number / 1_000_000))M"
        }
        if magnitude >= 1_000 {
            return "\(trimmedDecimal(number / 1_000))K"
        }
        return formatExactAmount(value)
    }

    /// 金额：两位小数、千位分隔、**不带单位**（单位由调用方按需追加）。
    static func moneyText(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private static func unitText(for usage: TokenUsage) -> String? {
        usage.unit?.isEmpty == false ? usage.unit : nil
    }

    private static func trimmedDecimal(_ value: Double) -> String {
        var result = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        while result.last == "0" {
            result.removeLast()
        }
        if result.last == "." {
            result.removeLast()
        }
        return result
    }

    private static func formatExactAmount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
