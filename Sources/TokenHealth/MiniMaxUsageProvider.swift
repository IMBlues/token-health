import Foundation

struct MiniMaxUsageProvider: UsageProvider {
    private let platformHost = "www.minimaxi.com"

    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        guard let session = MiniMaxWebSessionCredential.decode(from: secrets.apiKey), !session.isEmpty else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Login with MiniMax")
        }

        do {
            let bundleData: Data
            do {
                bundleData = try await fetchUsageBundle(session: session)
            } catch {
                MiniMaxWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                bundleData = try await MiniMaxWebLoginController.shared.fetchUsageBundleFromActiveSession()
            }

            let result = try MiniMaxUsageParser().parseBundle(data: bundleData)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: result.planName ?? session.accountName,
                usages: result.usages,
                state: .ready,
                statusMessage: "MiniMax Platform",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func fetchUsageBundle(session: MiniMaxWebSessionCredential) async throws -> Data {
        async let subscription = fetchPlatformData(
            session: session,
            path: "/v1/api/openplatform/charge/combo/cycle_audio_resource_package",
            query: [
                "biz_line": "2",
                "cycle_type": "1",
                "resource_package_type": "7"
            ]
        )
        async let remains = fetchPlatformData(
            session: session,
            path: "/v1/api/openplatform/coding_plan/remains",
            query: [:]
        )
        async let credits = fetchPlatformData(
            session: session,
            path: "/backend/account/token_plan_credit",
            query: [:]
        )
        async let summary = fetchPlatformData(
            session: session,
            path: "/backend/account/token_plan/usage_summary",
            query: [:]
        )

        return try bundle(
            subscription: try await subscription,
            remains: try await remains,
            credits: try await credits,
            summary: try await summary
        )
    }

    private func fetchPlatformData(
        session: MiniMaxWebSessionCredential,
        path: String,
        query: [String: String]
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = platformHost
        components.path = path
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://platform.minimaxi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.minimaxi.com/console/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        applySessionAuthentication(session, to: &request)

        MiniMaxWebLoginController.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            MiniMaxWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")
            throw MiniMaxWebLoginController.LoginError.requestFailed("MiniMax HTTP \(httpResponse.statusCode): \(body.prefix(160))")
        }
        MiniMaxWebLoginController.debugLog("native request succeeded, path=\(path), bytes=\(data.count)")
        return data
    }

    private func bundle(subscription: Data, remains: Data, credits: Data, summary: Data) throws -> Data {
        let object: [String: Any] = [
            "subscription": try jsonObject(from: subscription),
            "remains": try jsonObject(from: remains),
            "credits": try jsonObject(from: credits),
            "summary": try jsonObject(from: summary)
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func jsonObject(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func applySessionAuthentication(_ session: MiniMaxWebSessionCredential, to request: inout URLRequest) {
        if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let groupID = session.groupID, !groupID.isEmpty {
            request.setValue(groupID, forHTTPHeaderField: "X-Group-Id")
        }
        if (session.cookieHeader ?? "").isEmpty,
           let accessToken = session.accessToken,
           !accessToken.isEmpty {
            if accessToken.lowercased().hasPrefix("bearer ") {
                request.setValue(accessToken, forHTTPHeaderField: "Authorization")
            } else {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}

struct MiniMaxUsageParser {
    struct ParseResult {
        var planName: String?
        var usages: [TokenUsage]
    }

    func parseBundle(data: Data) throws -> ParseResult {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }

        let subscription = root["subscription"] as? [String: Any]
        let remains = root["remains"] as? [String: Any]
        let credits = root["credits"] as? [String: Any]
        let summary = root["summary"] as? [String: Any]

        try [subscription, remains, credits, summary].forEach { item in
            if let item {
                try validateAPIResponse(item)
            }
        }

        var usages: [TokenUsage] = []
        if let remains {
            usages.append(contentsOf: parseRemains(root: remains))
        }
        if let credits {
            usages.append(contentsOf: parseCredits(root: credits))
        }
        if let summary {
            usages.append(contentsOf: parseUsageSummary(root: summary))
        }

        guard !usages.isEmpty else {
            throw ParserError.noUsage
        }
        return ParseResult(planName: planName(from: subscription), usages: usages)
    }

    private func parseRemains(root: [String: Any]) -> [TokenUsage] {
        let items = root["model_remains"] as? [[String: Any]] ?? []
        guard let item = items.first(where: hasTextPlanQuota) ?? items.first else {
            return []
        }

        var usages: [TokenUsage] = []
        if let fiveHours = quotaUsage(
            .fiveHours,
            item: item,
            totalKey: "current_interval_total_count",
            usageKey: "current_interval_usage_count",
            remainingPercentKey: "current_interval_remaining_percent",
            statusKey: "current_interval_status",
            remainsKey: "remains_time",
            endKey: "end_time"
        ) {
            usages.append(fiveHours)
        }

        if let week = quotaUsage(
            .week,
            item: item,
            totalKey: "current_weekly_total_count",
            usageKey: "current_weekly_usage_count",
            remainingPercentKey: "current_weekly_remaining_percent",
            boostPermilleKey: "weekly_boost_permille",
            statusKey: "current_weekly_status",
            remainsKey: "weekly_remains_time",
            endKey: "weekly_end_time"
        ) {
            usages.append(week)
        }

        if let videoItem = items.first(where: hasVideoQuota),
           let videoGift = videoGiftUsage(item: videoItem) {
            usages.append(videoGift)
        }
        return usages
    }

    private func parseCredits(root: [String: Any]) -> [TokenUsage] {
        let breakdown = root["balance_breakdown"] as? [String: Any]
        guard let balance = decimalValue(breakdown?["total_balance"])
            ?? decimalValue(root["remaining_credits"])
            ?? decimalValue(root["total_balance"]) else {
            return []
        }

        return [
            TokenUsage(
                window: .balance,
                label: "Credits balance",
                used: max(0, NSDecimalNumber(decimal: balance).intValue),
                limit: nil,
                resetDate: nil,
                unit: "credits",
                displayValue: "\(decimalText(balance)) credits"
            )
        ]
    }

    private func parseUsageSummary(root: [String: Any]) -> [TokenUsage] {
        let items = root["date_model_usage"] as? [[String: Any]] ?? []
        guard !items.isEmpty else {
            return []
        }

        let today = currentDayString()
        let todayItem = items.first { stringValue($0["date"]) == today }
        let sortedItems = items.sorted {
            (stringValue($0["date"]) ?? "") < (stringValue($1["date"]) ?? "")
        }
        let recentItems = Array(sortedItems.suffix(7))
        let sevenDayTokens = recentItems.reduce(0) { partial, item in
            partial + (intValue(item["total_token"]) ?? 0)
        }

        var usages: [TokenUsage] = []
        if let todayItem {
            let todayTokens = intValue(todayItem["total_token"]) ?? 0
            usages.append(TokenUsage(window: .todayTokens, label: "Today tokens total", used: todayTokens, limit: nil, resetDate: nil, unit: "tokens"))

            let topModels = (todayItem["models"] as? [[String: Any]] ?? [])
                .compactMap { model -> TokenUsage? in
                    guard let name = stringValue(model["model"]),
                          let total = intValue(model["total_token"]) else {
                        return nil
                    }
                    return TokenUsage(window: .todayTokens, label: "Today \(name) tokens", used: total, limit: nil, resetDate: nil, unit: "tokens")
                }
                .sorted { $0.used > $1.used }
                .prefix(3)
            usages.append(contentsOf: topModels)
        }

        if sevenDayTokens > 0 {
            usages.append(TokenUsage(window: .sevenDaysTokens, label: "7d Token total", used: sevenDayTokens, limit: nil, resetDate: nil, unit: "tokens"))
        }

        if let totalConsumed = intValue(root["total_token_consumed"]), totalConsumed > 0 {
            usages.append(TokenUsage(window: .sevenDaysTokens, label: "Lifetime Token total", used: totalConsumed, limit: nil, resetDate: nil, unit: "tokens"))
        }

        return usages
    }

    private func quotaUsage(
        _ window: UsageWindow,
        item: [String: Any],
        totalKey: String,
        usageKey: String,
        remainingPercentKey: String,
        boostPermilleKey: String = "interval_boost_permille",
        statusKey: String,
        remainsKey: String,
        endKey: String
    ) -> TokenUsage? {
        if intValue(item[statusKey]) == 3 {
            return TokenUsage(
                window: window,
                used: 0,
                limit: nil,
                resetDate: resetDate(item: item, remainsKey: remainsKey, endKey: endKey),
                unit: nil,
                displayValue: "Unlimited"
            )
        }

        if let total = intValue(item[totalKey]), total > 0 {
            let used = intValue(item[usageKey]).map { remaining in
                max(0, total - remaining)
            } ?? {
                guard let remainingPercent = doubleValue(item[remainingPercentKey]) else {
                    return 0
                }
                let usedPercent = max(0, min(100, 100 - remainingPercent))
                return Int((Double(total) * usedPercent / 100).rounded())
            }()

            return TokenUsage(
                window: window,
                used: max(0, used),
                limit: total,
                resetDate: resetDate(item: item, remainsKey: remainsKey, endKey: endKey),
                unit: "requests"
            )
        }

        guard let remainingPercent = doubleValue(item[remainingPercentKey]) else {
            return nil
        }

        let displayedTotal = max(100, Int(((doubleValue(item[boostPermilleKey]) ?? 1000) / 10).rounded()))
        let usedPercent = max(0, min(100, 100 - remainingPercent))
        return TokenUsage(
            window: window,
            used: Int((Double(displayedTotal) * usedPercent / 100).rounded()),
            limit: displayedTotal,
            resetDate: resetDate(item: item, remainsKey: remainsKey, endKey: endKey),
            unit: "%"
        )
    }

    private func videoGiftUsage(item: [String: Any]) -> TokenUsage? {
        guard let total = intValue(item["current_interval_total_count"]), total > 0 else {
            return nil
        }

        let used = intValue(item["current_interval_usage_count"]).map { remaining in
            max(0, total - remaining)
        } ?? {
            guard let remainingPercent = doubleValue(item["current_interval_remaining_percent"]) else {
                return 0
            }
            let usedPercent = max(0, min(100, 100 - remainingPercent))
            return Int((Double(total) * usedPercent / 100).rounded())
        }()

        return TokenUsage(
            window: .videoGift,
            label: "Video gifted",
            used: max(0, used),
            limit: total,
            resetDate: resetDate(item: item, remainsKey: "remains_time", endKey: "end_time"),
            unit: "videos"
        )
    }

    private func resetDate(item: [String: Any], remainsKey: String, endKey: String) -> Date? {
        if let milliseconds = doubleValue(item[remainsKey]), milliseconds > 0 {
            return Date().addingTimeInterval(milliseconds / 1000)
        }
        return dateValue(item[endKey])
    }

    private func hasTextPlanQuota(_ item: [String: Any]) -> Bool {
        let modelName = stringValue(item["model_name"]) ?? ""
        if modelName.localizedCaseInsensitiveContains("video") {
            return false
        }
        return (intValue(item["current_interval_total_count"]) ?? 0) > 0
            || (intValue(item["current_weekly_total_count"]) ?? 0) > 0
            || doubleValue(item["current_interval_remaining_percent"]) != nil
            || doubleValue(item["current_weekly_remaining_percent"]) != nil
            || intValue(item["current_interval_status"]) == 3
            || intValue(item["current_weekly_status"]) == 3
    }

    private func hasVideoQuota(_ item: [String: Any]) -> Bool {
        let modelName = stringValue(item["model_name"]) ?? ""
        return modelName.localizedCaseInsensitiveContains("video")
            && ((intValue(item["current_interval_total_count"]) ?? 0) > 0
                || (intValue(item["current_interval_usage_count"]) ?? 0) > 0)
    }

    private func planName(from subscription: [String: Any]?) -> String? {
        guard let subscription else {
            return nil
        }
        if let current = subscription["current_subscribe"] as? [String: Any],
           let title = firstString(current, keys: ["current_subscribe_title", "title", "combo_name"]) {
            return title
        }
        if let card = subscription["current_combo_card"] as? [String: Any],
           let title = firstString(card, keys: ["title", "combo_name"]) {
            return title
        }
        return firstString(subscription, keys: ["current_subscribe_title", "title", "combo_name"])
    }

    private func validateAPIResponse(_ root: [String: Any]) throws {
        if let baseResp = root["base_resp"] as? [String: Any],
           let statusCode = intValue(baseResp["status_code"]),
           statusCode != 0 {
            let message = stringValue(baseResp["status_msg"]) ?? "\(statusCode)"
            throw ParserError.apiError(message)
        }

        if let code = root["code"] {
            let text = String(describing: code)
            if text != "0" && text != "200" {
                throw ParserError.apiError(text)
            }
        }
    }

    private func currentDayString(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key]), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let decimal = value as? Decimal {
            return NSDecimalNumber(decimal: decimal).intValue
        }
        if let string = value as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
            if let int = Int(normalized) {
                return int
            }
            if let double = doubleValue(normalized) {
                return Int(double)
            }
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let string = value as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "%", with: "")
            if normalized.uppercased().hasSuffix("B"),
               let number = Double(normalized.dropLast()) {
                return number * 1_000_000_000
            }
            if normalized.uppercased().hasSuffix("M"),
               let number = Double(normalized.dropLast()) {
                return number * 1_000_000
            }
            if normalized.uppercased().hasSuffix("K"),
               let number = Double(normalized.dropLast()) {
                return number * 1_000
            }
            return Double(normalized)
        }
        return nil
    }

    private func decimalValue(_ value: Any?) -> Decimal? {
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

    private func decimalText(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let milliseconds = value as? Double {
            return Date(timeIntervalSince1970: milliseconds > 10_000_000_000 ? milliseconds / 1000 : milliseconds)
        }
        if let int = value as? Int {
            let seconds = Double(int)
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    enum ParserError: LocalizedError {
        case invalidShape
        case noUsage
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidShape:
                "Expected a JSON object"
            case .noUsage:
                "No MiniMax usage data found"
            case let .apiError(message):
                "MiniMax API error: \(message)"
            }
        }
    }
}
