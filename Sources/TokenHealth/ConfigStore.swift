import Foundation

final class ConfigStore {
    private let defaultsKey = "service.configs.v1"
    private let secretsPrefix = "service.secrets.v1"
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func loadConfigs() -> [ServiceConfig] {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([ServiceConfig].self, from: data)) ?? []
    }

    func saveConfigs(_ configs: [ServiceConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else {
            return
        }
        defaults.set(data, forKey: defaultsKey)
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

    func deleteConfig(_ config: ServiceConfig, from configs: inout [ServiceConfig]) {
        configs.removeAll { $0.id == config.id }
        keychain.deleteSecrets(for: config.id)
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
