import Foundation

protocol UsageProvider: Sendable {
    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot
}

struct ProviderFactory {
    func provider(for config: ServiceConfig) -> any UsageProvider {
        switch config.providerKind {
        case .demo:
            DemoUsageProvider()
        case .genericHTTP:
            GenericHTTPUsageProvider()
        case .kimiCode:
            KimiCodeUsageProvider()
        case .zhipuCode:
            ZhipuCodeUsageProvider()
        case .deepSeek:
            DeepSeekUsageProvider()
        case .miniMax:
            MiniMaxUsageProvider()
        case .openAI, .anthropic, .cursor:
            switch config.authMode {
            case .api:
                KnownServiceAPIProvider()
            case .browserLogin:
                BrowserLoginUsageProvider()
            }
        }
    }
}

struct ZhipuCodeUsageProvider: UsageProvider {
    private let quotaEndpoint = "https://bigmodel.cn/api/monitor/usage/quota/limit?type=2"

    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        guard let session = ZhipuWebSessionCredential.decode(from: secrets.apiKey), !session.isEmpty else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Login with Zhipu")
        }

        do {
            let quotaData: Data
            do {
                quotaData = try await fetchUsageData(session: session, endpoint: quotaEndpoint)
            } catch {
                ZhipuWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                quotaData = try await ZhipuWebLoginController.shared.fetchUsageDataFromActiveSession()
            }

            let parser = ZhipuUsageParser()
            var usages = try parser.parse(data: quotaData)
            if let detailUsages = try? await fetchDetailUsages(session: session, parser: parser) {
                usages.append(contentsOf: detailUsages)
            }
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: session.planName ?? PlanNameExtractor().find(in: quotaData) ?? "团队套餐标准版",
                usages: usages,
                state: .ready,
                statusMessage: "Zhipu Web session",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func fetchDetailUsages(session: ZhipuWebSessionCredential, parser: ZhipuUsageParser) async throws -> [TokenUsage] {
        let range = sevenDayRange()
        var result: [TokenUsage] = []
        for type in ["2", "3"] {
            let modelURL = try usageURL(
                path: "/api/monitor/usage/model-usage",
                query: [
                    "startTime": range.start,
                    "endTime": range.end,
                    "type": type
                ]
            )
            let modelData = try await fetchUsageData(session: session, endpoint: modelURL.absoluteString)
            let modelUsage = parser.parseModelUsage(data: modelData)
            if !modelUsage.isEmpty {
                result.append(contentsOf: modelUsage)
                break
            }
        }

        for type in ["2", "3"] {
            let toolURL = try usageURL(
                path: "/api/monitor/usage/tool-usage",
                query: [
                    "startTime": range.start,
                    "endTime": range.end,
                    "type": type
                ]
            )
            let toolData = try await fetchUsageData(session: session, endpoint: toolURL.absoluteString)
            let toolUsage = parser.parseToolUsage(data: toolData)
            if !toolUsage.isEmpty {
                result.append(contentsOf: toolUsage)
                break
            }
        }
        return result
    }

    private func fetchUsageData(session: ZhipuWebSessionCredential, endpoint: String) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("zh", forHTTPHeaderField: "Set-Language")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")

        if let accessToken = session.accessToken, !accessToken.isEmpty {
            request.setValue(accessToken, forHTTPHeaderField: "Authorization")
        }
        if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let organizationID = session.organizationID, !organizationID.isEmpty {
            request.setValue(organizationID, forHTTPHeaderField: "Bigmodel-Organization")
        }
        if let projectID = session.projectID, !projectID.isEmpty {
            request.setValue(projectID, forHTTPHeaderField: "Bigmodel-Project")
        }

        ZhipuWebLoginController.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            ZhipuWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")
            throw ZhipuWebLoginController.LoginError.requestFailed("Zhipu HTTP \(httpResponse.statusCode): \(body.prefix(160))")
        }
        ZhipuWebLoginController.debugLog("native request succeeded, bytes=\(data.count)")
        if endpoint.contains("/monitor/usage/quota/limit") {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            ZhipuWebLoginController.debugLog("quota body=\(body.prefix(1000))")
        }
        return data
    }

    private func usageURL(path: String, query: [String: String]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "bigmodel.cn"
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func sevenDayRange() -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.timeZone = timeZone
        let now = Date()
        let endOfToday = calendar.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: now
        ) ?? now
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (formatter.string(from: start), formatter.string(from: endOfToday))
    }
}

