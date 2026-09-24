import Foundation
import WebKit

@MainActor
final class WebSessionRegistry {
    static let shared = WebSessionRegistry()

    private let makeDataStore: @MainActor (UUID) -> WKWebsiteDataStore
    private let clearProfile: @MainActor (UUID) async -> Void
    private var controllers: [UUID: (kind: ProviderKind, controller: WebSessionController)] = [:]
    private var evictionsInFlight: Set<UUID> = []

    init(
        makeDataStore: @escaping @MainActor (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        clearProfile: @escaping @MainActor (UUID) async -> Void = { await WebSessionRegistry.clearPersistentProfile($0) }
    ) {
        self.makeDataStore = makeDataStore
        self.clearProfile = clearProfile
    }

    /// Returns this config's kernel, creating it on first use; nil when the provider cannot log in
    /// through a browser, or while the account is being deleted.
    func controller(for config: ServiceConfig) -> WebSessionController? {
        guard !evictionsInFlight.contains(config.id) else {
            return nil
        }
        if let cached = controllers[config.id] {
            guard cached.kind != config.providerKind else {
                return cached.controller
            }
            // The provider was changed under this config, so the cached kernel is for the wrong
            // site. Drop it; its profile (keyed by config id) stays where it is and is cleaned up
            // when the config is deleted.
            controllers.removeValue(forKey: config.id)
            Task { await cached.controller.teardown() }
        }
        return makeController(for: config)
    }

    private func makeController(for config: ServiceConfig) -> WebSessionController? {
        guard let descriptor = WebSessionDescriptorFactory().descriptor(for: config.providerKind) else {
            return nil
        }
        let controller = WebSessionController(
            configID: config.id,
            descriptor: descriptor,
            dataStore: makeDataStore(config.id)
        )
        controllers[config.id] = (kind: config.providerKind, controller: controller)
        return controller
    }

    /// Deletes an account: evicts the kernel and clears the profile on disk.
    /// `config.id` is tombstoned for the duration of the eviction, so `controller(for:)` cannot
    /// build a new kernel on a profile that is about to be removed. The profile is cleared
    /// unconditionally — even if no kernel was created in this run (app restarted, then deleted
    /// the account), or if its provider kind has since changed to something the factory no longer
    /// recognises.
    ///
    /// `teardown()` first unblocks any in-flight load or script wait, closes the login window and
    /// yields once so those tasks get a chance to release their WebView.
    func evict(config: ServiceConfig) async {
        evictionsInFlight.insert(config.id)
        defer { evictionsInFlight.remove(config.id) }

        let removed = controllers.removeValue(forKey: config.id)
        if let removed {
            await removed.controller.teardown()
        }
        await clearProfile(config.id)
    }

    /// 清掉这个 id 在 WebKit 里的全部网页数据。
    ///
    /// 别改回「先问有没有 profile，再 `remove(forIdentifier:)`」那套。那两条路在某些 macOS
    /// 上都会让 WebKit 在 `WebsiteDataStoreIO` 队列里 SIGSEGV（`os_unfair_lock_lock` 踩在
    /// 地址 0x40 上；一个只调这一句的空 App 都能复现）：`allDataStoreIdentifiers` 无条件崩，
    /// 对没有 store 的 id 调 `remove` 则崩在 `removeDataStoreWithIdentifierImpl` 里。
    ///
    /// 而且 `remove` 就算不崩也不见得有用：它要求 store 无人使用，但 `teardown()` 明确不是
    /// 屏障，WebView 往往还活着，于是它以 "Data store is in use" 失败 —— 数据一点没清掉。
    ///
    /// `dataStoreForIdentifier:` 文档保证「不存在就创建」，是安全的；建出来直接把数据擦干。
    /// 代价是给从没有过 profile 的账号也留一个空的 store 目录（约 180K），换来这条路永远
    /// 不崩、也永远真的清掉。
    static func clearPersistentProfile(_ id: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: id)
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }
}
