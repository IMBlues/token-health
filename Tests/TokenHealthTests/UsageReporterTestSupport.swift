import Foundation
@testable import TokenHealth

enum UsageReporterTestSupport {
    struct RequestSummary {
        let method: String?
        let authorization: String?
        let idempotencyKey: String?
        let contentType: String?
        let bodyMatches: Bool
        let bodyUsesSnakeCase: Bool
    }

    static var livePinnedEndpointConfigured: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["TOKEN_HEALTH_LIVE_REPORT_ENDPOINT"] != nil &&
            environment["TOKEN_HEALTH_LIVE_REPORT_PIN"] != nil
    }

    static func livePinnedEndpointStatus() async throws -> Int {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["TOKEN_HEALTH_LIVE_REPORT_ENDPOINT"],
              let fingerprint = environment["TOKEN_HEALTH_LIVE_REPORT_PIN"] else {
            throw URLError(.badURL)
        }
        let config = ReportHookConfig(
            isEnabled: true,
            endpoint: endpoint,
            clientID: "token-health-live-test",
            pinnedCertificateSHA256: fingerprint
        )

        do {
            return try await UsageReporter().report(
                config: config,
                bearerToken: "",
                payload: accountQuotaPayload()
            )
        } catch UsageReporter.ReporterError.rejected(let statusCode, _) {
            // An HTTP rejection still proves the pinned TLS handshake reached the endpoint.
            return statusCode
        }
    }

    static func accountQuotaPayload() -> UsageReportPayload {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let config = ServiceConfig(
            id: id,
            displayName: "Kimi Code",
            providerKind: .kimiCode,
            authMode: .api
        )
        let snapshot = ProviderUsageSnapshot(
            id: id,
            serviceName: "Kimi Code",
            providerTitle: "Kimi Code",
            planName: "Allegretto",
            usages: [
                TokenUsage(
                    window: .fiveHours,
                    used: 9,
                    limit: 50,
                    resetDate: Date(timeIntervalSince1970: 0)
                ),
                TokenUsage(
                    window: .week,
                    used: 970,
                    limit: 1_000,
                    resetDate: Date(timeIntervalSince1970: 3_600)
                ),
                TokenUsage(window: .todayTokens, used: 12_000, limit: nil, resetDate: nil)
            ],
            state: .ready,
            statusMessage: "Updated",
            updatedAt: Date()
        )

        return UsageReportBuilder().build(
            clientID: "test-client",
            config: config,
            snapshot: snapshot
        )
    }

    static func deduplicatedPayload() -> UsageReportPayload {
        let enabledID = UUID()
        let enabled = ServiceConfig(
            id: enabledID,
            displayName: "Codex",
            providerKind: .codex,
            authMode: .api
        )
        let snapshot = ProviderUsageSnapshot(
            id: enabledID,
            serviceName: "Codex",
            providerTitle: "Codex",
            usages: [
                TokenUsage(window: .fiveHours, label: "Primary", used: 20, limit: 100, resetDate: nil),
                TokenUsage(window: .fiveHours, label: "Another model", used: 80, limit: 100, resetDate: nil)
            ],
            state: .ready,
            statusMessage: "Updated",
            updatedAt: Date()
        )

        return UsageReportBuilder().build(
            clientID: "local",
            config: enabled,
            snapshot: snapshot
        )
    }

    static func disabledProviderPayload() -> UsageReportPayload {
        let id = UUID()
        var config = ServiceConfig(
            id: id,
            displayName: "Disabled Kimi",
            providerKind: .kimiCode,
            authMode: .api
        )
        config.isEnabled = false
        let snapshot = ProviderUsageSnapshot(
            id: id,
            serviceName: "Disabled Kimi",
            providerTitle: "Kimi Code",
            usages: [TokenUsage(window: .fiveHours, used: 1, limit: 10, resetDate: nil)],
            state: .ready,
            statusMessage: "Updated",
            updatedAt: Date()
        )
        return UsageReportBuilder().build(clientID: "local", config: config, snapshot: snapshot)
    }

    static func requestSummary() throws -> RequestSummary {
        let hook = ReportHookConfig(
            isEnabled: true,
            endpoint: "https://quota.example.com/api/v1/reports",
            clientID: "test-client"
        )
        let payload = accountQuotaPayload()
        let request = try UsageReporter().makeRequest(
            config: hook,
            bearerToken: "secret-token",
            payload: payload,
            now: Date(timeIntervalSince1970: 1_234.567)
        )
        let bodyMatches = try request.httpBody.map {
            try JSONDecoder().decode(UsageReportPayload.self, from: $0) == payload
        } ?? false
        let bodyUsesSnakeCase = try request.httpBody.map { data in
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["client_id"] != nil,
                  let account = (root["accounts"] as? [[String: Any]])?.first,
                  account["account_ref"] != nil,
                  account["display_name"] != nil,
                  let window = (account["windows"] as? [[String: Any]])?.first else {
                return false
            }
            return window["used_percent"] != nil && window["resets_at"] != nil
        } ?? false

        return RequestSummary(
            method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            bodyMatches: bodyMatches,
            bodyUsesSnakeCase: bodyUsesSnakeCase
        )
    }

    static func persistsHookConfiguration() throws -> Bool {
        let suiteName = "TokenHealthTests.UsageReport.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return false
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ConfigStore(defaults: defaults)
        let config = ReportHookConfig(
            isEnabled: true,
            endpoint: "https://example.com/report",
            clientID: "test-client",
            providerConfigID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            pinnedCertificateSHA256: String(repeating: "a", count: 64)
        )

        store.saveReportHookConfig(config)
        return store.loadReportHookConfig() == config
    }

    static func decodesLegacyHookConfiguration() throws -> Bool {
        let data = Data(
            #"{"isEnabled":true,"endpoint":"https://example.com/report","clientID":"legacy-client"}"#.utf8
        )
        let config = try JSONDecoder().decode(ReportHookConfig.self, from: data)
        return config.isEnabled &&
            config.endpoint == "https://example.com/report" &&
            config.clientID == "legacy-client" &&
            config.providerConfigID == nil &&
            config.pinnedCertificateSHA256.isEmpty
    }

    static func normalizesCertificateFingerprint() -> Bool {
        let input = "SHA256:" + Array(repeating: "AB", count: 32).joined(separator: ":")
        return TLSCertificatePin.normalizedSHA256(input) == String(repeating: "ab", count: 32)
    }

    static func rejectsMalformedCertificateFingerprint() -> Bool {
        let config = ReportHookConfig(
            isEnabled: true,
            endpoint: "https://example.com/report",
            clientID: "test-client",
            pinnedCertificateSHA256: "not-a-fingerprint"
        )
        do {
            _ = try UsageReporter().makeRequest(
                config: config,
                bearerToken: "",
                payload: accountQuotaPayload()
            )
            return false
        } catch UsageReporter.ReporterError.invalidCertificatePin {
            return true
        } catch {
            return false
        }
    }

}