struct ZhipuUsageParser {
    func parse(data: Data) throws -> [TokenUsage] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }

        if let code = root["code"], String(describing: code) != "200" && String(describing: code) != "0" {
            throw ParserError.apiError(String(describing: code))
        }

        let dataObject = root["data"] ?? root
        let limits = findLimits(in: dataObject)
        guard !limits.isEmpty else {
            ZhipuWebLoginController.debugLog("parser found no limits in body=\(responsePreview(data))")
            throw ParserError.noUsage
        }

        var result: [TokenUsage] = []
        let tokenLimits = limits.filter { stringValue($0["type"]).uppercased().contains("TOKEN") }
        let candidates = tokenLimits.isEmpty ? limits : tokenLimits

        if let fiveHours = candidates.first(where: isFiveHourLimit),
           let usage = quotaUsage(.fiveHours, item: fiveHours) {
            result.append(usage)
        }
        if let week = candidates.first(where: isWeekLimit),
           let usage = quotaUsage(.week, item: week) {
            result.append(usage)
        }
        if let mcpMonth = limits.first(where: isMCPMonthLimit),
           let usage = quotaUsage(.mcpMonth, item: mcpMonth) {
            result.append(usage)
        }

        if result.isEmpty {
            let fallback = candidates.prefix(2).enumerated().compactMap { index, item in
                quotaUsage(index == 0 ? .fiveHours : .week, item: item)
            }
            result.append(contentsOf: fallback)
        }

        guard !result.isEmpty else {
            let keySummary = candidates.map { $0.keys.sorted().joined(separator: "|") }.joined(separator: ",")
            ZhipuWebLoginController.debugLog("parser could not map limits keys=\(keySummary), body=\(responsePreview(data))")
            throw ParserError.noUsage
        }
        return result
    }

    func parseModelUsage(data: Data) -> [TokenUsage] {
        guard let root = jsonRoot(data), let payload = payload(from: root) else {
            ZhipuWebLoginController.debugLog("model parser invalid body=\(responsePreview(data))")
            return []
        }

        var result: [TokenUsage] = []
        let total = intValue((payload["totalUsage"] as? [String: Any])?["totalTokensUsage"])
            ?? sumArray(payload["tokensUsage"])
        if let total, total > 0 {
            result.append(TokenUsage(window: .sevenDaysTokens, label: "7d Token total", used: total, limit: nil, resetDate: nil, unit: "tokens"))
        }

        let summaries = payload["modelSummaryList"] as? [[String: Any]] ?? []
        let topModels = summaries
            .compactMap { item -> TokenUsage? in
                guard let name = firstString(item, keys: ["modelName", "name", "model"]),
                      let used = firstInt(item, keys: ["totalTokens", "totalUsage", "tokens", "usage"]) else {
                    return nil
                }
                return TokenUsage(window: .sevenDaysTokens, label: "7d \(name)", used: used, limit: nil, resetDate: nil, unit: "tokens")
            }
            .sorted { $0.used > $1.used }
            .prefix(3)
        result.append(contentsOf: topModels)

        if result.isEmpty {
            ZhipuWebLoginController.debugLog("model parser found no usage body=\(responsePreview(data))")
        }
        return result
    }

    func parseToolUsage(data: Data) -> [TokenUsage] {
        guard let root = jsonRoot(data), let payload = payload(from: root) else {
            ZhipuWebLoginController.debugLog("tool parser invalid body=\(responsePreview(data))")
            return []
        }

        var result: [TokenUsage] = []
        let total = intValue((payload["totalUsage"] as? [String: Any])?["totalSearchMcpCount"])
            ?? intValue((payload["totalUsage"] as? [String: Any])?["totalUsageCount"])
            ?? sumArray(payload["usageCount"])
        if let total, total > 0 {
            result.append(TokenUsage(window: .sevenDaysTools, label: "7d Tool calls", used: total, limit: nil, resetDate: nil, unit: "calls"))
        }

        let summaries = payload["toolSummaryList"] as? [[String: Any]] ?? []
        let topTools = summaries
            .compactMap { item -> TokenUsage? in
                guard let name = firstString(item, keys: ["toolName", "name", "mcpName"]),
                      let used = firstInt(item, keys: ["totalUsageCount", "usageCount", "count", "total"]) else {
                    return nil
                }
                return TokenUsage(window: .sevenDaysTools, label: "7d \(name)", used: used, limit: nil, resetDate: nil, unit: "calls")
            }
            .sorted { $0.used > $1.used }
            .prefix(3)
        result.append(contentsOf: topTools)

        return result
    }

    private func quotaUsage(_ window: UsageWindow, item: [String: Any]) -> TokenUsage? {
        let total = firstInt(item, keys: ["limit", "total", "totalLimit", "quota", "usage", "limitCount", "totalCount", "max"])
        let remaining = firstInt(item, keys: ["remaining", "remain", "left", "available", "balance"])
        let explicitUsed = firstInt(item, keys: ["used", "usedTokens", "usageCount", "consumed", "consumedTokens"])
        let percentage = firstDouble(item, keys: ["percentage", "percent", "usedPercent", "usagePercent", "rate"])
        let inferredTotal = total ?? {
            guard let remaining, let percentage, percentage < 100 else {
                return nil
            }
            return Int((Double(remaining) / max(0.0001, 1 - percentage / 100)).rounded())
        }()
        let used = explicitUsed ?? {
            if let total, let remaining {
                return max(0, total - remaining)
            }
            if let inferredTotal, let remaining {
                return max(0, inferredTotal - remaining)
            }
            if let inferredTotal, let percentage {
                return max(0, Int((Double(inferredTotal) * percentage / 100).rounded()))
            }
            if let total, let percentage {
                return max(0, Int((Double(total) * percentage / 100).rounded()))
            }
            if let percentage {
                return max(0, Int(percentage.rounded()))
            }
            return nil
        }()

        guard let used else {
            return nil
        }

        let displayedLimit = inferredTotal ?? total ?? (percentage == nil ? nil : 100)
        return TokenUsage(
            window: window,
            used: used,
            limit: displayedLimit,
            resetDate: dateValue(item["nextResetTime"]) ?? dateValue(item["resetTime"]),
            unit: displayedLimit == 100 && total == nil && inferredTotal == nil ? "%" : (window == .mcpMonth ? "calls" : "tokens")
        )
    }

    private func jsonRoot(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private func payload(from root: [String: Any]) -> [String: Any]? {
        root["data"] as? [String: Any] ?? root
    }

    private func findLimits(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            if let limits = dictionary["limits"] as? [[String: Any]] {
                return limits
            }
            if let limits = dictionary["limits"] as? [String: Any] {
                let found = findLimits(in: limits)
                if !found.isEmpty {
                    return found
                }
            }
            if isLimitLike(dictionary) {
                return [dictionary]
            }
            for child in dictionary.values {
                let found = findLimits(in: child)
                if !found.isEmpty {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            if let dictionaries = array as? [[String: Any]],
               dictionaries.contains(where: { $0["type"] != nil || $0["unit"] != nil }) {
                return dictionaries
            }
            for child in array {
                let found = findLimits(in: child)
                if !found.isEmpty {
                    return found
                }
            }
        }

        return []
    }

    private func isLimitLike(_ dictionary: [String: Any]) -> Bool {
        let keys = Set(dictionary.keys.map { $0.lowercased() })
        return keys.contains("percentage")
            || keys.contains("percent")
            || keys.contains("remaining")
            || keys.contains("nextresettime")
            || (keys.contains("type") && keys.contains("unit"))
    }

    private func isFiveHourLimit(_ item: [String: Any]) -> Bool {
        let unit = stringValue(item["unit"]).uppercased()
        return intValue(item["unit"]) == 3
            || unit.contains("5")
            || unit.contains("HOUR")
            || stringValue(item["title"]).contains("5")
    }

    private func isWeekLimit(_ item: [String: Any]) -> Bool {
        let unit = stringValue(item["unit"]).uppercased()
        return intValue(item["unit"]) == 6
            || unit.contains("WEEK")
            || stringValue(item["title"]).contains("周")
    }

    private func isMCPMonthLimit(_ item: [String: Any]) -> Bool {
        let type = stringValue(item["type"]).uppercased()
        let title = stringValue(item["title"]).uppercased()
        return (type.contains("TIME") || title.contains("MCP"))
            && (intValue(item["unit"]) == 5 || title.contains("MCP"))
    }

    private func stringValue(_ value: Any?) -> String {
        String(describing: value ?? "")
    }

    private func firstInt(_ dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private func firstDouble(_ dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private func sumArray(_ value: Any?) -> Int? {
        guard let array = value as? [Any] else {
            return nil
        }
        let sum = array.reduce(0) { partial, item in
            partial + (intValue(item) ?? 0)
        }
        return sum > 0 ? sum : nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            if let int = Int(string) {
                return int
            }
            if let double = doubleValue(string) {
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
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    private func responsePreview(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        return String(text.prefix(800))
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
                "No Zhipu Coding usage data found"
            case let .apiError(code):
                "Zhipu API error: \(code)"
            }
        }
    }
}

struct KimiCodeUsageProvider: UsageProvider {
    private let defaultConsoleUsageEndpoint = "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"

    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        switch config.authMode {
        case .api:
            let endpoint = config.apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if endpoint.isEmpty || endpoint.contains("BillingService/GetUsages") {
                if let session = KimiWebSessionCredential.decode(from: secrets.apiKey) {
                    KimiWebUsageBridge.debugLog("stored Kimi session found, trying native request first: \(session.debugSummary)")
                    let nativeSnapshot = await fetchConsoleUsage(config: config, secrets: secrets, endpoint: endpoint)
                    if nativeSnapshot.state == .ready {
                        return nativeSnapshot
                    }
                    KimiWebUsageBridge.debugLog("native request failed: \(nativeSnapshot.statusMessage); falling back to active WebView")
                    return await fetchConsoleUsageViaWebView(config: config, secrets: secrets)
                }
                return await fetchConsoleUsage(config: config, secrets: secrets, endpoint: endpoint)
            }
            return await GenericHTTPUsageProvider().fetchUsage(config: config, secrets: secrets)
        case .browserLogin:
            do {
                let localStore = KimiCodeLocalUsageStore()
                let (usages, source) = try localStore.loadUsage(preferredPath: config.usageDataPath)
                return ProviderUsageSnapshot(
                    id: config.id,
                    serviceName: config.displayName,
                    providerTitle: config.providerKind.title,
                    usages: usages,
                    state: .ready,
                    statusMessage: "Local data: \(source.lastPathComponent)",
                    updatedAt: Date()
                )
            } catch {
                return ProviderUsageSnapshot.unavailable(
                    config: config,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func fetchConsoleUsage(
        config: ServiceConfig,
        secrets: ProviderSecrets,
        endpoint: String
    ) async -> ProviderUsageSnapshot {
        guard !secrets.apiKey.isEmpty else {
            return ProviderUsageSnapshot.unavailable(
                config: config,
                message: "Paste Kimi web bearer token or use Login mode"
            )
        }

        guard let url = URL(string: endpoint.isEmpty ? defaultConsoleUsageEndpoint : endpoint) else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Invalid endpoint")
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyKimiAuthentication(secrets.apiKey, to: &request)
            request.httpBody = Data(#"{"scope":["FEATURE_CODING"]}"#.utf8)
            if let session = KimiWebSessionCredential.decode(from: secrets.apiKey) {
                KimiWebUsageBridge.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                KimiWebUsageBridge.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")
                return ProviderUsageSnapshot.unavailable(config: config, message: "HTTP \(httpResponse.statusCode)")
            }

            KimiWebUsageBridge.debugLog("native request succeeded, bytes=\(data.count)")
            if ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1",
               let body = String(data: data, encoding: .utf8) {
                KimiWebUsageBridge.debugLog("native response body=\(body.prefix(1200))")
            }
            let usages = try KimiCodeBillingParser().parse(data: data)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: PlanNameExtractor().find(in: data) ?? KimiWebSessionCredential.decode(from: secrets.apiKey)?.planName ?? "Allegretto",
                usages: usages,
                state: .ready,
                statusMessage: "Kimi Console",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func fetchConsoleUsageViaWebView(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        do {
            let data: Data
            do {
                data = try await KimiWebLoginController.shared.fetchUsageDataFromActiveSession()
            } catch {
                KimiWebUsageBridge.debugLog("active session fetch failed: \(error.localizedDescription); falling back to hidden WebView")
                data = try await KimiWebUsageBridge.shared.fetchUsageData()
            }
            if ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1",
               let body = String(data: data, encoding: .utf8) {
                KimiWebUsageBridge.debugLog("web response body=\(body.prefix(1200))")
            }
            let usages = try KimiCodeBillingParser().parse(data: data)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: KimiWebSessionCredential.decode(from: secrets.apiKey)?.planName ?? PlanNameExtractor().find(in: data) ?? "Allegretto",
                usages: usages,
                state: .ready,
                statusMessage: "Kimi Web session",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func applyKimiAuthentication(_ credential: String, to request: inout URLRequest) {
        if let session = KimiWebSessionCredential.decode(from: credential) {
            if let accessToken = session.accessToken, !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            if let trafficID = session.trafficID, !trafficID.isEmpty {
                request.setValue(trafficID, forHTTPHeaderField: "X-Traffic-Id")
            }
            if let deviceID = session.deviceID, !deviceID.isEmpty {
                request.setValue(deviceID, forHTTPHeaderField: "x-msh-device-id")
            }
            if let sessionID = session.sessionID, !sessionID.isEmpty {
                request.setValue(sessionID, forHTTPHeaderField: "x-msh-session-id")
            }
            request.setValue("web", forHTTPHeaderField: "x-msh-platform")
            request.setValue("1.0.0", forHTTPHeaderField: "x-msh-version")
            request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "R-Timezone")
        } else if credential.hasPrefix("cookie:") {
            request.setValue(String(credential.dropFirst("cookie:".count)), forHTTPHeaderField: "Cookie")
        } else if credential.lowercased().hasPrefix("bearer ") {
            request.setValue(credential, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
    }
}

struct KimiCodeBillingParser {
    func parse(data: Data) throws -> [TokenUsage] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }
        if let code = root["code"] as? String {
            throw ParserError.apiError(code)
        }
        guard let usages = root["usages"] as? [[String: Any]],
              let codingUsage = usages.first(where: { scopeValue($0["scope"]) == "FEATURE_CODING" }) ?? usages.first else {
            throw ParserError.noUsage
        }

        var result: [TokenUsage] = []
        if let weeklyDetail = codingUsage["detail"] as? [String: Any],
           let weekly = quotaUsage(.week, detail: weeklyDetail, context: codingUsage) {
            result.append(weekly)
        }

        let limits = codingUsage["limits"] as? [[String: Any]] ?? []
        if let fiveHourLimit = limits.first(where: isFiveHourLimit),
           let detail = fiveHourLimit["detail"] as? [String: Any],
           let fiveHours = quotaUsage(.fiveHours, detail: detail, context: fiveHourLimit) {
            result.append(fiveHours)
        } else if let firstLimit = limits.first,
                  let detail = firstLimit["detail"] as? [String: Any],
                  let fiveHours = quotaUsage(.fiveHours, detail: detail, context: firstLimit) {
            result.append(fiveHours)
        }

        guard !result.isEmpty else {
            throw ParserError.noUsage
        }
        return result
    }

    private func isFiveHourLimit(_ limit: [String: Any]) -> Bool {
        guard let window = limit["window"] as? [String: Any] else {
            return false
        }
        let duration = intValue(window["duration"]) ?? 0
        let timeUnit = String(describing: window["timeUnit"] ?? "").uppercased()
        return duration == 5 && timeUnit.contains("HOUR")
    }

    private func quotaUsage(_ window: UsageWindow, detail: [String: Any], context: [String: Any]) -> TokenUsage? {
        guard let limit = intValue(detail["limit"]) else {
            return nil
        }
        let used = intValue(detail["used"]) ?? max(0, limit - (intValue(detail["remaining"]) ?? limit))
        let reset = resetDate(in: detail) ?? resetDate(in: context)
        if reset == nil {
            KimiWebUsageBridge.debugLog("parser found no reset for \(window.title), detailKeys=\(Array(detail.keys).sorted()), contextKeys=\(Array(context.keys).sorted())")
        }
        return TokenUsage(
            window: window,
            used: used,
            limit: limit,
            resetDate: reset,
            unit: limit == 100 ? "%" : "tokens"
        )
    }

    private func scopeValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let int = value as? Int, int == 4 {
            return "FEATURE_CODING"
        }
        return ""
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private func resetDate(in value: Any) -> Date? {
        if let dictionary = value as? [String: Any] {
            for key in resetDateKeys {
                if let date = dateValue(dictionary[key]) {
                    return date
                }
            }

            for (key, child) in dictionary where isResetDateKey(key) {
                if let date = dateValue(child) ?? resetDate(in: child) {
                    return date
                }
            }

            for child in dictionary.values {
                if let date = resetDate(in: child) {
                    return date
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let date = resetDate(in: child) {
                    return date
                }
            }
        }

        return nil
    }

    private var resetDateKeys: [String] {
        [
            "nextResetTime",
            "next_reset_time",
            "nextResetAt",
            "next_reset_at",
            "resetTime",
            "reset_time",
            "resetAt",
            "reset_at",
            "refreshTime",
            "refresh_time",
            "refreshAt",
            "refresh_at",
            "recoverTime",
            "recover_time",
            "recoverAt",
            "recover_at",
            "expiresAt",
            "expires_at",
            "expireAt",
            "expire_at"
        ]
    }

    private func isResetDateKey(_ key: String) -> Bool {
        let normalized = key
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return (normalized.contains("reset")
            || normalized.contains("refresh")
            || normalized.contains("recover")
            || normalized.contains("expire"))
            && (normalized.contains("time") || normalized.contains("at"))
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let string = stringValue(value) {
            return dateValue(from: string)
        }

        if let int = intValue(value) {
            return dateValue(fromTimestamp: int)
        }

        if let double = value as? Double {
            return dateValue(fromTimestamp: Int(double))
        }

        guard let dictionary = value as? [String: Any],
              let seconds = intValue(dictionary["seconds"] ?? dictionary["_seconds"]) else {
            return nil
        }

        let nanos = intValue(dictionary["nanos"] ?? dictionary["_nanoseconds"]) ?? 0
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }

    private func dateValue(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let int = Int(trimmed) {
            return dateValue(fromTimestamp: int)
        }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func dateValue(fromTimestamp timestamp: Int) -> Date? {
        guard timestamp > 0 else {
            return nil
        }
        let seconds = timestamp > 9_999_999_999 ? Double(timestamp) / 1000 : Double(timestamp)
        return Date(timeIntervalSince1970: seconds)
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
                "No Kimi Code usage data found"
            case let .apiError(code):
                "Kimi API error: \(code)"
            }
        }
    }
}

struct KimiCodeLocalUsageStore {
    func loadUsage(preferredPath: String) throws -> ([TokenUsage], URL) {
        let candidates = candidateURLs(preferredPath: preferredPath)
        for url in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                if let result = try loadFirstUsableJSON(in: url) {
                    return result
                }
            } else if let usages = try? loadUsageFile(url), !usages.isEmpty {
                return (usages, url)
            }
        }

        throw LocalUsageError.notFound
    }

    private func loadFirstUsableJSON(in directory: URL) throws -> ([TokenUsage], URL)? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var scanned = 0
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension.lowercased() == "json" else {
                continue
            }
            scanned += 1
            if scanned > 250 {
                break
            }
            if let usages = try? loadUsageFile(fileURL), !usages.isEmpty {
                return (usages, fileURL)
            }
        }
        return nil
    }

    private func loadUsageFile(_ url: URL) throws -> [TokenUsage] {
        let data = try Data(contentsOf: url)
        return try UsageJSONParser().parse(data: data)
    }

    private func candidateURLs(preferredPath: String) -> [URL] {
        var urls: [URL] = []
        let trimmedPath = preferredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            urls.append(expandedURL(trimmedPath))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(contentsOf: [
            home.appendingPathComponent(".kimi/usage.json"),
            home.appendingPathComponent(".kimi/quota.json"),
            home.appendingPathComponent(".kimi-code/usage.json"),
            home.appendingPathComponent(".kimi-code/quota.json"),
            home.appendingPathComponent(".config/kimi/usage.json"),
            home.appendingPathComponent(".config/kimi-code/usage.json"),
            home.appendingPathComponent("Library/Application Support/Kimi Code/usage.json"),
            home.appendingPathComponent("Library/Application Support/Kimi Code"),
            home.appendingPathComponent("Library/Application Support/kimi-code/usage.json"),
            home.appendingPathComponent("Library/Application Support/kimi-code")
        ])
        return urls
    }

    private func expandedURL(_ path: String) -> URL {
        if path.hasPrefix("~") {
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            let suffix = path.dropFirst()
            return URL(fileURLWithPath: homePath + suffix)
        }
        return URL(fileURLWithPath: path)
    }

    enum LocalUsageError: LocalizedError {
        case notFound

        var errorDescription: String? {
            "Kimi Code local usage JSON not found"
        }
    }
}

struct DemoUsageProvider: UsageProvider {
    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        let seed = abs(config.id.uuidString.hashValue)
        let fiveUsed = 8_000 + seed % 42_000
        let weekUsed = 120_000 + seed % 460_000
        return ProviderUsageSnapshot(
            id: config.id,
            serviceName: config.displayName,
            providerTitle: config.providerKind.title,
            usages: [
                TokenUsage(window: .fiveHours, used: fiveUsed, limit: 50_000, resetDate: Date().addingTimeInterval(60 * 60 * 2)),
                TokenUsage(window: .week, used: weekUsed, limit: 900_000, resetDate: Date().addingTimeInterval(60 * 60 * 24 * 3))
            ],
            state: .ready,
            statusMessage: "Demo data",
            updatedAt: Date()
        )
    }
}

struct KnownServiceAPIProvider: UsageProvider {
    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        guard !secrets.apiKey.isEmpty else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "API key missing")
        }

        guard !config.apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ProviderUsageSnapshot.unavailable(
                config: config,
                message: "Add an API usage endpoint for this provider"
            )
        }

        return await GenericHTTPUsageProvider().fetchUsage(config: config, secrets: secrets)
    }
}

