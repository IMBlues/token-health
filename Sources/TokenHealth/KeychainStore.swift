import Foundation
import Security

/// 凭据库的可用性，供界面决定要不要提示、要不要给「重新授权」入口。
enum SecretVaultAvailability: Equatable {
    /// 首次读取还没落地（可能正在等系统授权框）。
    case loading
    case ready
    /// 读不到凭据，关联值是 `SecItemCopyMatching` 的原始状态码。凭据库在系统授权之前
    /// 一律是这个状态，而不是「空库」—— 两者的区别是能不能写。
    case unavailable(OSStatus)
}

/// 凭据的存放处。抽成协议是为了让 ConfigStore 与 AppState 能在测试里不碰真实钥匙串 ——
/// 测试进程读钥匙串会触发系统授权，在无人值守时会直接卡住。
///
/// 要求 Sendable：首次读取要放到非主线程去等系统授权框（见 `prepareVault`），这条跨
/// 隔离域的调用链上不能有非 Sendable 的接收者。
protocol SecretStoring: Sendable {
    func loadSecrets(for id: UUID) -> ProviderSecrets
    func saveSecrets(_ secrets: ProviderSecrets, for id: UUID) throws
    func deleteSecrets(for id: UUID) throws
    func loadReportHookToken() -> String
    func saveReportHookToken(_ token: String) throws
    func migrateLegacyItems(for activeConfigIDs: Set<UUID>) throws

    var vaultAvailability: SecretVaultAvailability { get }

    /// 在后台完成首次读取。
    ///
    /// 这是唯一会**等**系统授权框的地方，所以它必须是 async 的：授权框没人应答时会一直
    /// 阻塞到超时（实测约 47 分钟），一旦钉在主线程上，整个 App 就是一块转圈的砖。
    func prepareVault() async

    /// 用户要求重新授权：解除「不再自动重试」的闸门，在后台再读一次。
    /// 返回 nil 表示这次读成功，否则是给用户看的说明。
    func retryVaultLoad() async -> String?
}

final class KeychainStore: SecretStoring, @unchecked Sendable {
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
    private let backing: any KeychainBacking

    /// 首次读取（可能等系统授权框）只在这条串行队列上做，绝不占用主线程。
    private static let loadQueue = DispatchQueue(
        label: "local.token-health.keychain-load",
        qos: .userInitiated
    )

    /// 下面几个状态会被主线程、串行队列和写路径同时碰，统一由这把锁保护。
    private let lock = NSLock()
    private var cachedVault: CredentialVault?
    private var loadFailure: OSStatus?
    private var isLoading = false
    /// 读失败之后不再自动重试：每次重试都会把系统授权框再弹一遍，只能等用户明确要求。
    private var retryBlocked = false

    init(backing: any KeychainBacking = SecurityToolKeychainBacking()) {
        self.backing = backing
    }

    // MARK: - 读

    var vaultAvailability: SecretVaultAvailability {
        lock.lock()
        defer { lock.unlock() }
        if cachedVault != nil {
            return .ready
        }
        if let loadFailure {
            return .unavailable(loadFailure)
        }
        return .loading
    }

    func loadSecrets(for id: UUID) -> ProviderSecrets {
        let vault = loadVault()
        let key = id.uuidString
        if let secrets = vault.providerSecrets[key] {
            return secrets
        }
        return .empty
    }

    func loadReportHookToken() -> String {
        let vault = loadVault()
        if let token = vault.reportHookToken {
            return token
        }
        return ""
    }

    func prepareVault() async {
        await withCheckedContinuation { continuation in
            Self.loadQueue.async {
                _ = self.loadVault()
                continuation.resume()
            }
        }
    }

    func retryVaultLoad() async -> String? {
        await withCheckedContinuation { continuation in
            Self.loadQueue.async {
                self.lock.lock()
                self.retryBlocked = false
                self.lock.unlock()
                _ = self.loadVault()
                continuation.resume(returning: self.vaultAccessIssueMessage())
            }
        }
    }

    /// 读一次钥匙串，结果进缓存。可能等系统授权框，**不要在写路径以外同步调用它**。
    private func loadVault() -> CredentialVault {
        lock.lock()
        if let cachedVault {
            lock.unlock()
            return cachedVault
        }
        if retryBlocked || isLoading {
            // 已经失败过（或正在读）就别再碰钥匙串：读不到就先当空库，写路径会拦住。
            lock.unlock()
            return .empty
        }
        isLoading = true
        lock.unlock()

        let result = backing.copyData(service: service, account: vaultAccount)

        var vault: CredentialVault
        var failure: OSStatus?
        switch result.status {
        case errSecSuccess:
            if let data = result.data,
               let decoded = try? JSONDecoder().decode(CredentialVault.self, from: data) {
                vault = decoded
            } else {
                vault = .empty
                failure = errSecDecode
            }
        case errSecItemNotFound:
            vault = .empty
        default:
            vault = .empty
            failure = result.status
        }

        lock.lock()
        isLoading = false
        loadFailure = failure
        if failure == nil {
            cachedVault = vault
            retryBlocked = false
        } else {
            retryBlocked = true
        }
        lock.unlock()
        return vault
    }

