import Foundation
@testable import TokenHealth

/// 测试用的凭据存放处。
///
/// 真机上 `KeychainStore` 里已经有条目，测试进程去读会触发系统授权框并卡住，
/// 所以凡是会经过凭据的测试都必须注入这个替身。
///
/// `@unchecked Sendable`：可变字典本身没有加锁，但测试都在单个线程里驱动它。
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var stored: [UUID: ProviderSecrets] = [:]
    private var reportToken = ""
    private(set) var migratedConfigIDs: Set<UUID>?

    func loadSecrets(for id: UUID) -> ProviderSecrets {
        stored[id] ?? .empty
    }

    func saveSecrets(_ secrets: ProviderSecrets, for id: UUID) throws {
        if secrets == .empty {
            stored.removeValue(forKey: id)
        } else {
            stored[id] = secrets
        }
    }

    func deleteSecrets(for id: UUID) throws {
        stored.removeValue(forKey: id)
    }

    func loadReportHookToken() -> String {
        reportToken
    }

    func saveReportHookToken(_ token: String) throws {
        reportToken = token
    }

    func migrateLegacyItems(for activeConfigIDs: Set<UUID>) throws {
        migratedConfigIDs = activeConfigIDs
    }

    // 替身没有系统授权这一步：凭据永远当场可读，没有「等授权」和「重新授权」。
    var vaultAvailability: SecretVaultAvailability { .ready }

    func prepareVault() async {}

    func retryVaultLoad() async -> String? { nil }
}
