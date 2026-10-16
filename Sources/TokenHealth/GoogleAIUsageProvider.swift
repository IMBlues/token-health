import Foundation

/// Reads the quota of the Google account signed in to Antigravity.
///
/// Antigravity meters two pools per model group — a five-hour one and a weekly one — for the
/// Gemini models and for the Claude and GPT ones it brokers. It exposes them through the same
/// private Cloud Code API its own language server calls, authenticated with the OAuth token it
/// leaves at `~/.gemini/jetski-standalone-oauth-token`.
///
/// Nothing here talks to a service the app is not already entitled to: the token is the user's
/// own, read from the same file Antigravity wrote it to, and the calls are read-only.
struct GoogleAIUsageProvider: UsageProvider {
    /// Everything the provider reaches outside itself for, so tests can drive the whole fetch —
    /// credential file, token refresh, both RPCs — without a network, an installed Antigravity,
    /// or a clock.
    struct Environment: Sendable {
        var credentialFileURL: URL
        var antigravityBinaryURL: URL
        var tokenEndpoint: URL
        var codeAssistEndpoint: URL
        /// 见 `GoogleAIClientIdentity`：后端按它裁剪返回，不是装饰。
        var userAgent: String
        var now: @Sendable () -> Date
        var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

        static let live: Environment = {
            let binaryURL = URL(
                fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
            )
            return Environment(
                credentialFileURL: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".gemini/jetski-standalone-oauth-token"),
                antigravityBinaryURL: binaryURL,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                // Not cloudcode-pa.googleapis.com. Both hosts serve the same RPCs, but the prod
                // one answers the quota calls as if the account had spent nothing — every pool
                // comes back at remainingFraction 1 — while this one reports the real numbers, the
                // ones Antigravity's own Models & Usage page shows. Antigravity's language server
                // logs every request it makes and it is calling this host.
                codeAssistEndpoint: URL(string: "https://daily-cloudcode-pa.googleapis.com")!,
                userAgent: GoogleAIClientIdentity.userAgent(
                    version: GoogleAIClientIdentity.installedVersion(executableAt: binaryURL)
                ),
                now: { Date() },
                send: { request in
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw GoogleAIError.transport("Google AI did not answer over HTTP")
                    }
                    return (data, http)
                }
            )
        }()
    }

    /// Discovered clients and refreshed tokens survive between refresh cycles: scanning the 155 MB
    /// binary and asking Google for a token are not things to redo every few minutes, and a
    /// refreshed token outlives several cycles. Keyed by path so two Antigravity installs — or two
    /// tests — never share one.
    private actor SessionCache {
        private var tokens: [String: (token: String, expiry: Date?)] = [:]
        private var clients: [String: [GoogleAIOAuthClient]] = [:]

        func token(forFile path: String) -> (token: String, expiry: Date?)? {
            tokens[path]
        }

        func store(token: String, expiry: Date?, forFile path: String) {
            tokens[path] = (token, expiry)
        }

        func clientList(forBinary path: String) -> [GoogleAIOAuthClient]? {
            clients[path]
        }

        func store(clients found: [GoogleAIOAuthClient], forBinary path: String) {
            clients[path] = found
        }
    }

    private static let sessions = SessionCache()

    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func fetchUsage(config: ServiceConfig, secrets _: ProviderSecrets) async -> ProviderUsageSnapshot {
        do {
            let token = try await accessToken()
            let context = try await codeAssistContext(token: token)
            let summary = try await rpc(
                "retrieveUserQuotaSummary",
                token: token,
                body: ["project": context.project].compactMapValues { $0 }
            )
            // The catalogue is a nice-to-have: without it the popover loses its per-model table
            // and nothing else.
            let models = try? await rpc(
                "fetchAvailableModels",
                token: token,
                body: ["project": context.project].compactMapValues { $0 }
            )
            let usages = try GoogleAIQuotaParser.summary(from: summary).usages
            guard !usages.isEmpty else {
                return failure(config: config, state: .unavailable, message: "Google AI reported no quota windows")
            }

            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: context.planName,
                usages: usages,
                detail: GoogleAIUsageDetail.make(summary: summary, models: models, usages: usages),
                state: .ready,
                statusMessage: context.planName ?? "Antigravity",
                updatedAt: environment.now()
            )
        } catch let error as GoogleAIError {
            return failure(config: config, state: error.state, message: error.message)
        } catch {
            return failure(config: config, state: .unavailable, message: error.localizedDescription)
        }
    }

    private func failure(
        config: ServiceConfig,
        state: ProviderUsageSnapshot.State,
        message: String
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: config.id,
            serviceName: config.displayName,
            providerTitle: config.providerKind.title,
            usages: [],
            state: state,
            statusMessage: message,
            updatedAt: environment.now()
        )
    }

    // MARK: - Credentials

    /// A token worth sending: Antigravity's own while it lasts, otherwise one this app refreshes
    /// with the OAuth client Antigravity ships.
    private func accessToken() async throws -> String {
        guard let data = try? Data(contentsOf: environment.credentialFileURL),
              let credential = GoogleAICredential.decode(from: data) else {
            throw GoogleAIError.notLoggedIn
        }

        let now = environment.now()
        if credential.isFresh(now: now) {
            return credential.accessToken
        }

        let path = environment.credentialFileURL.path
        if let cached = await Self.sessions.token(forFile: path),
           let expiry = cached.expiry,
           expiry.timeIntervalSince(now) > 60 {
            return cached.token
        }

        guard credential.refreshToken != nil else {
            throw GoogleAIError.notLoggedIn
        }
        let clients = await antigravityClients()
        guard !clients.isEmpty else {
            throw GoogleAIError.clientNotFound
        }

        // Antigravity's binary carries two client ids and two secrets with nothing in the layout
        // pairing them, so the only way to find the one Google will accept is to offer them.
        for client in clients {
            if let refreshed = try? await refresh(credential: credential, client: client) {
                await Self.sessions.store(token: refreshed.token, expiry: refreshed.expiry, forFile: path)
                return refreshed.token
            }
        }
        throw GoogleAIError.refreshRejected
    }

    private func antigravityClients() async -> [GoogleAIOAuthClient] {
        let path = environment.antigravityBinaryURL.path
        if let cached = await Self.sessions.clientList(forBinary: path) {
            return cached
        }
        let found = GoogleAIOAuthClientScanner.candidates(at: environment.antigravityBinaryURL)
        await Self.sessions.store(clients: found, forBinary: path)
        return found
    }

    private func refresh(
        credential: GoogleAICredential,
        client: GoogleAIOAuthClient
    ) async throws -> (token: String, expiry: Date?) {
        guard let refreshToken = credential.refreshToken else {
            throw GoogleAIError.notLoggedIn
        }

        var request = URLRequest(url: environment.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(environment.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            Self.formEncoded([
                "client_id": client.clientID,
                "client_secret": client.clientSecret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ]).utf8
        )

        let (data, response) = try await environment.send(request)
        guard response.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String,
              !token.isEmpty else {
            throw GoogleAIError.refreshRejected
        }

        let lifetime = (root["expires_in"] as? NSNumber)?.doubleValue
        return (token, lifetime.map { environment.now().addingTimeInterval($0) })
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    // MARK: - Cloud Code

    /// Which plan the account is on, and which project the quota calls want. Both calls need the
    /// project, so a failure here is not something the rest can shrug off.
    private func codeAssistContext(token: String) async throws -> (planName: String?, project: String?) {
        let data = try await rpc(
            "loadCodeAssist",
            token: token,
            body: ["metadata": ["ideType": "ANTIGRAVITY", "pluginType": "GEMINI"]]
        )
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAIError.transport("Google AI returned a payload this app cannot read")
        }

        // `paidTier` is the subscription the account actually pays for; `currentTier` names the
        // free bucket, so preferring the former is what puts "Google AI Pro" on the card.
        let paid = (root["paidTier"] as? [String: Any])?["name"] as? String
        let current = (root["currentTier"] as? [String: Any])?["name"] as? String
        return (
            planName: [paid, current].compactMap { $0 }.first { !$0.isEmpty },
            project: root["cloudaicompanionProject"] as? String
        )
    }

    private func rpc(_ method: String, token: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: environment.codeAssistEndpoint.appendingPathComponent("v1internal:\(method)"))
        request.httpMethod = "POST"
        request.setValue(environment.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await environment.send(request)
        guard response.statusCode == 200 else {
            throw GoogleAIError.rpc("Google AI returned \(response.statusCode) for \(method)")
        }
        return data
    }
}

enum GoogleAIError: LocalizedError {
    case notLoggedIn
    case clientNotFound
    case refreshRejected
    case transport(String)
    case rpc(String)

    var message: String {
        switch self {
        case .notLoggedIn:
            "Log in with Antigravity"
        case .clientNotFound:
            "Antigravity's OAuth client could not be read"
        case .refreshRejected:
            "Antigravity's session expired — open Antigravity to sign in again"
        case let .transport(detail), let .rpc(detail):
            detail
        }
    }

    var state: ProviderUsageSnapshot.State {
        switch self {
        case .notLoggedIn:
            .needsConfiguration
        case .clientNotFound, .refreshRejected, .transport, .rpc:
            .unavailable
        }
    }

    var errorDescription: String? { message }
}