    // MARK: - 写

    func saveSecrets(_ secrets: ProviderSecrets, for id: UUID) throws {
        var vault = loadVault()
        try throwIfVaultUnavailable()
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
        try throwIfVaultUnavailable()
        if vault.providerSecrets.removeValue(forKey: id.uuidString) != nil {
            try saveVault(vault)
        }
        try delete(account: legacyAccount(.apiKey, id: id))
        try delete(account: legacyAccount(.password, id: id))
    }

    func saveReportHookToken(_ token: String) throws {
        var vault = loadVault()
        try throwIfVaultUnavailable()
        guard vault.reportHookToken != token else {
            return
        }
        vault.reportHookToken = token
        try saveVault(vault)
    }

    func migrateLegacyItems(for activeConfigIDs: Set<UUID>) throws {
        var vault = loadVault()
        try throwIfVaultUnavailable()
        guard !vault.legacyMigrationComplete else {
            return
        }

        let result = backing.copyAllAccounts(service: service)
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

    // MARK: - 底层读写

    private func legacyAccount(_ secret: Secret, id: UUID) -> String {
        "\(id.uuidString).\(secret.rawValue)"
    }

    private func copyLegacyString(account: String) throws -> String {
        let result = backing.copyData(service: service, account: account)
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
        let data = try JSONEncoder().encode(vault)
        try save(data, account: vaultAccount)
        lock.lock()
        cachedVault = vault
        lock.unlock()
    }

    private func save(_ data: Data, account: String) throws {
        let updateStatus = backing.update(service: service, account: account, data: data)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(status: updateStatus, operation: "update")
        }

        let addStatus = backing.add(service: service, account: account, data: data)
        guard addStatus == errSecSuccess else {
            throw keychainError(status: addStatus, operation: "write")
        }
    }

    private func delete(account: String) throws {
        let status = backing.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status: status, operation: "delete")
        }
    }

    // MARK: - 出错时说什么

    /// 写路径的前置条件。整个凭据库是一个条目，用没读到的库去写等于抹掉别的账号。
    private func throwIfVaultUnavailable() throws {
        lock.lock()
        let failure = loadFailure
        let loading = isLoading
        lock.unlock()
        if let failure {
            throw keychainError(status: failure, operation: "read")
        }
        if loading {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(errSecNotAvailable),
                userInfo: [NSLocalizedDescriptionKey: Self.pendingAuthorizationMessage]
            )
        }
    }

    /// 读失败时给用户看的说明；没有失败就是 nil。
    private func vaultAccessIssueMessage() -> String? {
        lock.lock()
        let failure = loadFailure
        lock.unlock()
        guard let failure else {
            return nil
        }
        return Self.message(status: failure, operation: "read")
    }

    private func keychainError(status: OSStatus, operation: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: Self.message(status: status, operation: operation)]
        )
    }

    static let pendingAuthorizationMessage =
        "Keychain access is still waiting for the macOS authorization prompt. "
        + "Approve it (choose \"Always Allow\") and try again."

    /// 授权类失败的原始状态码有三种来源：Authorization Services（-60008 等，实测就是这个）、
    /// Security 的 auth 类错误，以及弹框被用户取消。它们对用户是同一件事：需要他去弹框里点允许。
    static func isAuthorizationFailure(_ status: OSStatus) -> Bool {
        switch status {
        case errAuthorizationInternal,
             errAuthorizationCanceled,
             errAuthorizationDenied,
             errAuthorizationInteractionNotAllowed,
             errSecAuthFailed,
             errSecUserCanceled,
             errSecInteractionNotAllowed,
             errSecNotAvailable:
            return true
        default:
            return false
        }
    }

    static func message(status: OSStatus, operation: String) -> String {
        let base = "Keychain \(operation) failed: \(status)"
        if status == errSecDecode {
            return "\(base) — the stored credential vault could not be decoded."
        }
        if isAuthorizationFailure(status) {
            return "\(base) — macOS did not authorize this access: the authorization prompt was "
                + "denied, ignored, or timed out. Approve the macOS prompt next time, choose "
                + "\"Always Allow\", then use Retry Keychain Access in Settings."
        }
        return base
    }
}
