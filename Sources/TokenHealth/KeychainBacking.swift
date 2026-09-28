import Foundation
import Security

/// 钥匙串条目的原始读写。
///
/// 抽成协议只有一个理由：让「系统没批准这次访问」这类失败能在测试里复现。真机上它表现为
/// 一个没人应答的授权框，超时后 `SecItemCopyMatching` 返回 -60008（errAuthorizationInternal）
/// —— 测试进程既弹不出这个框，也造不出这个状态码。
protocol KeychainBacking: Sendable {
    /// 读取条目数据。返回 `SecItemCopyMatching` 的原始状态码。
    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?)
    /// 列出 service 下所有条目的 account 名，供旧格式迁移用。
    func copyAllAccounts(service: String) -> (status: OSStatus, accounts: [String])
    func update(service: String, account: String, data: Data) -> OSStatus
    func add(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

/// 真机实现。刻意不传 `kSecUseAuthenticationContext`：条目是传统的 login 钥匙串条目，
/// 访问由 ACL 决定，跟 LAContext 无关 —— 一个长期持有的 LAContext 只会把授权流程多绕一层。
struct SecItemKeychainBacking: KeychainBacking {
    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func copyAllAccounts(service: String) -> (status: OSStatus, accounts: [String]) {
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

    func update(service: String, account: String, data: Data) -> OSStatus {
        SecItemUpdate(
            itemQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var item = itemQuery(service: service, account: account)
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(itemQuery(service: service, account: account) as CFDictionary)
    }

    private func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
