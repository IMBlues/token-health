import Foundation

/// DeepSeek 两个用量端点的响应形状。搬自 `DeepSeekUsageParser` 的私有走查函数 ——
/// 解析器与详情构建器共用一份，避免形状知识出现第二份拷贝。
///
/// 两个端点的形状**不对称**，这里如实反映：
/// - `amount`：`{code, data:{biz_data:{days:[{date, data:[{model, usage:[{type, amount}]}]}]}}}`
/// - `cost`：`{data:[{currency, days:[{date, data:[{model, usage:[{amount}]}]}]}]}` —— 顶层是币种数组
enum DeepSeekPayload {
    struct CostCurrency {
        var currency: String
        var days: [[String: Any]]
    }

    // MARK: - amount 侧

    /// 走到 `days` 数组。
    static func days(fromAmount root: [String: Any]) -> [[String: Any]] {
        guard let dataObject = usageDataObject(from: root) else {
            return []
        }
        return dataObject["days"] as? [[String: Any]] ?? []
    }

    // MARK: - cost 侧

    /// 走到 `[{currency, days}]`。
    ///
    /// **保持解析器原有的策略**：缺币种时默认 `"CNY"`，且不排序 —— 排序是详情浮层的展示
    /// 决定，放在 `DeepSeekUsageDetail` 里做。这里若顺手改了策略，解析器的行为就跟着变了，
    /// 而它的测试覆盖不到这种畸形响应。
    static func costCurrencies(fromCost root: [String: Any]) -> [CostCurrency] {
        costCurrencyItems(from: root).map { item in
            CostCurrency(
                currency: stringValue(item["currency"]) ?? "CNY",
                days: item["days"] as? [[String: Any]] ?? []
            )
        }
    }

    // MARK: - 共用

    /// 某一天的明细行。
    static func items(inDay day: [String: Any]) -> [[String: Any]] {
        day["data"] as? [[String: Any]] ?? []
    }

    /// 某一天的日期原文（调用方自己决定怎么用）。
    static func dateText(_ day: [String: Any]) -> String? {
        stringValue(day["date"])
    }

    static func modelName(in item: [String: Any]) -> String? {
        stringValue(item["model"])
    }

    static func intAmount(in item: [String: Any], type: String) -> Int {
        guard let usage = item["usage"] as? [[String: Any]],
              let amount = usage.first(where: { stringValue($0["type"]) == type })
                  .flatMap({ decimalValue($0["amount"]) }) else {
            return 0
        }
        return max(0, NSDecimalNumber(decimal: amount).intValue)
    }

    static func sumAmounts(in item: [String: Any]) -> Decimal {
        guard let usage = item["usage"] as? [[String: Any]] else {
            return Decimal(0)
        }
        return usage.reduce(Decimal(0)) { partial, entry in
            partial + (decimalValue(entry["amount"]) ?? Decimal(0))
        }
    }

    static func decimal(_ value: Any?) -> Decimal? {
        decimalValue(value)
    }

    // MARK: - 形状走查（逐字搬自解析器，必须是 internal）

    // 这几个**不能是 private**：解析器自己也要用（bizData 在 parseSummaryBalances、
    // usageDataObject 在 parseTodayAmounts、costCurrencyItems 在 parseTodayCosts，
    // stringValue/decimalValue 散在四处）。共享一份的意义就在这儿。

    static func bizData(from root: [String: Any]) -> [String: Any]? {
        guard let data = root["data"] as? [String: Any] else {
            return root["biz_data"] as? [String: Any] ?? root
        }
        return data["biz_data"] as? [String: Any] ?? data
    }

    static func usageDataObject(from root: [String: Any]) -> [String: Any]? {
        guard let bizData = bizData(from: root) else {
            return nil
        }
        return bizData["data"] as? [String: Any] ?? bizData
    }

    static func costCurrencyItems(from root: [String: Any]) -> [[String: Any]] {
        if let data = root["data"] as? [[String: Any]] {
            return data
        }
        if let data = root["data"] as? [String: Any] {
            if let bizData = data["biz_data"] as? [[String: Any]] {
                return bizData
            }
            if let bizData = data["biz_data"] as? [String: Any],
               let nested = bizData["data"] as? [[String: Any]] {
                return nested
            }
        }
        if let bizData = root["biz_data"] as? [[String: Any]] {
            return bizData
        }
        return []
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    static func decimalValue(_ value: Any?) -> Decimal? {
        if let decimal = value as? Decimal {
            return decimal
        }
        if let int = value as? Int {
            return Decimal(int)
        }
        if let double = value as? Double {
            return Decimal(double)
        }
        if let string = value as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
            return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }
}
