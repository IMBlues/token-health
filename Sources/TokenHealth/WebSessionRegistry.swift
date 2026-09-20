import Foundation
import WebKit

@MainActor
final class WebSessionRegistry {
    static let shared = WebSessionRegistry()

    private let makeDataStore: @MainActor (UUID) -> WKWebsiteDataStore
    private let hasStoredProfile: @MainActor (UUID) async -> Bool
    private let removeProfile: @MainActor (UUID) async -> Void
    private var controllers: [UUID: (kind: ProviderKind, controller: WebSessionController)] = [:]
    private var evictionsInFlight: Set<UUID> = []

    init(
        makeDataStore: @escaping @MainActor (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        hasStoredProfile: @escaping @MainActor (UUID) async -> Bool = { await WebSessionRegistry.hasPersistentProfile($0) },
        removeProfile: @escaping @MainActor (UUID) async -> Void = { await WebSessionRegistry.removePersistentProfile($0) }
    ) {
        self.makeDataStore = makeDataStore
        self.hasStoredProfile = hasStoredProfile
        self.removeProfile = removeProfile
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
    /// build a new kernel on a profile that is about to be removed. The profile is cleared if this
    /// config ever had one — even if no kernel was created in this run (app restarted, then deleted
    /// the account), or if its provider kind has since changed to something the factory no longer
    /// recognises.
    ///
    /// `teardown()` first unblocks any in-flight load or script wait, closes the login window and
    /// yields once so those tasks get a chance to release their WebView; only then is the store
    /// removed (the SDK requires the WKWebViews using that store to be released first). It is
    /// **not** a hard barrier, so do not treat it here as "already drained".
    func evict(config: ServiceConfig) async {
        evictionsInFlight.insert(config.id)
        defer { evictionsInFlight.remove(config.id) }

        let removed = controllers.removeValue(forKey: config.id)
        if let removed {
            await removed.controller.teardown()
        }
        // Whether this config ever had a profile cannot be answered by this run's bookkeeping: the
        // provider kind may have changed, and the app may have restarted since. Ask the store.
        // (`||` cannot take an `await` on its right side, hence the two-step guard.)
        var hadProfile = removed != nil
            || WebSessionDescriptorFactory().descriptor(for: config.providerKind) != nil
        if !hadProfile {
            hadProfile = await hasStoredProfile(config.id)
        }
        guard hadProfile else {
            return
        }
        await removeProfile(config.id)
    }

    /// Whether a persistent profile for this id exists on disk. Unlike anything kept in memory, this
    /// answer survives an app restart.
    static func hasPersistentProfile(_ id: UUID) async -> Bool {
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        return identifiers.contains(id)
    }

    /// The caller must guarantee that no WKWebView using this store is still alive (a hard SDK
    /// requirement); `evict` reaches here only after `teardown()`.
    static func removePersistentProfile(_ id: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if let error {
                    WebSessionLog.error(
                        "profile removal failed for \(id.uuidString): \(error.localizedDescription)",
                        providerTitle: "WebSession"
                    )
                }
                continuation.resume()
            }
        }
    }
}
