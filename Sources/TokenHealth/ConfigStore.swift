import Foundation

final class ConfigStore {
    private let defaultsKey = "service.configs.v2"
    // Leave v1 untouched so older builds can still load their last compatible snapshot.
    private let legacyDefaultsKey = "service.configs.v1"
    private let reportHookDefaultsKey = "usage-report-hook.config.v1"
    private let secretsPrefix = "service.secrets.v1"
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
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

    func loadReportHookToken() -> String {
        keychain.loadReportHookToken()
    }

    func saveReportHookToken(_ token: String) throws {
        try keychain.saveReportHookToken(token)
    }

    func migrateLegacySecrets(for configs: [ServiceConfig]) throws {
        try keychain.migrateLegacyItems(for: Set(configs.map(\.id)))
    }

    func loadSecrets(for configID: UUID) -> ProviderSecrets {
        let stored = keychain.loadSecrets(for: configID)
        if !stored.apiKey.isEmpty || !stored.password.isEmpty {
            return stored
        }

        let legacy = ProviderSecrets(
            apiKey: defaults.string(forKey: secretKey(configID, "apiKey")) ?? "",
            password: defaults.string(forKey: secretKey(configID, "password")) ?? ""
        )
        if !legacy.apiKey.isEmpty || !legacy.password.isEmpty {
            if (try? keychain.saveSecrets(legacy, for: configID)) != nil {
                removeLegacySecrets(for: configID)
            }
        }
        return legacy
    }

    func saveSecrets(_ secrets: ProviderSecrets, for configID: UUID) throws {
        try keychain.saveSecrets(secrets, for: configID)
        removeLegacySecrets(for: configID)
    }

    func deleteConfig(_ config: ServiceConfig, from configs: inout [ServiceConfig]) throws {
        try keychain.deleteSecrets(for: config.id)
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
