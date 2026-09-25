import Foundation

struct OpenCodeGoUsageProvider: UsageProvider {
    private static let providerTitle = "OpenCode Go"
    private let consoleHost = "console.opencode.ai"
    /// Keep in sync with the web script's `workspaces.slice(0, 5)`.
    static let workspaceProbeLimit = 5
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

            return consoleSnapshot(config: config, bundle: bundleData, accountName: session.accountName, today: Date())
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

    /// 把一次取回的信封变成快照。
    ///
    /// 抽出来是因为 `fetchUsage` 永远会打真实网络（失败还回落到 WebKit 会话），没有注入点 ——
    /// 拿合成信封测这一层，才不用去碰 console.opencode.ai。
    func consoleSnapshot(
        config: ServiceConfig,
        bundle: Data,
        accountName: String?,
        today: Date
    ) -> ProviderUsageSnapshot {
        do {
            let result = try OpenCodeGoUsageParser().parseBundle(data: bundle)
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
                planName: result.planName ?? accountName,
                usages: result.usages,
                detail: OpenCodeGoUsageDetail.make(bundle: bundle, usages: result.usages, today: today),
                state: .ready,
                statusMessage: "OpenCode Go API",
                updatedAt: Date()
            )
        } catch {
            // 这里只可能接到 parser 的错：WebSessionError →「重登/会话过期」的映射在上层
            // fetchConsoleUsage 的 catch 里；别让 parser 抛会话错误，否则那条映射会被绕过。
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
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
