import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case anthropic
    case cursor
    case codex
    case kimiCode
    case zhipuCode
    case deepSeek
    case miniMax
    case volcengineArk
    case openCodeGo
    case genericHTTP
    case demo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .kimiCode: "Kimi Code"
        case .zhipuCode: "Zhipu Coding"
        case .deepSeek: "DeepSeek"
        case .miniMax: "MiniMax"
        case .volcengineArk: "Volcengine Ark"
        case .openCodeGo: "OpenCode Go"
        case .genericHTTP: "Generic HTTP"
        case .demo: "Demo"
        }
    }

    var supportsWebLogin: Bool {
        switch self {
        case .kimiCode, .zhipuCode, .deepSeek, .miniMax, .volcengineArk, .openCodeGo:
            true
        case .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            false
        }
    }

    /// Providers whose normal credential path is the web session rather than a plain API key, so a
    /// new config for them should start in Login mode. Excludes the single-API-key providers, which
    /// ship an endpoint of their own.
    var defaultsToBrowserLogin: Bool {
        supportsWebLogin && !usesWebSession && !usesSingleAPIKeyOnly
    }

    var usesWebSession: Bool {
        switch self {
        case .kimiCode, .zhipuCode, .miniMax, .volcengineArk:
            true
        case .openAI, .anthropic, .cursor, .codex, .deepSeek, .openCodeGo, .genericHTTP, .demo:
            false
        }
    }

    var usesLocalLogin: Bool {
        self == .cursor || self == .codex
    }

    /// Provider 只用单个 API key（endpoint 内置于适配器），无需 API endpoint / 本地数据 / 账号密码字段。
    var usesSingleAPIKeyOnly: Bool {
        self == .openCodeGo
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
    /// 展示币种（目前只有 DeepSeek 用）。nil 表示按原币种展示。
    var displayCurrency: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        providerKind: ProviderKind,
        authMode: AuthMode,
        apiEndpoint: String = "",
        usageDataPath: String = "",
        username: String = "",
        isEnabled: Bool = true,
        displayCurrency: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.providerKind = providerKind
        self.authMode = authMode
        self.apiEndpoint = apiEndpoint
        self.usageDataPath = usageDataPath
        self.username = username
        self.isEnabled = isEnabled
        self.displayCurrency = displayCurrency
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
        case displayCurrency
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
        displayCurrency = try container.decodeIfPresent(String.self, forKey: .displayCurrency)
    }
}

struct ProviderSecrets: Codable, Equatable, Sendable {
    var apiKey: String
    var password: String

    static let empty = ProviderSecrets(apiKey: "", password: "")
}

enum UsageWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    case balance
    case tokenQuota
    case todayCost
    case todayTokens
    case todayRequests
    case fiveHours
    case week
    case month
    case mcpMonth
    case videoGift
    case sevenDaysTokens
    case sevenDaysTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balance: "Balance"
        case .tokenQuota: "Usage"
        case .todayCost: "Today Cost"
        case .todayTokens: "Today Tokens"
        case .todayRequests: "Today Requests"
        case .fiveHours: "5h"
        case .week: "Week"
        case .month: "Month"
        case .mcpMonth: "MCP Month"
        case .videoGift: "Video Gift"
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
    var displayValue: String? = nil
    /// 金额型窗口的数值本身（`unit` 是币种代码）。卡片读 `displayValue`；
    /// 需要重新换算的展示（钉住的菜单栏项）读这个。
    var amount: Decimal? = nil

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
    /// Provider 提供的明细。为 nil 就不弹详情浮层。
    var detail: UsageDetail? = nil
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
