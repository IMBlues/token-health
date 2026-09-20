import Foundation

struct OpenCodeGoUsageProvider: UsageProvider {
    private static let providerTitle = "OpenCode Go"
    private let consoleHost = "console.opencode.ai"
    private let apiUsageEndpoint = "https://opencode.ai/zen/go/v1/usage"

    func fetchUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        if let session = OpenCodeGoWebSessionCredential.decode(from: secrets.apiKey), !session.isEmpty {
            return await fetchConsoleUsage(config: config, session: session)
        }

        if config.authMode == .browserLogin {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Login with OpenCode Go")
        }

        return await fetchAPIUsage(config: config, secrets: secrets)
    }

    private func fetchConsoleUsage(
        config: ServiceConfig,
        session: OpenCodeGoWebSessionCredential
    ) async -> ProviderUsageSnapshot {
        do {
            let bundleData: Data
            do {
                // Debug-only escape hatch for exercising the web-session fallback path; there is
                // no real native request behind this failure.
                if ProcessInfo.processInfo.environment["TOKEN_HEALTH_FORCE_WEB_FALLBACK"] == "1" {
                    WebSessionLog.debugLog("forced web fallback", providerTitle: Self.providerTitle)
                    throw WebSessionError.requestFailed(providerTitle: Self.providerTitle, message: "forced fallback")
                }
                bundleData = try await fetchUsageBundle(session: session)
            } catch {
                WebSessionLog.debugLog(
                    "native request failed: \(error.localizedDescription); falling back to own session",
                    providerTitle: Self.providerTitle
                )
                guard let controller = await WebSessionRegistry.shared.controller(for: config) else {
                    throw WebSessionError.unsupportedProvider
                }
                // The status endpoint takes no period parameters, so the context is intentionally
                // unused by its script.
                bundleData = try await controller.fetchUsage(
                    context: .currentUTC()
                )
            }

            let result = try OpenCodeGoUsageParser().parseBundle(data: bundleData)
            guard !result.usages.isEmpty else {
                return ProviderUsageSnapshot.unavailable(
                    config: config,
                    message: result.subscriptionMessage ?? "No OpenCode Go usage found"
                )
            }
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: result.planName ?? session.accountName,
                usages: result.usages,
                state: .ready,
                statusMessage: "OpenCode Go API",
                updatedAt: Date()
            )
        } catch {
            let message: String
            if let sessionError = error as? WebSessionError {
                switch sessionError {
                case .unsupportedProvider:
                    message = "OpenCode Go session is unavailable. Re-login with OpenCode Go."
                case let .requestFailed(_, text):
                    message = text.contains("401")
                        ? "OpenCode Go session expired. Re-login with OpenCode Go."
                        : text
                default:
                    message = sessionError.localizedDescription
                }
            } else {
                message = error.localizedDescription
            }
            return ProviderUsageSnapshot.unavailable(config: config, message: message)
        }
    }

    private func fetchAPIUsage(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        let apiKey = secrets.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Enter your OpenCode Go API key")
        }

        guard let url = URL(string: apiUsageEndpoint) else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Invalid usage endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        WebSessionLog.debugLog("API usage request endpoint=\(url.absoluteString)", providerTitle: Self.providerTitle)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                WebSessionLog.debugLog(
                    "API usage request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))",
                    providerTitle: Self.providerTitle
                )
                let message: String
                if httpResponse.statusCode == 401 {
                    message = "OpenCode Go API key rejected (401). Check the key in Settings."
                } else {
                    message = "OpenCode Go API HTTP \(httpResponse.statusCode): \(body.prefix(160))"
                }
                return ProviderUsageSnapshot.unavailable(config: config, message: message)
            }

            let result = try OpenCodeGoUsageParser().parseAPIResponse(data: data)
            guard !result.usages.isEmpty else {
                return ProviderUsageSnapshot.unavailable(
                    config: config,
                    message: result.subscriptionMessage ?? "No OpenCode Go usage returned by the API"
                )
            }
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: result.planName ?? "Go",
                usages: result.usages,
                state: .ready,
                statusMessage: "OpenCode Go API",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }

    private func fetchUsageBundle(session: OpenCodeGoWebSessionCredential) async throws -> Data {
        guard let url = URL(string: "https://\(consoleHost)/api/go/status") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        WebSessionLog.debugLog(
            "native request endpoint=\(url.absoluteString), \(session.debugSummary)",
            providerTitle: Self.providerTitle
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            WebSessionLog.debugLog(
                "native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))",
                providerTitle: Self.providerTitle
            )
            throw WebSessionError.requestFailed(
                providerTitle: Self.providerTitle,
                message: "OpenCode Go HTTP \(httpResponse.statusCode): \(body.prefix(160))"
            )
        }
        WebSessionLog.debugLog("native request succeeded, bytes=\(data.count)", providerTitle: Self.providerTitle)
        return data
    }
}