struct BrowserLoginUsageProvider: UsageProvider {
    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        let hasCredentials = !config.username.isEmpty && !secrets.password.isEmpty
        return ProviderUsageSnapshot.unavailable(
            config: config,
            message: hasCredentials ? "Login adapter not connected yet" : "Login credentials missing"
        )
    }
}

struct GenericHTTPUsageProvider: UsageProvider {
    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        guard let url = URL(string: config.apiEndpoint), !config.apiEndpoint.isEmpty else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Endpoint missing")
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !secrets.apiKey.isEmpty {
                request.setValue("Bearer \(secrets.apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                return ProviderUsageSnapshot.unavailable(
                    config: config,
                    message: "HTTP \(httpResponse.statusCode)"
                )
            }

            let usages = try UsageJSONParser().parse(data: data)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                usages: usages,
                state: .ready,
                statusMessage: "Updated",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(
                config: config,
                message: error.localizedDescription
            )
        }
    }
}

struct UsageJSONParser {
    func parse(data: Data) throws -> [TokenUsage] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }

        let direct: [TokenUsage] = UsageWindow.quotaWindows.compactMap { window in
            let key = window == .fiveHours ? "fiveHours" : "week"
            let snakeKey = window == .fiveHours ? "five_hours" : "week"
            let shortKey = window == .fiveHours ? "5h" : "weekly"
            let usedPaths = [
                [key, "used"],
                [snakeKey, "used"],
                [shortKey, "used"],
                ["usage", key, "used"],
                ["usage", snakeKey, "used"],
                ["usage", shortKey, "used"],
                ["\(key)Used"],
                ["\(snakeKey)_used"],
                ["\(shortKey)_used"]
            ]
            let used = firstIntValue(root, paths: usedPaths)
            guard let used else {
                return nil
            }

            let limitPaths = [
                [key, "limit"],
                [snakeKey, "limit"],
                [shortKey, "limit"],
                ["usage", key, "limit"],
                ["usage", snakeKey, "limit"],
                ["usage", shortKey, "limit"],
                ["\(key)Limit"],
                ["\(snakeKey)_limit"],
                ["\(shortKey)_limit"]
            ]
            let limit = firstIntValue(root, paths: limitPaths)

            let resetPaths = [
                [key, "resetAt"],
                [snakeKey, "reset_at"],
                [shortKey, "reset_at"],
                ["usage", key, "resetAt"],
                ["usage", snakeKey, "reset_at"],
                ["usage", shortKey, "reset_at"]
            ]
            let reset = firstStringValue(root, paths: resetPaths)

            return TokenUsage(
                window: window,
                used: used,
                limit: limit,
                resetDate: reset.flatMap { ISO8601DateFormatter().date(from: $0) }
            )
        }

        if !direct.isEmpty {
            return direct
        }

        let inferred = inferWindowUsage(from: root)
        if !inferred.isEmpty {
            return inferred
        }

        throw ParserError.noUsage
    }

    private func firstIntValue(_ root: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            if let value = intValue(root, path: path) {
                return value
            }
        }
        return nil
    }

    private func firstStringValue(_ root: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            if let value = stringValue(root, path: path) {
                return value
            }
        }
        return nil
    }

    private func intValue(_ root: [String: Any], path: [String]) -> Int? {
        guard let value = value(root, path: path) else {
            return nil
        }
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func stringValue(_ root: [String: Any], path: [String]) -> String? {
        value(root, path: path) as? String
    }

    private func value(_ root: [String: Any], path: [String]) -> Any? {
        path.reduce(root as Any?) { current, key in
            (current as? [String: Any])?[key]
        }
    }

    private func inferWindowUsage(from root: [String: Any]) -> [TokenUsage] {
        var results: [UsageWindow: TokenUsage] = [:]
        scan(root, keyPath: []) { keys, dictionary in
            guard let window = window(from: keys) else {
                return
            }
            let used = firstInt(dictionary, keys: [
                "used",
                "usage",
                "tokens",
                "total_tokens",
                "totalTokens",
                "used_tokens",
                "usedTokens",
                "consumed",
                "consumed_tokens",
                "consumedTokens"
            ]) ?? summedInt(dictionary, keys: [
                "input_tokens",
                "inputTokens",
                "output_tokens",
                "outputTokens",
                "cache_creation_input_tokens",
                "cacheReadInputTokens",
                "cache_read_input_tokens"
            ])
            guard let used else {
                return
            }

            let limit = firstInt(dictionary, keys: [
                "limit",
                "quota",
                "total",
                "max",
                "token_limit",
                "tokenLimit"
            ])
            let reset = firstString(dictionary, keys: [
                "resetAt",
                "reset_at",
                "resetTime",
                "reset_time",
                "expiresAt",
                "expires_at"
            ])

            results[window] = TokenUsage(
                window: window,
                used: used,
                limit: limit,
                resetDate: reset.flatMap { ISO8601DateFormatter().date(from: $0) }
            )
        }
        return UsageWindow.quotaWindows.compactMap { results[$0] }
    }

    private func scan(_ value: Any, keyPath: [String], visit: ([String], [String: Any]) -> Void) {
        if let dictionary = value as? [String: Any] {
            visit(keyPath, dictionary)
            for (key, child) in dictionary {
                scan(child, keyPath: keyPath + [key], visit: visit)
            }
        } else if let array = value as? [Any] {
            for child in array {
                scan(child, keyPath: keyPath, visit: visit)
            }
        }
    }

    private func window(from keyPath: [String]) -> UsageWindow? {
        let joined = keyPath.joined(separator: "_").lowercased()
        if joined.contains("fivehour")
            || joined.contains("five_hour")
            || joined.contains("5h")
            || joined.contains("5_hour")
            || joined.contains("rolling5") {
            return .fiveHours
        }
        if joined.contains("weekly")
            || joined.contains("week")
            || joined.contains("7d")
            || joined.contains("seven_day") {
            return .week
        }
        return nil
    }

    private func firstInt(_ dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let int = dictionary[key] as? Int {
                return int
            }
            if let double = dictionary[key] as? Double {
                return Int(double)
            }
            if let string = dictionary[key] as? String, let int = Int(string) {
                return int
            }
        }
        return nil
    }

    private func summedInt(_ dictionary: [String: Any], keys: [String]) -> Int? {
        let values = keys.compactMap { key -> Int? in
            if let int = dictionary[key] as? Int {
                return int
            }
            if let double = dictionary[key] as? Double {
                return Int(double)
            }
            if let string = dictionary[key] as? String {
                return Int(string)
            }
            return nil
        }
        guard !values.isEmpty else {
            return nil
        }
        return values.reduce(0, +)
    }

    private func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String {
                return string
            }
        }
        return nil
    }

    enum ParserError: LocalizedError {
        case invalidShape
        case noUsage

        var errorDescription: String? {
            switch self {
            case .invalidShape:
                "Expected a JSON object"
            case .noUsage:
                "No 5-hour or weekly usage fields found"
            }
        }
    }
}
