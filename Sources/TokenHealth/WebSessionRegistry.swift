import Foundation
import WebKit

@MainActor
final class WebSessionRegistry {
    static let shared = WebSessionRegistry()

    private let makeDataStore: @MainActor (UUID) -> WKWebsiteDataStore
    private let removeProfile: @MainActor (UUID) async -> Void
    private var controllers: [UUID: WebSessionController] = [:]

    init(
        makeDataStore: @escaping @MainActor (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        removeProfile: @escaping @MainActor (UUID) async -> Void = { await WebSessionRegistry.removePersistentProfile($0) }
    ) {
        self.makeDataStore = makeDataStore
        self.removeProfile = removeProfile
    }

    /// Returns this config's kernel, creating it if absent; nil when the provider does not support web login.
    func controller(for config: ServiceConfig) -> WebSessionController? {
        if let existing = controllers[config.id] {
            return existing
        }
        guard let descriptor = WebSessionDescriptorFactory().descriptor(for: config.providerKind) else {
            return nil
        }
        let controller = WebSessionController(
            configID: config.id,
            descriptor: descriptor,
            dataStore: makeDataStore(config.id)
        )
        controllers[config.id] = controller
        return controller
    }

    /// Deletes an account: evicts the kernel and clears the profile on disk.
    /// The profile is cleared even if no kernel was created in this run (app restarted, then deleted the account).
    ///
    /// `teardown()` first unblocks any in-flight load or script wait, closes the login window and yields
    /// once so those tasks get a chance to release their WebView; only then is the store removed (the SDK
    /// requires the WKWebViews using that store to be released first). It is **not** a hard barrier, so do
    /// not treat it here as "already drained".
    func evict(config: ServiceConfig) async {
        if let controller = controllers.removeValue(forKey: config.id) {
            await controller.teardown()
        }
        guard WebSessionDescriptorFactory().descriptor(for: config.providerKind) != nil else {
            return
        }
        await removeProfile(config.id)
    }

    /// The caller must guarantee that no WKWebView using this store is still alive (a hard SDK
    /// requirement); `evict` reaches here only after `teardown()`.
    static func removePersistentProfile(_ id: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if let error {
                    WebSessionLog.debugLog(
                        "profile removal failed for \(id.uuidString): \(error.localizedDescription)",
                        providerTitle: "WebSession"
                    )
                }
                continuation.resume()
            }
        }
    }
}
