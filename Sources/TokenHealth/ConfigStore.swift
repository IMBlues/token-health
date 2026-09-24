import Foundation

final class ConfigStore {
    private let defaultsKey = "service.configs.v2"
    // Leave v1 untouched so older builds can still load their last compatible snapshot.
    private let legacyDefaultsKey = "service.configs.v1"
    private let reportHookDefaultsKey = "usage-report-hook.config.v1"
    private let refreshIntervalDefaultsKey = "refresh-interval.config.v1"
    private let pinnedProvidersDefaultsKey = "pinned-provider.config.v2"
    // 只存单个 pin 的旧键。只读不写：读到就当作一个元素的列表，与其他历史键的处理一致。
    private let legacyPinnedProviderDefaultsKey = "pinned-provider.config.v1"
    private let exchangeRateDefaultsKey = "exchange-rate.config.v1"
    private let secretsPrefix = "service.secrets.v1"
    private let defaults: UserDefaults
    private let secretStore: any SecretStoring

    init(defaults: UserDefaults = .standard, secretStore: any SecretStoring = KeychainStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    func loadConfigs() -> [ServiceConfig] {
        if let data = defaults.data(forKey: defaultsKey),
           let configs = try? JSONDecoder().decode([ServiceConfig].self, from: data) {
            return configs
        }
        if let data = defaults.data(forKey: legacyDefaultsKey),
           let configs = try? JSONDecoder().decode([ServiceConfig].self, from: data) {
            return configs
        }
        return []
    }

    func saveConfigs(_ configs: [ServiceConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else {
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    func loadReportHookConfig() -> ReportHookConfig {
        guard let data = defaults.data(forKey: reportHookDefaultsKey),
              let config = try? JSONDecoder().decode(ReportHookConfig.self, from: data) else {
            return .defaultValue
        }
        return config
    }

    func saveReportHookConfig(_ config: ReportHookConfig) {
        guard let data = try? JSONEncoder().encode(config) else {
            return
        }
        defaults.set(data, forKey: reportHookDefaultsKey)
    }

    /// Returns nil when nothing was stored, so the caller can apply its own default.
    func loadRefreshInterval() -> TimeInterval? {
        let stored = defaults.double(forKey: refreshIntervalDefaultsKey)
        return stored > 0 ? stored : nil
    }

    func saveRefreshInterval(_ interval: TimeInterval) {
        defaults.set(interval, forKey: refreshIntervalDefaultsKey)
    }

    func loadPinnedConfigIDs() -> [UUID] {
        if let data = defaults.data(forKey: pinnedProvidersDefaultsKey),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            return ids
        }
        if let raw = defaults.string(forKey: legacyPinnedProviderDefaultsKey),
           let id = UUID(uuidString: raw) {
            return [id]
        }
        return []
    }

    func savePinnedConfigIDs(_ ids: [UUID]) {
        guard let data = try? JSONEncoder().encode(ids) else {
            return
        }
        defaults.set(data, forKey: pinnedProvidersDefaultsKey)
    }

    func loadExchangeRate() -> ExchangeRateTable? {
        guard let data = defaults.data(forKey: exchangeRateDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ExchangeRateTable.self, from: data)
    }

    func saveExchangeRate(_ table: ExchangeRateTable) {
        guard let data = try? JSONEncoder().encode(table) else {
            return
        }
        defaults.set(data, forKey: exchangeRateDefaultsKey)
    }

    func loadReportHookToken() -> String {
        secretStore.loadReportHookToken()
    }

    func saveReportHookToken(_ token: String) throws {
        try secretStore.saveReportHookToken(token)
    }

    func migrateLegacySecrets(for configs: [ServiceConfig]) throws {
        try secretStore.migrateLegacyItems(for: Set(configs.map(\.id)))
    }

    func loadSecrets(for configID: UUID) -> ProviderSecrets {
        let stored = secretStore.loadSecrets(for: configID)
        if !stored.apiKey.isEmpty || !stored.password.isEmpty {
            return stored
        }

        let legacy = ProviderSecrets(
            apiKey: defaults.string(forKey: secretKey(configID, "apiKey")) ?? "",
            password: defaults.string(forKey: secretKey(configID, "password")) ?? ""
        )
        if !legacy.apiKey.isEmpty || !legacy.password.isEmpty {
            if (try? secretStore.saveSecrets(legacy, for: configID)) != nil {
                removeLegacySecrets(for: configID)
            }
        }
        return legacy
    }

    func saveSecrets(_ secrets: ProviderSecrets, for configID: UUID) throws {
        try secretStore.saveSecrets(secrets, for: configID)
        removeLegacySecrets(for: configID)
    }

    func deleteConfig(_ config: ServiceConfig, from configs: inout [ServiceConfig]) throws {
        try secretStore.deleteSecrets(for: config.id)
        configs.removeAll { $0.id == config.id }
        removeLegacySecrets(for: config.id)
        saveConfigs(configs)
    }

    private func secretKey(_ configID: UUID, _ field: String) -> String {
        "\(secretsPrefix).\(configID.uuidString).\(field)"
    }

    private func removeLegacySecrets(for configID: UUID) {
        defaults.removeObject(forKey: secretKey(configID, "apiKey"))
        defaults.removeObject(forKey: secretKey(configID, "password"))
    }
}
