import Foundation
import Security
import Testing
@testable import TokenHealth

/// 可编排的钥匙串替身：由测试决定「系统授不授权」，以及某次读取要不要先挂住
/// （模拟系统授权框弹着不返回）。真机上这套状态只有系统能造出来。
private final class FakeKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: Data]] = [:]
    private var authorized = true
    private var gateArmed = false
    private var gateBlockedReads = 0
    private let gate = DispatchSemaphore(value: 0)

    func seed(service: String, account: String, data: Data) {
        lock.lock()
        items[service, default: [:]][account] = data
        lock.unlock()
    }

    func rawData(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[service]?[account]
    }

    func setAuthorized(_ value: Bool) {
        lock.lock()
        authorized = value
        lock.unlock()
    }

    /// 让下一次读取在返回前先挂住，直到 `openGate()`。
    func armGate() {
        lock.lock()
        gateArmed = true
        lock.unlock()
    }

    func openGate() {
        gate.signal()
    }

    /// 等到确实有读取被门闩挂住为止。
    func waitUntilAReadIsBlocked() {
        while true {
            lock.lock()
            let blocked = gateBlockedReads
            lock.unlock()
            if blocked > 0 {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        lock.lock()
        let shouldBlock = gateArmed
        let isAuthorized = authorized
        lock.unlock()
        if shouldBlock {
            lock.lock()
            gateBlockedReads += 1
            lock.unlock()
            gate.wait()
            lock.lock()
            gateArmed = false
            lock.unlock()
        }
        guard isAuthorized else {
            return (errAuthorizationInternal, nil)
        }
        lock.lock()
        let data = items[service]?[account]
        lock.unlock()
        if let data {
            return (errSecSuccess, data)
        }
        return (errSecItemNotFound, nil)
    }

    func copyAllAccounts(service: String) -> (status: OSStatus, accounts: [String]) {
        lock.lock()
        let isAuthorized = authorized
        let accounts = Array((items[service] ?? [:]).keys)
        lock.unlock()
        guard isAuthorized else {
            return (errAuthorizationInternal, [])
        }
        return accounts.isEmpty ? (errSecItemNotFound, []) : (errSecSuccess, accounts)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard authorized else { return errAuthorizationInternal }
        guard items[service]?[account] != nil else { return errSecItemNotFound }
        items[service]?[account] = data
        return errSecSuccess
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard authorized else { return errAuthorizationInternal }
        items[service, default: [:]][account] = data
        return errSecSuccess
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard authorized else { return errAuthorizationInternal }
        guard items[service]?[account] != nil else { return errSecItemNotFound }
        items[service]?.removeValue(forKey: account)
        return errSecSuccess
    }
}

/// 回归自 2026-09-26 的实机事故：App 重建后系统弹钥匙串授权框，没人应答、约 47 分钟后
/// 超时返回 -60008；旧实现把这次失败缓存成终身状态，凭据到 App 重启前都读不出来，而且
/// 没有恢复路径。下面的测试钉住修复后的行为。
struct KeychainStoreTests {
    private let service = "local.token-health.credentials"
    private let vaultAccount = "credential-vault.v1"

    /// 按 KeychainStore 的存储格式播种：真实条目就是这个 JSON。
    private struct SeededVault: Encodable {
        var providerSecrets: [String: ProviderSecrets]
        var legacyMigrationComplete: Bool
    }

    private func vaultData(_ secrets: [UUID: ProviderSecrets]) throws -> Data {
        let encoded = secrets.reduce(into: [String: ProviderSecrets]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        return try JSONEncoder().encode(
            SeededVault(providerSecrets: encoded, legacyMigrationComplete: true)
        )
    }

    @Test
    func authorizationFailureIsRecoverable() async throws {
        let backing = FakeKeychainBacking()
        backing.setAuthorized(false)
        let store = KeychainStore(backing: backing)

        await store.prepareVault()
        #expect(store.vaultAvailability == .unavailable(errAuthorizationInternal))
        #expect(store.loadSecrets(for: UUID()) == .empty)

        // 读不到时写入必须失败：整个凭据库是一个条目，拿空库去写等于抹掉所有账号。
        var saveError: Error?
        do {
            try store.saveSecrets(ProviderSecrets(apiKey: "k", password: ""), for: UUID())
        } catch {
            saveError = error
        }
        let message = try #require(saveError?.localizedDescription)
        #expect(message.contains("-60008"))
        #expect(message.contains("authorize"))

        // 用户去系统弹框里点了「允许」：同一个进程内必须能当场恢复，不必重启 App。
        backing.setAuthorized(true)
        let issue = await store.retryVaultLoad()
        #expect(issue == nil)
        #expect(store.vaultAvailability == .ready)

        let id = UUID()
        try store.saveSecrets(ProviderSecrets(apiKey: "recovered", password: ""), for: id)
        #expect(store.loadSecrets(for: id).apiKey == "recovered")
    }

    @Test
    func failedAuthorizationDoesNotPersistAcrossRestart() async throws {
        let id = UUID()
        let backing = FakeKeychainBacking()
        backing.seed(service: service, account: vaultAccount, data: try vaultData([
            id: ProviderSecrets(apiKey: "stored", password: "pw")
        ]))

        // 第一次启动：系统拒绝授权。
        backing.setAuthorized(false)
        let first = KeychainStore(backing: backing)
        await first.prepareVault()
        #expect(first.loadSecrets(for: id) == .empty)

        // 重启 App 且这次授权通过：旧实现只把失败缓存在实例里，重来一次就该读到数据。
        backing.setAuthorized(true)
        let second = KeychainStore(backing: backing)
        await second.prepareVault()
        #expect(second.vaultAvailability == .ready)
        #expect(second.loadSecrets(for: id) == ProviderSecrets(apiKey: "stored", password: "pw"))
    }

    @Test
    func seededVaultSurvivesRoundTrip() async throws {
        let id = UUID()
        let backing = FakeKeychainBacking()
        backing.seed(service: service, account: vaultAccount, data: try vaultData([
            id: ProviderSecrets(apiKey: "web-session", password: "")
        ]))
        let store = KeychainStore(backing: backing)

        await store.prepareVault()
        #expect(store.vaultAvailability == .ready)
        #expect(store.loadSecrets(for: id).apiKey == "web-session")

        // 改一个账号不能动到另一个账号。
        let other = UUID()
        try store.saveSecrets(ProviderSecrets(apiKey: "other", password: ""), for: other)
        #expect(store.loadSecrets(for: id).apiKey == "web-session")
        #expect(store.loadSecrets(for: other).apiKey == "other")
    }

    @Test
    func writeWhileTheFirstReadIsPendingIsRefused() async throws {
        let id = UUID()
        let backing = FakeKeychainBacking()
        let original = try vaultData([id: ProviderSecrets(apiKey: "keep-me", password: "")])
        backing.seed(service: service, account: vaultAccount, data: original)
        backing.armGate()

        let store = KeychainStore(backing: backing)
        let preparing = Task { await store.prepareVault() }
        backing.waitUntilAReadIsBlocked()

        // 首次读取还挂着（等系统授权框）时，凭据库对写路径就是「不可用」而不是「空」。
        var saveError: Error?
        do {
            try store.saveSecrets(ProviderSecrets(apiKey: "new", password: ""), for: id)
        } catch {
            saveError = error
        }
        #expect(saveError != nil)
        #expect(backing.rawData(service: service, account: vaultAccount) == original)

        backing.openGate()
        await preparing.value
        #expect(store.vaultAvailability == .ready)
        #expect(store.loadSecrets(for: id).apiKey == "keep-me")
    }

    @Test
    func legacyMigrationCopiesItemsAndRunsOnce() async throws {
        let activeID = UUID()
        let inactiveID = UUID()
        let backing = FakeKeychainBacking()
        backing.seed(
            service: service,
            account: "\(activeID.uuidString).apiKey",
            data: Data("legacy-key".utf8)
        )
        backing.seed(
            service: service,
            account: "\(inactiveID.uuidString).apiKey",
            data: Data("orphan-key".utf8)
        )

        let store = KeychainStore(backing: backing)
        await store.prepareVault()
        try store.migrateLegacyItems(for: [activeID])

        #expect(store.loadSecrets(for: activeID).apiKey == "legacy-key")
        // 已删除账号的遗留条目不该被搬回来。
        #expect(store.loadSecrets(for: inactiveID).apiKey == "")

        // 第二次迁移是空操作（legacyMigrationComplete 已落地）。
        try store.migrateLegacyItems(for: [activeID])
        #expect(store.loadSecrets(for: activeID).apiKey == "legacy-key")
    }

    @Test
    func errorMessagesExplainAuthorizationStalls() {
        #expect(KeychainStore.isAuthorizationFailure(errAuthorizationInternal))
        #expect(!KeychainStore.isAuthorizationFailure(errSecItemNotFound))
        let message = KeychainStore.message(status: errAuthorizationInternal, operation: "read")
        #expect(message.contains("Keychain read failed: -60008"))
        #expect(message.contains("did not authorize"))
        #expect(message.contains("Always Allow"))
    }
}
