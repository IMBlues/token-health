import Foundation

struct VolcengineArkUsageProvider: UsageProvider {
    private let consoleOrigin = "https://console.volcengine.com"
    private let agentPlanReferer = "https://console.volcengine.com/ark/region:cn-beijing/subscription/agent-plan"

    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        guard let session = VolcengineArkWebSessionCredential.decode(from: secrets.apiKey), !session.isEmpty else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Login with Volcengine Ark")
        }

        do {
            let usageData: Data
            do {
                usageData = try await fetchAgentPlanAFPUsage(session: session)
            } catch {
                VolcengineArkWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                usageData = try await VolcengineArkWebLoginController.shared.fetchAFPUsageFromActiveSession()
            }

            let usages = try VolcengineArkUsageParser().parseAFPUsage(data: usageData)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: session.accountName ?? "Agent Plan",
                usages: usages,
                state: .ready,
                statusMessage: "Volcengine Ark Console",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func fetchAgentPlanAFPUsage(session: VolcengineArkWebSessionCredential) async throws -> Data {
        try await fetchTopAction(session: session, action: "GetAgentPlanAFPUsage", body: [:])
    }

    private func fetchTopAction(
        session: VolcengineArkWebSessionCredential,
        action: String,
        body: [String: Any]
    ) async throws -> Data {
        guard let url = URL(string: "\(consoleOrigin)/api/top/ark/cn-beijing/2024-01-01/\(action)?") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(consoleOrigin, forHTTPHeaderField: "Origin")
        request.setValue(agentPlanReferer, forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let csrfToken = session.csrfToken, !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "X-Csrf-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        VolcengineArkWebLoginController.debugLog("native request action=\(action), \(session.debugSummary)")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            VolcengineArkWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")
            throw VolcengineArkWebLoginController.LoginError.requestFailed("Volcengine Ark HTTP \(httpResponse.statusCode): \(body.prefix(160))")
        }

        try VolcengineArkUsageParser().validateResponseEnvelope(data: data)
        VolcengineArkWebLoginController.debugLog("native request succeeded, action=\(action), bytes=\(data.count)")
        return data
    }
}

struct VolcengineArkUsageParser {
    func parseAFPUsage(data: Data) throws -> [TokenUsage] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }
        try validateResponseEnvelope(root: root)

        let payload = payload(from: root)
        let periods: [(String, UsageWindow, String)] = [
            ("AFPFiveHour", .fiveHours, "5h AFP"),
            ("AFPWeekly", .week, "Week AFP"),
            ("AFPMonthly", .month, "Month AFP")
        ]

        let usages = periods.compactMap { key, window, label -> TokenUsage? in
            guard let item = payload[key] as? [String: Any] else {
                return nil
            }
            return quotaUsage(window: window, label: label, item: item)
        }

        guard !usages.isEmpty else {
            throw ParserError.noUsage
        }
        return usages
    }

    func validateResponseEnvelope(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserError.invalidShape
        }
        try validateResponseEnvelope(root: root)
    }

    private func validateResponseEnvelope(root: [String: Any]) throws {
        if let responseMetadata = root["ResponseMetadata"] as? [String: Any],
           let error = responseMetadata["Error"] as? [String: Any] {
            let code = stringValue(error["Code"]) ?? "Unknown"
            let message = stringValue(error["Message"]) ?? code
            throw ParserError.apiError(message)
        }
        if let code = stringValue(root["Code"]), code != "0", code != "200" {
            throw ParserError.apiError(stringValue(root["Message"]) ?? code)
        }
    }

    private func payload(from root: [String: Any]) -> [String: Any] {
        root["Result"] as? [String: Any]
            ?? root["result"] as? [String: Any]
            ?? root["Data"] as? [String: Any]
            ?? root["data"] as? [String: Any]
            ?? root
    }

    private func quotaUsage(window: UsageWindow, label: String, item: [String: Any]) -> TokenUsage? {
        let used = firstInt(item, keys: ["Used", "used", "Usage", "usage"]) ?? 0
        let limit = firstInt(item, keys: ["Quota", "quota", "Limit", "limit"])
        guard limit != nil || used > 0 else {
            return nil
        }

        return TokenUsage(
            window: window,
            label: label,
            used: used,
            limit: limit,
            resetDate: dateValue(item["ResetTime"] ?? item["resetTime"] ?? item["ResetAt"] ?? item["resetAt"]),
            unit: "AFP"
        )
    }

    private func firstInt(_ dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let int64 = value as? Int64 {
            return Int(int64)
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
            if let int = Int(normalized) {
                return int
            }
            if let double = Double(normalized) {
                return Int(double)
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        return String(describing: value)
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let int = intValue(value) {
            guard int > 0 else {
                return nil
            }
            let seconds = int > 9_999_999_999 ? Double(int) / 1000 : Double(int)
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = stringValue(value) else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
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
                "No Volcengine Ark AFP usage data found"
            case let .apiError(message):
                "Volcengine Ark API error: \(message)"
            }
        }
    }
}
