import CryptoKit
import Foundation

struct ReportHookConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var endpoint: String
    var clientID: String
    var providerConfigIDs: [UUID]
    var pinnedCertificateSHA256: String

    init(
        isEnabled: Bool,
        endpoint: String,
        clientID: String,
        providerConfigIDs: [UUID] = [],
        pinnedCertificateSHA256: String = ""
    ) {
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.clientID = clientID
        self.providerConfigIDs = providerConfigIDs
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case endpoint
        case clientID
        case providerConfigIDs
        case providerConfigID
        case pinnedCertificateSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        clientID = try container.decode(String.self, forKey: .clientID)
        let decodedIDs: [UUID]
        if container.contains(.providerConfigIDs) {
            decodedIDs = try container.decodeIfPresent([UUID].self, forKey: .providerConfigIDs) ?? []
        } else if let legacyID = try container.decodeIfPresent(UUID.self, forKey: .providerConfigID) {
            decodedIDs = [legacyID]
        } else {
            decodedIDs = []
        }
        var seenIDs = Set<UUID>()
        providerConfigIDs = decodedIDs.filter { seenIDs.insert($0).inserted }
        pinnedCertificateSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .pinnedCertificateSHA256
        ) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(providerConfigIDs, forKey: .providerConfigIDs)
        try container.encode(pinnedCertificateSHA256, forKey: .pinnedCertificateSHA256)
    }

    static var defaultValue: ReportHookConfig {
        ReportHookConfig(
            isEnabled: false,
            endpoint: "",
            clientID: defaultClientID(),
            providerConfigIDs: [],
            pinnedCertificateSHA256: ""
        )
    }

    private static func defaultClientID() -> String {
        let source = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let transliterated = source
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? source
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let normalized = transliterated
            .lowercased()
            .unicodeScalars
            .map { scalar in
                allowed.contains(scalar) ? String(scalar) : "-"
            }
            .joined()
        let value = normalized
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return value.isEmpty ? "local" : value
    }
}

enum TLSCertificatePin {
    static func normalizedSHA256(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("sha256:") {
            candidate.removeFirst("sha256:".count)
        }

        let compact = candidate.unicodeScalars.filter { scalar in
            scalar.value != 58 && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        guard compact.count == 64,
              compact.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) ||
                  (65...70).contains(scalar.value) ||
                  (97...102).contains(scalar.value)
              }) else {
            return nil
        }
        return String(String.UnicodeScalarView(compact)).lowercased()
    }

}

struct UsageReportPayload: Codable, Equatable, Sendable {
    var clientID: String
    var accounts: [UsageReportAccount]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case accounts
    }
}

struct UsageReportAccount: Codable, Equatable, Sendable {
    var provider: String
    var accountRef: String
    var displayName: String
    var plan: String
    var status: String
    var windows: [UsageReportWindow]

    enum CodingKeys: String, CodingKey {
        case provider
        case accountRef = "account_ref"
        case displayName = "display_name"
        case plan
        case status
        case windows
    }
}

struct UsageReportWindow: Codable, Equatable, Sendable {
    var name: String
    var usedPercent: Int
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case name
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }
}

struct UsageReportBuilder {
    func build(
        clientID: String,
        config: ServiceConfig,
        snapshot: ProviderUsageSnapshot
    ) -> UsageReportPayload {
        build(clientID: clientID, providers: [(config: config, snapshot: snapshot)])
    }

    func build(
        clientID: String,
        providers: [(config: ServiceConfig, snapshot: ProviderUsageSnapshot)]
    ) -> UsageReportPayload {
        var includedConfigIDs = Set<UUID>()
        let accounts = providers.compactMap { provider -> UsageReportAccount? in
            guard provider.config.isEnabled,
                  includedConfigIDs.insert(provider.config.id).inserted else {
                return nil
            }
            return account(config: provider.config, snapshot: provider.snapshot)
        }
        return UsageReportPayload(clientID: clientID, accounts: accounts)
    }

    private func account(config: ServiceConfig, snapshot: ProviderUsageSnapshot) -> UsageReportAccount {
        UsageReportAccount(
            provider: providerIdentifier(config.providerKind),
            accountRef: accountReference(for: config.displayName),
            displayName: displayName(for: snapshot),
            plan: normalizedPlan(snapshot.planName),
            status: status(for: snapshot.state),
            windows: reportWindows(snapshot.usages)
        )
    }

