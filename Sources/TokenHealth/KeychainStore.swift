import Foundation
import LocalAuthentication
import Security

final class KeychainStore {
    private struct CredentialVault: Codable {
        var providerSecrets: [String: ProviderSecrets]
        var reportHookToken: String?
        var legacyMigrationComplete: Bool

        static let empty = CredentialVault(
            providerSecrets: [:],
            reportHookToken: nil,
            legacyMigrationComplete: false
        )

        private enum CodingKeys: String, CodingKey {
            case providerSecrets
            case reportHookToken
            case legacyMigrationComplete
        }

        init(
            providerSecrets: [String: ProviderSecrets],
            reportHookToken: String?,
            legacyMigrationComplete: Bool
        ) {
            self.providerSecrets = providerSecrets
            self.reportHookToken = reportHookToken
            self.legacyMigrationComplete = legacyMigrationComplete
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerSecrets = try container.decodeIfPresent(
                [String: ProviderSecrets].self,
                forKey: .providerSecrets
            ) ?? [:]
            reportHookToken = try container.decodeIfPresent(String.self, forKey: .reportHookToken)
            legacyMigrationComplete = try container.decodeIfPresent(
                Bool.self,
                forKey: .legacyMigrationComplete
            ) ?? false
        }
    }

    private enum Secret: String {
        case apiKey
        case password
    }

    private let service = "local.token-health.credentials"
    private let vaultAccount = "credential-vault.v1"
    private let reportTokenAccount = "usage-report-hook.bearer-token"
    private let authenticationContext = LAContext()
    private var cachedVault: CredentialVault?
    private var vaultLoadError: OSStatus?

    func loadSecrets(for id: UUID) -> ProviderSecrets {
        let vault = loadVault()
        let key = id.uuidString
        if let secrets = vault.providerSecrets[key] {
            return secrets
        }
        return .empty
    }

    func saveSecrets(_ secrets: ProviderSecrets, for id: UUID) throws {
        var vault = loadVault()
        try throwIfVaultLoadFailed()
        let key = id.uuidString
        let changed: Bool
        if secrets == .empty {
            changed = vault.providerSecrets.removeValue(forKey: key) != nil
        } else if vault.providerSecrets[key] != secrets {
            vault.providerSecrets[key] = secrets
            changed = true
        } else {
            changed = false
        }
        guard changed else {
            return
        }
        try saveVault(vault)
    }

    func deleteSecrets(for id: UUID) throws {
        var vault = loadVault()
        try throwIfVaultLoadFailed()
        if vault.providerSecrets.removeValue(forKey: id.uuidString) != nil {
            try saveVault(vault)
        }
        try delete(account: legacyAccount(.apiKey, id: id))
        try delete(account: legacyAccount(.password, id: id))
    }

    func loadReportHookToken() -> String {
        let vault = loadVault()
        if let token = vault.reportHookToken {
            return token
        }
        return ""
    }

    func saveReportHookToken(_ token: String) throws {
        var vault = loadVault()
        try throwIfVaultLoadFailed()
        guard vault.reportHookToken != token else {
            return
        }
        vault.reportHookToken = token
        try saveVault(vault)
    }

    func migrateLegacyItems(for activeConfigIDs: Set<UUID>) throws {
        var vault = loadVault()
        try throwIfVaultLoadFailed()
        guard !vault.legacyMigrationComplete else {
            return
        }

        let result = copyAllAccounts()
        guard result.status == errSecSuccess || result.status == errSecItemNotFound else {
            throw keychainError(status: result.status, operation: "migration read")
        }

        var legacyProviders: [String: ProviderSecrets] = [:]
        for account in result.accounts where account != vaultAccount {
            if account == reportTokenAccount {
                if vault.reportHookToken == nil {
                    vault.reportHookToken = try copyLegacyString(account: account)
                }
                continue
            }

            let apiKeySuffix = ".\(Secret.apiKey.rawValue)"
            let passwordSuffix = ".\(Secret.password.rawValue)"
            let id: String
            let secret: Secret
            if account.hasSuffix(apiKeySuffix) {
                id = String(account.dropLast(apiKeySuffix.count))
                secret = .apiKey
            } else if account.hasSuffix(passwordSuffix) {
                id = String(account.dropLast(passwordSuffix.count))
                secret = .password
            } else {
                continue
            }
            guard let configID = UUID(uuidString: id),
                  activeConfigIDs.contains(configID),
                  vault.providerSecrets[id] == nil else {
                continue
            }

            let value = try copyLegacyString(account: account)
            var secrets = legacyProviders[id] ?? .empty
            switch secret {
            case .apiKey:
                secrets.apiKey = value
            case .password:
                secrets.password = value
            }
            legacyProviders[id] = secrets
        }
        for (id, secrets) in legacyProviders where vault.providerSecrets[id] == nil {
            vault.providerSecrets[id] = secrets
        }
        vault.legacyMigrationComplete = true
        try saveVault(vault)
    }

    private func legacyAccount(_ secret: Secret, id: UUID) -> String {
        "\(id.uuidString).\(secret.rawValue)"
    }

    private func loadVault() -> CredentialVault {
        if let cachedVault {
            return cachedVault
        }
        if vaultLoadError != nil {
            return .empty
        }
        let result = copyData(account: vaultAccount)
        var vault: CredentialVault
        switch result.status {
        case errSecSuccess:
            guard let data = result.data,
                  let decoded = try? JSONDecoder().decode(CredentialVault.self, from: data) else {
                vaultLoadError = errSecDecode
                return .empty
            }
            vault = decoded
        case errSecItemNotFound:
            vault = .empty
        default:
            vaultLoadError = result.status
            return .empty
        }
        cachedVault = vault
        return vault
    }

    private func copyLegacyString(account: String) throws -> String {
        let result = copyData(account: account)
        guard result.status == errSecSuccess else {
            throw keychainError(status: result.status, operation: "legacy read")
        }
        guard let data = result.data,
              let value = String(data: data, encoding: .utf8) else {
            throw keychainError(status: errSecDecode, operation: "legacy decode")
        }
        return value
    }

    private func saveVault(_ vault: CredentialVault) throws {
        try throwIfVaultLoadFailed()
        let data = try JSONEncoder().encode(vault)
        try save(data, account: vaultAccount)
        cachedVault = vault
    }

    private func copyData(account: String) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    private func copyAllAccounts() -> (status: OSStatus, accounts: [String]) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if let items = result as? [[String: Any]] {
            return (status, items.compactMap { $0[kSecAttrAccount as String] as? String })
        }
        if let item = result as? [String: Any] {
            return (status, [item[kSecAttrAccount as String] as? String].compactMap { $0 })
        }
        return (status, [])
    }

    private func save(_ data: Data, account: String) throws {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var updateQuery = itemQuery
        updateQuery[kSecUseAuthenticationContext as String] = authenticationContext
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(status: updateStatus, operation: "update")
        }

        var item = itemQuery
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(status: addStatus, operation: "write")
        }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status: status, operation: "delete")
        }
    }

    private func keychainError(status: OSStatus, operation: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Keychain \(operation) failed: \(status)"]
        )
    }

    private func throwIfVaultLoadFailed() throws {
        if let vaultLoadError {
            throw keychainError(status: vaultLoadError, operation: "read")
        }
    }

}