struct OpenCodeGoUsageParser {
    struct ParseResult {
        var planName: String?
        var subscriptionMessage: String?
        var usages: [TokenUsage]
    }

    private struct Meter {
        var kind: String
        var limitMicroCents: Int?
        var settledMicroCents: Int?
        var reservedMicroCents: Int?
        var remainingMicroCents: Int?
        var resetsAt: Date?
        var windowStartsAt: Date?
    }

    func parseBundle(data: Data) throws -> ParseResult {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParserError.invalidShape
        }

        // The WebView fallback returns a `{ok, status, ..., goStatus: {...}}` envelope while
        // the native request returns the GoStatus object itself. Normalize both to GoStatus.
        let goStatusRoot = (root["goStatus"] as? [String: Any]) ?? root

        let status = stringValue(goStatusRoot["subscriptionStatus"]) ?? "inactive"
        let currentPeriod = goStatusRoot["currentPeriod"] as? [String: Any]
        let meters = (goStatusRoot["meters"] as? [[String: Any]] ?? []).compactMap(parseMeter)

        var usages: [TokenUsage] = []
        for meter in meters {
            guard let usage = usage(for: meter) else {
                continue
            }
            usages.append(usage)
        }

        guard isActiveStatus(status), !usages.isEmpty else {
            let message = subscriptionMessage(for: status)
            return ParseResult(
                planName: nil,
                subscriptionMessage: message,
                usages: []
            )
        }

