import Foundation

/// 菜单栏项上的一个指标：要么是一根比例条，要么是一段金额文字。
struct MenuBarMetric: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case ratio(Double)
        case amount(String)
    }

    var label: String
    var shape: Shape
    /// 用于给条选色；金额型没有严重度。
    var severity: Double?
}

enum MenuBarMetrics {
    /// 快照不可用时画这个，让菜单栏上留一根空槽而不是整项消失。
    static let placeholder = MenuBarMetric(label: "", shape: .ratio(0), severity: nil)

    static func metrics(
        for snapshot: ProviderUsageSnapshot?,
        kind: ProviderKind,
        displayCurrency: String?,
        rateTable: ExchangeRateTable
    ) -> [MenuBarMetric] {
        guard let snapshot, snapshot.state == .ready else {
            return []
        }
        if kind == .deepSeek {
            return deepSeekMetrics(from: snapshot.usages, displayCurrency: displayCurrency, rateTable: rateTable)
        }
        return UsageMetricSelection.pinnedMetrics(from: snapshot.usages, kind: kind).map { usage in
            let ratio = min(max(usage.ratio ?? 0, 0), 1)
            return MenuBarMetric(label: shortLabel(for: usage), shape: .ratio(ratio), severity: ratio)
        }
    }

    static func tooltipText(serviceName: String, metrics: [MenuBarMetric], statusMessage: String? = nil) -> String {
        guard !metrics.isEmpty else {
            return "\(serviceName) · \(statusMessage ?? "Waiting for refresh")"
        }
        let parts = metrics.map { metric in
            switch metric.shape {
            case let .ratio(value):
                "\(metric.label) \(percentText(value))"
            case let .amount(text):
                "\(metric.label) \(text)"
            }
        }
        return ([serviceName] + parts).joined(separator: " · ")
    }

    static func percentText(_ ratio: Double) -> String {
        let percent = (ratio * 100).rounded()
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: percent)) ?? "\(Int(percent))")%"
    }

    /// 短标签；usage 自带 label 时优先用它（Cursor 的三个池靠这个区分）。
    static func shortLabel(for usage: TokenUsage) -> String {
        if let label = usage.label, !label.isEmpty {
            return label
        }
        return switch usage.window {
        case .fiveHours: "5h"
        case .week: "Week"
        case .month: "Month"
        case .mcpMonth: "MCP"
        case .videoGift: "Video"
        default: usage.window.title
        }
    }

    /// DeepSeek 没有额度比例，退化成一个换算后的金额。
    private static func deepSeekMetrics(
        from usages: [TokenUsage],
        displayCurrency: String?,
        rateTable: ExchangeRateTable
    ) -> [MenuBarMetric] {
        let balances = usages.filter { $0.window == .balance }
        guard !balances.isEmpty else {
            return []
        }

        let target = displayCurrency?.trimmingCharacters(in: .whitespaces).uppercased()
        guard let target, !target.isEmpty else {
            // 没选目标币种：与卡片折叠态一致，取共享排序后的第一项原值。
            guard let first = UsageMetricSelection.sorted(balances, kind: .deepSeek).first,
                  let amount = first.amount else {
                return []
            }
            return [MenuBarMetric(label: shortLabel(for: first), shape: .amount(UsageAmountFormatter.moneyText(amount)), severity: nil)]
        }

        var total = Decimal(0)
        for balance in balances {
            guard let amount = balance.amount,
                  let currency = balance.unit,
                  let converted = rateTable.convert(amount, from: currency, to: target) else {
                // 只要有一个币种换不了就整体退回原值：宁可显示原币种，
                // 也不要给出一个悄悄漏掉了某个钱包的合计。
                guard let fallback = UsageMetricSelection.sorted(balances, kind: .deepSeek).first,
                      let fallbackAmount = fallback.amount else {
                    return []
                }
                return [MenuBarMetric(
                    label: "\(shortLabel(for: fallback)) · rate unavailable",
                    shape: .amount(UsageAmountFormatter.moneyText(fallbackAmount)),
                    severity: nil
                )]
            }
            total += converted
        }
        return [MenuBarMetric(label: target, shape: .amount(UsageAmountFormatter.moneyText(total)), severity: nil)]
    }
}
