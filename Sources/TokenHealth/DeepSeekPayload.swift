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

    // MARK: - by_api_key 侧

    /// 一把 API key 的身份。`name` 是用户给 key 起的名字，`trackingID` 是密钥前缀。
    ///
    /// 两个 id 的分工是硬约束：**聚合用 `keyID`，展示用 `displayName`**。
    /// amount 侧给的是对象、cost 侧给的是裸字符串，两边必须推出同一个 `keyID`，
    /// 否则同一把 key 会在表里裂成两行。
    struct APIKeyIdentity: Equatable {
        var name: String?
        var trackingID: String?

        var keyID: String {
            if let trackingID, !trackingID.isEmpty {
                return trackingID
            }
            if let name, !name.isEmpty {
                return name
            }
            return "unknown"
        }

        var displayName: String {
            if let name, !name.isEmpty {
                return name
            }
            if let trackingID, !trackingID.isEmpty {
                return trackingID
            }
            return "Unknown key"
        }
    }

    struct APIKeyAmountSeries {
        var apiKey: APIKeyIdentity?
        var model: String?
        var buckets: [[String: Any]]
    }

    struct APIKeyCostSeries {
        var apiKey: APIKeyIdentity?
        var model: String?
        var buckets: [[String: Any]]
    }

    struct APIKeyCostCurrency {
        var currency: String
        var series: [APIKeyCostSeries]
    }

    /// 走到 `data.biz_data.series`。
    static func apiKeyAmountSeries(fromAmount root: [String: Any]) -> [APIKeyAmountSeries] {
        guard let bizData = bizData(from: root),
              let series = bizData["series"] as? [[String: Any]] else {
            return []
        }
        return series.map { item in
            APIKeyAmountSeries(
                apiKey: apiKeyIdentity(from: item["api_key"]),
                model: stringValue(item["model"]),
                buckets: item["buckets"] as? [[String: Any]] ?? []
            )
        }
    }

    /// 走到 `data.biz_data.data`（币种层，里层才是 `series`）。
    static func apiKeyCostCurrencies(fromCost root: [String: Any]) -> [APIKeyCostCurrency] {
        guard let bizData = bizData(from: root),
              let currencies = bizData["data"] as? [[String: Any]] else {
            return []
        }
        return currencies.map { item in
            APIKeyCostCurrency(
                currency: stringValue(item["currency"]) ?? "CNY",
                series: (item["series"] as? [[String: Any]] ?? []).map { entry in
                    APIKeyCostSeries(
                        apiKey: apiKeyIdentity(from: entry["api_key"]),
                        model: stringValue(entry["model"]),
                        buckets: entry["buckets"] as? [[String: Any]] ?? []
                    )
                }
            )
        }
    }

    /// `api_key` 的两种形态：对象 `{name, tracking_id}`，或裸字符串（cost 侧就是这样）。
    static func apiKeyIdentity(from value: Any?) -> APIKeyIdentity? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : APIKeyIdentity(name: nil, trackingID: trimmed)
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        let identity = APIKeyIdentity(
            name: stringValue(object["name"]),
            trackingID: stringValue(object["tracking_id"])
        )
        return (identity.name == nil && identity.trackingID == nil) ? nil : identity
    }

    /// bucket 的 `usage` 是**字典**形态 `{TYPE: 值}`，与数组形态的 `intAmount(in:type:)` 各走一条。
    static func intAmount(inUsageDict usage: [String: Any]?, type: String) -> Int {
        guard let amount = decimalValue(usage?[type]) else {
            return 0
        }
        return max(0, NSDecimalNumber(decimal: amount).intValue)
    }

    /// cost bucket 的金额。负数（坏数据）夹到 0。
    static func costAmount(inBucket bucket: [String: Any]) -> Decimal {
        max(0, decimalValue(bucket["cost"]) ?? Decimal(0))
    }

    /// bucket 的时间戳（unix 秒）。缺或解不出返回 nil —— 调用方据此丢弃这个 bucket，
    /// 而不是当成 0（1970 年那天）收进来。
    static func time(inBucket bucket: [String: Any]) -> Int? {
        guard let amount = decimalValue(bucket["time"]) else {
            return nil
        }
        return NSDecimalNumber(decimal: amount).intValue
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
