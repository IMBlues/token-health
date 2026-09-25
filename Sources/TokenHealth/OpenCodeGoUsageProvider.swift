import Foundation

struct OpenCodeGoUsageProvider: UsageProvider {
    private static let providerTitle = "OpenCode Go"
    private let consoleHost = "console.opencode.ai"
    /// Keep in sync with the web script's `workspaces.slice(0, 5)`.
    private static let workspaceProbeLimit = 5
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
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
                // The console script scrapes a fixed 30-day window and takes no period from the
                // context, so the values passed in are inert.
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
        let orgsData = try await fetchData(session: session, path: "/api/me/orgs")
        let workspaces = OpenCodeGoUsageParser.workspaceIDs(fromOrgs: orgsData)

        // Prefer the first workspace that carries a Go subscription; fall back to the first
        // workspace's response so "not subscribed" still gets its own message. A probe that fails
        // is skipped and probing continues — matching the web script, which also keeps going — so
        // one unusable workspace (not visible to the session, transient console error) does not
        // doom the whole native path and later workspaces are still reached.
        var firstData: Data?
        var firstID: String?
        var chosen: (data: Data, id: String)?
        var sawFailure = false
        for workspace in workspaces.prefix(Self.workspaceProbeLimit) {
            guard let data = try? await fetchData(session: session, path: "/api/go/status", workspaceID: workspace) else {
                sawFailure = true
                continue
            }
            if firstData == nil {
                firstData = data
                firstID = workspace
            }
            if OpenCodeGoUsageParser.hasGoAccess(statusData: data) {
                chosen = (data, workspace)
                break
            }
        }

        // All probes succeeded but none carries Go: keep the first response so the "not subscribed"
        // message survives. A probe failure with no access found means the session (or the console)
        // is broken — throw so the WebView path can surface the real error.
        if chosen == nil, sawFailure {
            throw WebSessionError.requestFailed(
                providerTitle: Self.providerTitle,
                message: "OpenCode Go status probe failed"
            )
        }

        guard let statusData = chosen?.data ?? firstData,
              let workspaceID = chosen?.id ?? firstID else {
            throw WebSessionError.requestFailed(
                providerTitle: Self.providerTitle,
                message: "OpenCode Go has no workspace"
            )
        }

        // A 2xx body that is not a JSON object (an expired session redirected to an HTML page, a
        // proxy interstitial) must not be reported as "not subscribed" — fail the native path so
        // the WebView script gets to surface the real error instead.
        guard (try? JSONSerialization.jsonObject(with: statusData)) is [String: Any] else {
            throw WebSessionError.requestFailed(
                providerTitle: Self.providerTitle,
                message: "OpenCode Go status response was not JSON"
            )
        }

        async let summary = fetchUsageData(
            session: session,
            path: "/api/usage/summary",
            query: [("range", "30d")],
            workspaceID: workspaceID
        )
        async let byDay = fetchUsageData(
            session: session,
            path: "/api/usage/cost-by-day",
            query: [("range", "30d"), ("bucket", "day")],
            workspaceID: workspaceID
        )
        async let models = fetchUsageData(
            session: session,
            path: "/api/usage/models",
            query: [("range", "30d"), ("pageSize", "100"), ("costOrder", "desc")],
            workspaceID: workspaceID
        )

