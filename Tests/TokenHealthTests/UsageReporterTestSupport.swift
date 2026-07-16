import Foundation
@testable import TokenHealth

enum UsageReporterTestSupport {
    struct RequestSummary {
        let method: String?
        let authorization: String?
        let idempotencyKey: String?
        let contentType: String?
        let accountCount: Int
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

    static func multiProviderPayload() -> UsageReportPayload {
        let kimiID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let codexID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let disabledID = UUID(uuidString: "cccccccc-dddd-eeee-ffff-aaaaaaaaaaaa")!
        let kimi = ServiceConfig(
            id: kimiID,
            displayName: "Kimi Code",
            providerKind: .kimiCode,
            authMode: .api
        )
        let codex = ServiceConfig(
            id: codexID,
            displayName: "Codex",
            providerKind: .codex,
            authMode: .api
        )
        let disabled = ServiceConfig(
            id: disabledID,
            displayName: "Disabled DeepSeek",
            providerKind: .deepSeek,
            authMode: .api,
            isEnabled: false
        )
        let kimiSnapshot = ProviderUsageSnapshot(
            id: kimiID,
            serviceName: "Kimi Code",
            providerTitle: "Kimi Code",
            usages: [
                TokenUsage(
                    window: .fiveHours,
                    used: 25,
                    limit: 100,
                    resetDate: Date(timeIntervalSince1970: 0)
                )
            ],
            state: .ready,
            statusMessage: "Updated",
            updatedAt: Date()
        )
        let codexSnapshot = ProviderUsageSnapshot(
            id: codexID,
            serviceName: "Codex",
            providerTitle: "Codex",
            usages: [TokenUsage(window: .week, used: 50, limit: 100, resetDate: nil)],
            state: .unavailable,
            statusMessage: "Unavailable",
            updatedAt: Date()
        )
        let disabledSnapshot = ProviderUsageSnapshot(
            id: disabledID,
            serviceName: "Disabled DeepSeek",
            providerTitle: "DeepSeek",
            usages: [TokenUsage(window: .week, used: 10, limit: 100, resetDate: nil)],
            state: .ready,
            statusMessage: "Updated",
            updatedAt: Date()
        )

        return UsageReportBuilder().build(
            clientID: "test-client",
            providers: [
                (config: kimi, snapshot: kimiSnapshot),
                (config: disabled, snapshot: disabledSnapshot),
                (config: codex, snapshot: codexSnapshot),
                (config: kimi, snapshot: kimiSnapshot)
            ]
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
        let payload = multiProviderPayload()
        let request = try UsageReporter().makeRequest(
            config: hook,
            bearerToken: "secret-token",
            payload: payload,
            now: Date(timeIntervalSince1970: 1_234.567)
        )
        let decodedPayload = try request.httpBody.map {
            try JSONDecoder().decode(UsageReportPayload.self, from: $0)
        }
        let bodyMatches = decodedPayload == payload
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
            accountCount: decodedPayload?.accounts.count ?? 0,
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
        let providerIDs = [
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
        ]
        let config = ReportHookConfig(
            isEnabled: true,
            endpoint: "https://example.com/report",
            clientID: "test-client",
            providerConfigIDs: providerIDs,
            pinnedCertificateSHA256: String(repeating: "a", count: 64)
        )

        store.saveReportHookConfig(config)
        let encoded = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        return store.loadReportHookConfig() == config &&
            object?["providerConfigIDs"] != nil &&
            object?["providerConfigID"] == nil
    }

    static func decodesLegacyHookConfiguration() throws -> Bool {
        let data = Data(
            #"{"isEnabled":true,"endpoint":"https://example.com/report","clientID":"legacy-client"}"#.utf8
        )
        let config = try JSONDecoder().decode(ReportHookConfig.self, from: data)
        return config.isEnabled &&
            config.endpoint == "https://example.com/report" &&
            config.clientID == "legacy-client" &&
            config.providerConfigIDs.isEmpty &&
            config.pinnedCertificateSHA256.isEmpty
    }

    static func migratesLegacySingleProviderSelection() throws -> Bool {
        let providerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = Data(
            #"{"isEnabled":true,"endpoint":"https://example.com/report","clientID":"legacy-client","providerConfigID":"11111111-2222-3333-4444-555555555555"}"#.utf8
        )
        let config = try JSONDecoder().decode(ReportHookConfig.self, from: data)
        return config.providerConfigIDs == [providerID]
    }

    static func prefersAndDeduplicatesMultiProviderSelection() throws -> Bool {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
        let data = Data(
            #"{"isEnabled":true,"endpoint":"https://example.com/report","clientID":"test-client","providerConfigIDs":["11111111-2222-3333-4444-555555555555","11111111-2222-3333-4444-555555555555","66666666-7777-8888-9999-000000000000"],"providerConfigID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#.utf8
        )
        let config = try JSONDecoder().decode(ReportHookConfig.self, from: data)
        return config.providerConfigIDs == [firstID, secondID]
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
