import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case anthropic
    case cursor
    case kimiCode
    case zhipuCode
    case genericHTTP
    case demo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .cursor: "Cursor"
        case .kimiCode: "Kimi Code"
        case .zhipuCode: "Zhipu Coding"
        case .genericHTTP: "Generic HTTP"
        case .demo: "Demo"
        }
    }

    var usesWebSession: Bool {
        switch self {
        case .kimiCode, .zhipuCode:
            true
        case .openAI, .anthropic, .cursor, .genericHTTP, .demo:
            false
        }
    }
}

enum AuthMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case api
    case browserLogin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .api: "API"
        case .browserLogin: "Login"
        }
    }
}

struct ServiceConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var providerKind: ProviderKind
    var authMode: AuthMode
    var apiEndpoint: String
    var usageDataPath: String
    var username: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        providerKind: ProviderKind,
        authMode: AuthMode,
        apiEndpoint: String = "",
        usageDataPath: String = "",
        username: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.providerKind = providerKind
        self.authMode = authMode
        self.apiEndpoint = apiEndpoint
        self.usageDataPath = usageDataPath
        self.username = username
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case providerKind
        case authMode
        case apiEndpoint
        case usageDataPath
        case username
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        providerKind = try container.decode(ProviderKind.self, forKey: .providerKind)
        authMode = try container.decode(AuthMode.self, forKey: .authMode)
        apiEndpoint = try container.decodeIfPresent(String.self, forKey: .apiEndpoint) ?? ""
        usageDataPath = try container.decodeIfPresent(String.self, forKey: .usageDataPath) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct ProviderSecrets: Equatable, Sendable {
    var apiKey: String
    var password: String

    static let empty = ProviderSecrets(apiKey: "", password: "")
}

enum UsageWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHours
    case week
    case mcpMonth
    case sevenDaysTokens
    case sevenDaysTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHours: "5h"
        case .week: "Week"
        case .mcpMonth: "MCP Month"
        case .sevenDaysTokens: "7d Tokens"
        case .sevenDaysTools: "7d Tools"
        }
    }

    static var quotaWindows: [UsageWindow] {
        [.fiveHours, .week]
    }
}

struct TokenUsage: Codable, Equatable, Identifiable, Sendable {
    var window: UsageWindow
    var label: String? = nil
    var used: Int
    var limit: Int?
    var resetDate: Date?
    var unit: String? = nil

    var id: String {
        "\(window.rawValue):\(label ?? "")"
    }

    var ratio: Double? {
        guard let limit, limit > 0 else {
            return nil
        }
        return min(Double(used) / Double(limit), 1)
    }
}

struct ProviderUsageSnapshot: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case needsConfiguration
        case unavailable
    }

    var id: UUID
    var serviceName: String
    var providerTitle: String
    var planName: String? = nil
    var usages: [TokenUsage]
    var state: State
    var statusMessage: String
    var updatedAt: Date

    static func unavailable(config: ServiceConfig, message: String) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: config.id,
            serviceName: config.displayName,
            providerTitle: config.providerKind.title,
            usages: [],
            state: .unavailable,
            statusMessage: message,
            updatedAt: Date()
        )
    }
}