    private func reportWindows(_ usages: [TokenUsage]) -> [UsageReportWindow] {
        var included = Set<UsageWindow>()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        return usages.compactMap { usage in
            guard let name = reportName(for: usage.window),
                  !included.contains(usage.window),
                  let limit = usage.limit,
                  limit > 0 else {
                return nil
            }
            included.insert(usage.window)

            let percentage = Int((Double(usage.used) / Double(limit) * 100).rounded())
            return UsageReportWindow(
                name: name,
                usedPercent: min(max(percentage, 0), 100),
                resetsAt: usage.resetDate.map(dateFormatter.string(from:))
            )
        }
    }

    private func reportName(for window: UsageWindow) -> String? {
        switch window {
        case .fiveHours:
            "5h"
        case .week:
            "week"
        case .balance, .tokenQuota, .todayCost, .todayTokens, .todayRequests, .month, .mcpMonth, .videoGift, .sevenDaysTokens, .sevenDaysTools:
            nil
        }
    }

    private func providerIdentifier(_ provider: ProviderKind) -> String {
        switch provider {
        case .openAI: "openai"
        case .anthropic: "anthropic"
        case .cursor: "cursor"
        case .codex: "codex"
        case .kimiCode: "kimi-code"
        case .zhipuCode: "zhipu-code"
        case .deepSeek: "deepseek"
        case .miniMax: "minimax"
        case .volcengineArk: "volcengine-ark"
        case .genericHTTP: "generic-http"
        case .demo: "demo"
        }
    }

    private func accountReference(for displayName: String) -> String {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func displayName(for snapshot: ProviderUsageSnapshot) -> String {
        guard let planName = snapshot.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planName.isEmpty,
              planName.caseInsensitiveCompare(snapshot.serviceName) != .orderedSame else {
            return snapshot.serviceName
        }
        return "\(snapshot.serviceName) · \(planName)"
    }

    private func normalizedPlan(_ planName: String?) -> String {
        let value = planName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
    }

    private func status(for state: ProviderUsageSnapshot.State) -> String {
        switch state {
        case .ready:
            "ok"
        case .needsConfiguration:
            "needs_configuration"
        case .unavailable:
            "unavailable"
        }
    }
}

struct UsageReporter {
    enum ReporterError: LocalizedError {
        case invalidEndpoint
        case missingClientID
        case invalidCertificatePin
        case tlsValidationFailed
        case rejected(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "Usage reporting endpoint must be an HTTPS URL"
            case .missingClientID:
                "Usage reporting client ID is required"
            case .invalidCertificatePin:
                "Pinned certificate SHA-256 must contain exactly 64 hexadecimal characters"
            case .tlsValidationFailed:
                "TLS validation failed. Check the endpoint certificate chain or configure its exact SHA-256 fingerprint"
            case let .rejected(statusCode, message):
                message.isEmpty ? "Usage reporting failed with HTTP \(statusCode)" : "Usage reporting failed with HTTP \(statusCode): \(message)"
            }
        }
    }

    private let session: URLSession?

    init(session: URLSession? = nil) {
        self.session = session
    }

    func makeRequest(
        config: ReportHookConfig,
        bearerToken: String,
        payload: UsageReportPayload,
        now: Date = Date()
    ) throws -> URLRequest {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw ReporterError.invalidEndpoint
        }
        _ = try normalizedPin(config.pinnedCertificateSHA256)
        guard !payload.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReporterError.missingClientID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("local-\(Int(now.timeIntervalSince1970 * 1_000))", forHTTPHeaderField: "Idempotency-Key")
        let normalizedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedToken.isEmpty {
            request.setValue("Bearer \(normalizedToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    @discardableResult
    func report(
        config: ReportHookConfig,
        bearerToken: String,
        payload: UsageReportPayload
    ) async throws -> Int {
        let request = try makeRequest(config: config, bearerToken: bearerToken, payload: payload)
        let normalizedFingerprint = try normalizedPin(config.pinnedCertificateSHA256)
        let data: Data
        let response: URLResponse

        if let normalizedFingerprint {
            (data, response) = try await PinnedHTTPSClient().data(
                for: request,
                pinnedCertificateSHA256: normalizedFingerprint
            )
        } else {
            do {
                (data, response) = try await (session ?? .shared).data(for: request)
            } catch {
                throw mappedTransportError(error)
            }
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(240)) } ?? ""
            throw ReporterError.rejected(statusCode: httpResponse.statusCode, message: message)
        }
        return httpResponse.statusCode
    }

    private func normalizedPin(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let normalized = TLSCertificatePin.normalizedSHA256(trimmed) else {
            throw ReporterError.invalidCertificatePin
        }
        return normalized
    }

    private func mappedTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else {
            return error
        }
        switch urlError.code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return ReporterError.tlsValidationFailed
        default:
            return error
        }
    }
}