        return ParseResult(
            planName: planName(currentPeriod: currentPeriod, status: status),
            subscriptionMessage: nil,
            usages: usages
        )
    }

    /// Parse the `GET /zen/go/v1/usage` API response (authenticated by an OpenCode Go API key).
    /// Verified shape: `{usage: {rolling: {status, percent, resetsAt}, weekly: {...}, monthly: {...}}}`.
    /// Dollar amounts are derived from the published Go limits ($12 / $30 / $60) × percent.
    func parseAPIResponse(data: Data) throws -> ParseResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserError.invalidShape
        }

        // Primary shape: {usage: {rolling|weekly|monthly: {percent, resetsAt}}}.
        if let usage = object["usage"] as? [String: Any] {
            var usages: [TokenUsage] = []
            for (key, value) in usage {
                guard let item = value as? [String: Any],
                      let window = apiWindow(for: key),
                      let percent = intValue(item["percent"]) else {
                    continue
                }
                guard let limitMicroCents = Self.apiLimitMicroCents(for: key), limitMicroCents > 0 else {
                    continue
                }
                let used = max(0, min(limitMicroCents, limitMicroCents * percent / 100))
                usages.append(TokenUsage(
                    window: window,
                    used: used,
                    limit: limitMicroCents,
                    resetDate: dateValue(item["resetsAt"]),
                    unit: nil,
                    displayValue: "\(Self.dollarsText(used)) / \(Self.dollarsText(limitMicroCents))"
                ))
            }
            if !usages.isEmpty {
                return ParseResult(planName: "Go", subscriptionMessage: nil, usages: usages)
            }
        }

        // Fallback: tolerantly try the GoStatus `meters` shape, then common
        // `{limits|usage: [...]}` / `{data: {...}}` envelopes.
        if let result = try? parseBundle(data: data), !result.usages.isEmpty {
            return result
        }
        let root = (object["data"] as? [String: Any]) ?? (object["result"] as? [String: Any]) ?? object

        var meters: [Meter] = []
        if let list = (root["limits"] as? [[String: Any]]) ?? (root["usage"] as? [[String: Any]]) {
            meters = list.compactMap { item in
                guard let kind = stringValue(item["kind"]) ?? stringValue(item["window"]) else {
                    return nil
                }
                return Meter(
                    kind: kind,
                    limitMicroCents: intValue(item["limitMicroCents"]) ?? intValue(item["limit"]),
                    settledMicroCents: intValue(item["settledMicroCents"]) ?? intValue(item["usedMicroCents"]) ?? intValue(item["used"]),
                    reservedMicroCents: intValue(item["reservedMicroCents"]),
                    remainingMicroCents: intValue(item["remainingMicroCents"]) ?? intValue(item["remaining"]),
                    resetsAt: dateValue(item["resetsAt"]) ?? dateValue(item["resetAt"]),
                    windowStartsAt: dateValue(item["windowStartsAt"])
                )
            }
        } else if let dict = (root["limits"] as? [String: Any]) ?? (root["usage"] as? [String: Any]) {
            // {limits: {five_hour: {...}, week: {...}}} style.
            meters = dict.compactMap { kind, value in
                guard let item = value as? [String: Any] else {
                    return nil
                }
                return Meter(
                    kind: kind,
                    limitMicroCents: intValue(item["limitMicroCents"]) ?? intValue(item["limit"]),
                    settledMicroCents: intValue(item["settledMicroCents"]) ?? intValue(item["usedMicroCents"]) ?? intValue(item["used"]),
                    reservedMicroCents: intValue(item["reservedMicroCents"]),
                    remainingMicroCents: intValue(item["remainingMicroCents"]) ?? intValue(item["remaining"]),
                    resetsAt: dateValue(item["resetsAt"]) ?? dateValue(item["resetAt"]),
                    windowStartsAt: dateValue(item["windowStartsAt"])
                )
            }
        }

        let usages = meters.compactMap(usage(for:))
        if !usages.isEmpty {
            return ParseResult(planName: "Go", subscriptionMessage: nil, usages: usages)
        }

        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw ParserError.unsupportedShape(raw)
    }

    private func apiWindow(for key: String) -> UsageWindow? {
        switch key {
        case "rolling", "five_hour", "fiveHours", "5h":
            .fiveHours
        case "weekly", "week", "calendar_week":
            .week
        case "monthly", "month", "calendar_month":
            .month
        default:
            nil
        }
    }

    /// Published OpenCode Go dollar limits per window, in microCents.
    static func apiLimitMicroCents(for key: String) -> Int? {
        switch key {
        case "rolling", "five_hour", "fiveHours", "5h":
            12 * 1_000_000
        case "weekly", "week", "calendar_week":
            30 * 1_000_000
        case "monthly", "month", "calendar_month":
            60 * 1_000_000
        default:
            nil
        }
    }

    private func parseMeter(_ object: [String: Any]) -> Meter? {
        guard let kind = stringValue(object["kind"]) else {
            return nil
        }
        return Meter(
            kind: kind,
            limitMicroCents: intValue(object["limitMicroCents"]),
            settledMicroCents: intValue(object["settledMicroCents"]),
            reservedMicroCents: intValue(object["reservedMicroCents"]),
            remainingMicroCents: intValue(object["remainingMicroCents"]),
            resetsAt: dateValue(object["resetsAt"]),
            windowStartsAt: dateValue(object["windowStartsAt"])
        )
    }

    private func usage(for meter: Meter) -> TokenUsage? {
        let window: UsageWindow? = switch meter.kind {
        case "five_hour", "5h", "fiveHours", "five_hours":
            .fiveHours
        case "calendar_week", "week", "weekly", "calendar_weeks":
            .week
        case "calendar_month", "month", "monthly", "calendar_months":
            .month
        default:
            nil
        }
        guard let window, let limit = meter.limitMicroCents, limit > 0 else {
            return nil
        }

        let used: Int
        if let remaining = meter.remainingMicroCents {
            used = max(0, limit - remaining)
        } else {
            used = meter.settledMicroCents ?? 0
        }

        let usedText = Self.dollarsText(used)
        let limitText = Self.dollarsText(limit)
        return TokenUsage(
            window: window,
            used: used,
            limit: limit,
            resetDate: meter.resetsAt,
            unit: nil,
            displayValue: "\(usedText) / \(limitText)"
        )
    }

    private func isActiveStatus(_ status: String) -> Bool {
        switch status {
        case "active", "grace":
            true
        case "inactive", "suspended", "canceled", "":
            false
        default:
            false
        }
    }

    private func subscriptionMessage(for status: String) -> String {
        switch status {
        case "inactive":
            "OpenCode Go is not subscribed. Subscribe at opencode.ai/zen first."
        case "suspended":
            "OpenCode Go subscription is suspended."
        case "canceled":
            "OpenCode Go subscription is canceled."
        case "grace":
            "OpenCode Go subscription is in grace period."
        default:
            "OpenCode Go has no active usage data."
        }
    }

    private func planName(currentPeriod: [String: Any]?, status: String) -> String? {
        if let amount = intValue(currentPeriod?["amountMicroCents"]), amount > 0 {
            return "Go · \(Self.dollarsText(amount))/mo"
        }
        return status == "grace" ? "Go · Grace" : "Go Plan"
    }

    static func dollarsText(_ microCents: Int) -> String {
        let dollars = Double(microCents) / 1_000_000
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), dollars)
    }

    // MARK: - Value helpers

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
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func dateValue(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    enum ParserError: LocalizedError {
        case invalidShape
        case noUsage
        case unsupportedShape(String)

        var errorDescription: String? {
            switch self {
            case .invalidShape:
                "Expected a JSON object"
            case .noUsage:
                "No OpenCode Go usage data found"
            case let .unsupportedShape(raw):
                "Unexpected OpenCode Go API response: \(raw.prefix(200))"
            }
        }
    }
}
