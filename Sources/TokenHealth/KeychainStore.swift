import Foundation
import Security

final class KeychainStore {
    enum Secret: String {
        case apiKey
        case password
    }

    private let service = "local.token-health.credentials"

    func loadSecrets(for id: UUID) -> ProviderSecrets {
        ProviderSecrets(
            apiKey: load(.apiKey, for: id) ?? "",
            password: load(.password, for: id) ?? ""
        )
    }

    func saveSecrets(_ secrets: ProviderSecrets, for id: UUID) throws {
        try save(secrets.apiKey, secret: .apiKey, for: id)
        try save(secrets.password, secret: .password, for: id)
    }

    func deleteSecrets(for id: UUID) {
        delete(.apiKey, for: id)
        delete(.password, for: id)
    }

    private func account(_ secret: Secret, id: UUID) -> String {
        "\(id.uuidString).\(secret.rawValue)"
    }

    private func load(_ secret: Secret, for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(secret, id: id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, secret: Secret, for id: UUID) throws {
        delete(secret, for: id)
        guard !value.isEmpty else {
            return
        }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(secret, id: id),
            kSecValueData as String: Data(value.utf8)
        ]

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain write failed: \(status)"]
            )
        }
    }

    private func delete(_ secret: Secret, for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(secret, id: id)
        ]
        SecItemDelete(query as CFDictionary)
    }
}