        return OpenCodeGoUsageEnvelope.make(
            goStatus: statusData,
            orgs: orgsData,
            workspaceId: workspaceID,
            summary: await summary,
            byDay: await byDay,
            models: await models
        )
    }

    /// The usage endpoints are a nice-to-have: a failure only drops the matching card section, it
    /// must not fail the whole refresh.
    private func fetchUsageData(
        session: OpenCodeGoWebSessionCredential,
        path: String,
        query: [(String, String)],
        workspaceID: String?
    ) async -> Data? {
        // A failed request is already logged by fetchData (with the status and body), so this
        // swallows it silently rather than printing the same failure twice.
        guard let data = try? await fetchData(session: session, path: path, query: query, workspaceID: workspaceID) else {
            return nil
        }
        // A 2xx body that does not parse is a silent section-drop otherwise; log it so
        // "why is the by-day chart missing" has a signal in the debug log.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            WebSessionLog.debugLog(
                "usage response was not JSON, path=\(path)",
                providerTitle: Self.providerTitle
            )
            return nil
        }
        return data
    }

    private func fetchData(
        session: OpenCodeGoWebSessionCredential,
        path: String,
        query: [(String, String)] = [],
        workspaceID: String? = nil
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = consoleHost
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Scoped console endpoints answer HTTP 400 when this header is missing.
        if let workspaceID, !workspaceID.isEmpty {
            request.setValue(workspaceID, forHTTPHeaderField: "x-org-id")
        }
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
        WebSessionLog.debugLog("native request succeeded, path=\(path), bytes=\(data.count)", providerTitle: Self.providerTitle)
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

        // The live console shape (2026-09) carries its meters under `access`; it has no price or
        // subscriptionStatus, so it returns early and never reaches the legacy walk below.
        if let access = goStatusRoot["access"] as? [String: Any] {
            return accessShapeResult(access: access)
        }

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

        guard Self.isActiveStatus(status), !usages.isEmpty else {
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

    /// Parse the current console shape:
    /// `{access: {meters: {fiveHour|week|month: {limitMicroCents, usedMicroCents, resetsAt}}, endsAt}}`.
    /// `access` absent or null just means this is not that shape: the caller falls through to the
    /// legacy walk, and only "no usable meters" ends up reported as not-subscribed.
    private func accessShapeResult(access: [String: Any]) -> ParseResult {
        let meters = access["meters"] as? [String: Any] ?? [:]
        let periodEnd = dateValue(access["endsAt"])

        var usages: [TokenUsage] = []
        for (key, window) in [("fiveHour", UsageWindow.fiveHours), ("week", .week), ("month", .month)] {
            guard let item = meters[key] as? [String: Any],
                  let limit = intValue(item["limitMicroCents"]), limit > 0 else {
                continue
            }
            // Floor-only clamp, same as the legacy path: a window can exceed its limit, and the
            // card should show that rather than quietly pinning it to the limit.
            let used = max(0, intValue(item["usedMicroCents"]) ?? 0)
            usages.append(TokenUsage(
                window: window,
                used: used,
                limit: limit,
                // Only the month meter lacks a resetsAt of its own; the paid period end stands in
                // for it. The shorter windows must not borrow it — a 5-hour meter showing the
                // month's end would read as a 6-day window.
                resetDate: dateValue(item["resetsAt"]) ?? (window == .month ? periodEnd : nil),
                unit: nil,
                displayValue: "\(Self.dollarsText(used)) / \(Self.dollarsText(limit))"
            ))
        }

        guard !usages.isEmpty else {
            return ParseResult(
                planName: nil,
                subscriptionMessage: subscriptionMessage(for: "inactive"),
                usages: []
            )
        }

        // This shape carries no price (the console keeps it in the checkout product), so the plan
        // name is the bare "Go" — the same fallback the API-key path uses.
        return ParseResult(planName: "Go", subscriptionMessage: nil, usages: usages)
    }

    /// `/api/me/orgs` → `[{id, name}]`; the app only needs the ids.
    static func workspaceIDs(fromOrgs data: Data) -> [String] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    /// Whether this workspace carries a Go subscription, in either the current (`access`) or the
    /// legacy (`subscriptionStatus`) shape.
    ///
    /// An `access` object without usable meters still counts as "has access": the parser reports
    /// that as not-subscribed, which is the honest degrade. Do not read `true` as "has quota".
    static func hasGoAccess(statusData: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else {
            return false
        }
        let goStatus = (root["goStatus"] as? [String: Any]) ?? root
        if goStatus["access"] is [String: Any] {
            return true
        }
        guard let status = goStatus["subscriptionStatus"] as? String else {
            return false
        }
        return Self.isActiveStatus(status)
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
        // Amounts here come straight from the response; assume the console's microcent scale
        // (1 USD = 1e8). Unlike the percent branch's published limits above
        // (apiLimitMicroCents), this shape has never been seen from a real Zen account, so the
        // scale is unverified.
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
            // Amounts here come straight from the response; assume the console's microcent scale
            // (1 USD = 1e8). Unlike the percent branch's published limits above
            // (apiLimitMicroCents), this shape has never been seen from a real Zen account, so the
            // scale is unverified.
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

    /// Published OpenCode Go dollar limits per window, in microcents (1 USD = 1e8).
    static func apiLimitMicroCents(for key: String) -> Int? {
        switch key {
        case "rolling", "five_hour", "fiveHours", "5h":
            12 * microCentsPerDollar
        case "weekly", "week", "calendar_week":
            30 * microCentsPerDollar
        case "monthly", "month", "calendar_month":
            60 * microCentsPerDollar
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

    private static func isActiveStatus(_ status: String) -> Bool {
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

    /// Console money fields are microcents: 1 USD = 1e8.
    static let microCentsPerDollar = 100_000_000

    static func dollars(_ microCents: Int) -> Double {
        Double(microCents) / Double(microCentsPerDollar)
    }

    static func dollarsText(_ microCents: Int) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), dollars(microCents))
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

/// Assembles the native path's responses into the same envelope the WebView script returns.
///
/// `ok` / `status` / `text` describe a successful `/api/go/status` request: the session kernel
/// throws on `ok == false` (and maps 401/403 to session-expired), so a failed usage call must
/// never flip them — it only shows up as the matching `usage*` key being absent. Nothing in the
/// app reads this native envelope through the session kernel: `ok` / `status` / `text` /
/// `hasSession` are constants kept for shape parity with the WebView script's envelope. Absent
/// keys and explicit nulls are equivalent: both consumers read them with optional casts. The
/// serialization-failure fallback returns the raw status body, which `parseBundle` also accepts,
/// so meters still render and only the usage sections are absent.
enum OpenCodeGoUsageEnvelope {
    static func make(
        goStatus: Data,
        orgs: Data,
        workspaceId: String?,
        summary: Data?,
        byDay: Data?,
        models: Data?
    ) -> Data {
        var object: [String: Any] = [
            "ok": true,
            "status": 200,
            "text": "",
            "hasSession": true
        ]

        object["goStatus"] = jsonObject(from: goStatus) ?? [:]
        if let orgsObject = jsonObject(from: orgs) {
            object["orgs"] = orgsObject
        }
        if let workspaceId {
            object["workspaceId"] = workspaceId
        }
        if let summary, let value = jsonObject(from: summary) {
            object["usageSummary"] = value
        }
        if let byDay, let value = jsonObject(from: byDay) {
            object["usageByDay"] = value
        }
        if let models, let value = jsonObject(from: models) {
            object["usageModels"] = value
        }

        return (try? JSONSerialization.data(withJSONObject: object)) ?? goStatus
    }

    private static func jsonObject(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }
}
