import Foundation

struct DeepSeekUsageProvider: UsageProvider {
    private let publicBalanceEndpoint = "https://api.deepseek.com/user/balance"

    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        if let session = DeepSeekWebSessionCredential.decode(from: secrets.apiKey), !session.isEmpty {
            return await fetchPlatformUsage(config: config, session: session)
        }

        if config.authMode == .browserLogin {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Login with DeepSeek")
        }

        return await fetchPublicBalance(config: config, secrets: secrets)
    }

    private func fetchPlatformUsage(
        config: ServiceConfig,
        session: DeepSeekWebSessionCredential
    ) async -> ProviderUsageSnapshot {
        let period = DeepSeekUsagePeriod.currentUTC()
        do {
            let bundleData: Data
            do {
                bundleData = try await fetchUsageBundle(session: session, period: period)
            } catch {
                DeepSeekWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                bundleData = try await DeepSeekWebLoginController.shared.fetchUsageBundleFromActiveSession(
                    month: period.month,
                    year: period.year
                )
            }

            let usages = try DeepSeekUsageParser().parsePlatformBundle(data: bundleData, today: period.day)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: session.accountName,
                usages: usages,
                state: .ready,
                statusMessage: "DeepSeek Platform",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func fetchPublicBalance(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        guard !secrets.apiKey.isEmpty else {
            return ProviderUsageSnapshot.unavailable(
                config: config,
                message: "Paste DeepSeek API key or use Login mode"
            )
        }

        let endpoint = config.apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint.isEmpty ? publicBalanceEndpoint : endpoint) else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Invalid endpoint")
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            applyAPIAuthentication(secrets.apiKey, to: &request)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                DeepSeekWebLoginController.debugLog("public balance failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")
                return ProviderUsageSnapshot.unavailable(config: config, message: "HTTP \(httpResponse.statusCode)")
            }

            let usages = try DeepSeekUsageParser().parsePublicBalance(data: data)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                usages: usages,
                state: .ready,
                statusMessage: "DeepSeek API balance",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func fetchUsageBundle(session: DeepSeekWebSessionCredential, period: DeepSeekUsagePeriod) async throws -> Data {
        async let summary = fetchPlatformData(session: session, path: "/api/v0/users/get_user_summary", query: [:])
        async let amount = fetchPlatformData(
            session: session,
            path: "/api/v0/usage/amount",
            query: ["month": "\(period.month)", "year": "\(period.year)"]
        )
        async let cost = fetchPlatformData(
            session: session,
            path: "/api/v0/usage/cost",
            query: ["month": "\(period.month)", "year": "\(period.year)"]
        )

        return try bundle(
            summary: try await summary,
            amount: try await amount,
            cost: try await cost
        )
    }

    private func fetchPlatformData(
        session: DeepSeekWebSessionCredential,
        path: String,
        query: [String: String]
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "platform.deepseek.com"
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        applySessionAuthentication(session, to: &request)

        DeepSeekWebLoginController.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            DeepSeekWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")
            throw DeepSeekWebLoginController.LoginError.requestFailed("DeepSeek HTTP \(httpResponse.statusCode): \(body.prefix(160))")
        }
        DeepSeekWebLoginController.debugLog("native request succeeded, path=\(path), bytes=\(data.count)")
        return data
    }

    private func bundle(summary: Data, amount: Data, cost: Data) throws -> Data {
        let object: [String: Any] = [
            "summary": try jsonObject(from: summary),
            "amount": try jsonObject(from: amount),
            "cost": try jsonObject(from: cost)
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func jsonObject(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func applySessionAuthentication(_ session: DeepSeekWebSessionCredential, to request: inout URLRequest) {
        if let accessToken = session.accessToken, !accessToken.isEmpty {
            if accessToken.lowercased().hasPrefix("bearer ") {
                request.setValue(accessToken, forHTTPHeaderField: "Authorization")
            } else {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
        }
        if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
    }

    private func applyAPIAuthentication(_ apiKey: String, to request: inout URLRequest) {
        if apiKey.lowercased().hasPrefix("bearer ") {
            request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }
}

struct DeepSeekUsagePeriod {
    let year: Int
    let month: Int
    let day: String

    static func currentUTC(now: Date = Date()) -> DeepSeekUsagePeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        return DeepSeekUsagePeriod(year: year, month: month, day: formatter.string(from: now))
    }
}

struct DeepSeekUsageParser {
    func parsePublicBalance(data: Data) throws -> [TokenUsage] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }
        let infos = root["balance_infos"] as? [[String: Any]] ?? []
        let usages = infos.compactMap { balanceUsage(from: $0) }
        guard !usages.isEmpty else {
            throw ParserError.noBalance
        }
        return usages
    }

    func parsePlatformBundle(data: Data, today: String) throws -> [TokenUsage] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }

        let summary = root["summary"] as? [String: Any]
        let amount = root["amount"] as? [String: Any]
        let cost = root["cost"] as? [String: Any]

        try [summary, amount, cost].forEach { item in
            if let item {
                try validateAPIResponse(item)
            }
        }

        var usages: [TokenUsage] = []
        if let summary {
            usages.append(contentsOf: parseSummaryBalances(root: summary))
        }
        if let amount {
            usages.append(contentsOf: parseTodayAmounts(root: amount, today: today))
        }
        if let cost {
            usages.append(contentsOf: parseTodayCosts(root: cost, today: today))
        }

        guard !usages.isEmpty else {
            throw ParserError.noUsage
        }
        return usages
    }

    private func parseSummaryBalances(root: [String: Any]) -> [TokenUsage] {
        guard let bizData = bizData(from: root) else {
            return []
        }

        var totals: [String: Decimal] = [:]
        for key in ["normal_wallets", "bonus_wallets"] {
            let wallets = bizData[key] as? [[String: Any]] ?? []
            for wallet in wallets {
                guard let currency = stringValue(wallet["currency"]), !currency.isEmpty,
                      let balance = decimalValue(wallet["balance"]) else {
                    continue
                }
                totals[currency, default: Decimal(0)] += balance
            }
        }

        return totals.keys.sorted().map { currency in
            let balance = totals[currency] ?? Decimal(0)
            return TokenUsage(
                window: .balance,
                label: "Balance \(currency)",
                used: 0,
                limit: nil,
                resetDate: nil,
                unit: currency,
                displayValue: moneyText(balance, currency: currency, minimumFractionDigits: 2)
            )
        }
    }

    private func parseTodayAmounts(root: [String: Any], today: String) -> [TokenUsage] {
        guard let dataObject = usageDataObject(from: root) else {
            return []
        }

        let dayItems = dayData(in: dataObject, today: today)
        var totalRequests = 0
        var totalTokens = 0
        var modelRows: [(model: String, requests: Int, tokens: Int)] = []

        for item in dayItems {
            let model = stringValue(item["model"]) ?? "Unknown"
            let requests = intUsageAmount(in: item, type: "REQUEST")
            let tokens = intUsageAmount(in: item, type: "RESPONSE_TOKEN")
                + intUsageAmount(in: item, type: "PROMPT_CACHE_MISS_TOKEN")
                + intUsageAmount(in: item, type: "PROMPT_CACHE_HIT_TOKEN")
            totalRequests += requests
            totalTokens += tokens
            if requests > 0 || tokens > 0 {
                modelRows.append((model: model, requests: requests, tokens: tokens))
            }
        }

        var usages = [
            TokenUsage(window: .todayTokens, label: "Today tokens total", used: totalTokens, limit: nil, resetDate: nil, unit: "tokens"),
            TokenUsage(window: .todayRequests, label: "Today requests total", used: totalRequests, limit: nil, resetDate: nil, unit: "requests")
        ]

        for row in modelRows.sorted(by: { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }) {
            if row.tokens > 0 {
                usages.append(TokenUsage(window: .todayTokens, label: "Today \(row.model) tokens", used: row.tokens, limit: nil, resetDate: nil, unit: "tokens"))
            }
            if row.requests > 0 {
                usages.append(TokenUsage(window: .todayRequests, label: "Today \(row.model) requests", used: row.requests, limit: nil, resetDate: nil, unit: "requests"))
            }
        }

        return usages
    }

    private func parseTodayCosts(root: [String: Any], today: String) -> [TokenUsage] {
        let currencyItems = costCurrencyItems(from: root)
        var usages: [TokenUsage] = []

        for currencyItem in currencyItems {
            let currency = stringValue(currencyItem["currency"]) ?? "CNY"
            let dayItems = dayData(in: currencyItem, today: today)
            var total = Decimal(0)
            var modelRows: [(model: String, cost: Decimal)] = []

            for item in dayItems {
                let model = stringValue(item["model"]) ?? "Unknown"
                let cost = sumUsageAmounts(in: item)
                total += cost
                if cost > Decimal(0) {
                    modelRows.append((model: model, cost: cost))
                }
            }

            usages.append(TokenUsage(
                window: .todayCost,
                label: "Today cost total \(currency)",
                used: 0,
                limit: nil,
                resetDate: nil,
                unit: currency,
                displayValue: moneyText(total, currency: currency, minimumFractionDigits: 4)
            ))

            for row in modelRows.sorted(by: { $0.cost == $1.cost ? $0.model < $1.model : $0.cost > $1.cost }) {
                usages.append(TokenUsage(
                    window: .todayCost,
                    label: "Today \(row.model) cost \(currency)",
                    used: 0,
                    limit: nil,
                    resetDate: nil,
                    unit: currency,
                    displayValue: moneyText(row.cost, currency: currency, minimumFractionDigits: 4)
                ))
            }
        }

        return usages
    }

    private func balanceUsage(from info: [String: Any]) -> TokenUsage? {
        guard let currency = stringValue(info["currency"]),
              let totalBalance = decimalValue(info["total_balance"]) else {
            return nil
        }
        return TokenUsage(
            window: .balance,
            label: "Balance \(currency)",
            used: 0,
            limit: nil,
            resetDate: nil,
            unit: currency,
            displayValue: moneyText(totalBalance, currency: currency, minimumFractionDigits: 2)
        )
    }

    private func validateAPIResponse(_ root: [String: Any]) throws {
        guard let code = root["code"] else {
            return
        }
        let codeText = String(describing: code)
        if codeText != "0" && codeText != "200" {
            throw ParserError.apiError(codeText)
        }
    }

    private func bizData(from root: [String: Any]) -> [String: Any]? {
        guard let data = root["data"] as? [String: Any] else {
            return root["biz_data"] as? [String: Any] ?? root
        }
        return data["biz_data"] as? [String: Any] ?? data
    }

    private func usageDataObject(from root: [String: Any]) -> [String: Any]? {
        guard let bizData = bizData(from: root) else {
            return nil
        }
        return bizData["data"] as? [String: Any] ?? bizData
    }

    private func costCurrencyItems(from root: [String: Any]) -> [[String: Any]] {
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

    private func dayData(in dataObject: [String: Any], today: String) -> [[String: Any]] {
        let days = dataObject["days"] as? [[String: Any]] ?? []
        guard let day = days.first(where: { (stringValue($0["date"]) ?? "").hasPrefix(today) }) else {
            return []
        }
        return day["data"] as? [[String: Any]] ?? []
    }

    private func intUsageAmount(in item: [String: Any], type: String) -> Int {
        guard let usage = item["usage"] as? [[String: Any]],
              let amount = usage.first(where: { stringValue($0["type"]) == type }).flatMap({ decimalValue($0["amount"]) }) else {
            return 0
        }
        return max(0, NSDecimalNumber(decimal: amount).intValue)
    }

    private func sumUsageAmounts(in item: [String: Any]) -> Decimal {
        guard let usage = item["usage"] as? [[String: Any]] else {
            return Decimal(0)
        }
        return usage.reduce(Decimal(0)) { partial, entry in
            partial + (decimalValue(entry["amount"]) ?? Decimal(0))
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
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

    private func moneyText(_ amount: Decimal, currency: String, minimumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = 8
        let text = formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
        return "\(text) \(currency)"
    }

    enum ParserError: LocalizedError {
        case invalidShape
        case noBalance
        case noUsage
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidShape:
                "Expected a JSON object"
            case .noBalance:
                "No DeepSeek balance data found"
            case .noUsage:
                "No DeepSeek usage data found"
            case let .apiError(code):
                "DeepSeek API error: \(code)"
            }
        }
    }
}
