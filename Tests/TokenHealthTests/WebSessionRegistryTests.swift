import Foundation
import Testing
import WebKit
@testable import TokenHealth

@Suite
@MainActor
struct WebSessionRegistryTests {
    private final class ProfileRemovalSpy {
        var removed: [UUID] = []
    }

    private func makeRegistry(
        spy: ProfileRemovalSpy,
        existingProfiles: Set<UUID> = []
    ) -> WebSessionRegistry {
        WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            hasStoredProfile: { existingProfiles.contains($0) },
            removeProfile: { id in spy.removed.append(id) }
        )
    }

    private func deepSeekConfig() -> ServiceConfig {
        ServiceConfig(displayName: "DeepSeek", providerKind: .deepSeek, authMode: .browserLogin)
    }

    @Test
    func reusesControllerForSameConfig() {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        let config = deepSeekConfig()

        let first = registry.controller(for: config)
        let second = registry.controller(for: config)

        #expect(first != nil)
        #expect(first === second)
    }

    @Test
    func separatesControllersPerConfig() {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        let first = deepSeekConfig()
        let second = deepSeekConfig()

        let firstController = registry.controller(for: first)
        let secondController = registry.controller(for: second)
        #expect(firstController !== secondController)
    }

    @Test
    func returnsNilForProvidersWithoutDescriptor() {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        let config = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)

        #expect(registry.controller(for: config) == nil)
    }

    @Test
    func evictRemovesControllerAndProfile() async {
        let spy = ProfileRemovalSpy()
        let registry = makeRegistry(spy: spy)
        let config = deepSeekConfig()
        let first = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
        #expect(registry.controller(for: config) !== first)
    }

    @Test
    func evictClearsProfileEvenWithoutController() async {
        // 这次运行没建过 kernel，但盘上确实有 profile（App 重启过）。
        // 与下面那个用例的区别：这里 provider 类型**没变**，所以它只考验「缓存答不了就问 store」，
        // 不牵扯「类型变了」那条路径。
        let spy = ProfileRemovalSpy()
        let config = deepSeekConfig()
        let registry = makeRegistry(spy: spy, existingProfiles: [config.id])

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
    }

    @Test
    func evictLeavesOtherProvidersAlone() async {
        let spy = ProfileRemovalSpy()
        let registry = makeRegistry(spy: spy)
        let config = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)

        await registry.evict(config: config)

        #expect(spy.removed.isEmpty)
    }

    @Test
    func evictTearsTheKernelDownBeforeRemovingTheProfile() async {
        let spy = ProfileRemovalSpy()
        var tornDownWhenProfileRemoved: Bool?
        var controller: WebSessionController?
        let registry = WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            removeProfile: { id in
                // Read at the SDK call, not after evict returns: a post-hoc assertion would stay
                // green if evict were reordered to remove the profile first.
                tornDownWhenProfileRemoved = controller?.isTornDown
                spy.removed.append(id)
            }
        )
        let config = deepSeekConfig()
        controller = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(tornDownWhenProfileRemoved == true)
        #expect(spy.removed == [config.id])
    }

    @Test
    func refusesToBuildAKernelWhileAnEvictionIsInFlight() async {
        let config = deepSeekConfig()
        var rebuiltDuringEviction: WebSessionController?

        var registry: WebSessionRegistry!
        registry = WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            removeProfile: { _ in rebuiltDuringEviction = registry.controller(for: config) }
        )
        _ = registry.controller(for: config)

        await registry.evict(config: config)

        // The probe fires while `evict` is suspended mid-flight (kernel already torn down, profile
        // not yet removed). Without the tombstone it would build a new kernel on the profile that
        // the same `evict` is about to delete, violating the SDK's release-first precondition.
        #expect(rebuiltDuringEviction == nil)
    }

    @Test
    func rebuildingAfterEvictionYieldsAFreshKernel() async {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        let config = deepSeekConfig()
        let first = registry.controller(for: config)

        await registry.evict(config: config)
        let second = registry.controller(for: config)

        #expect(second != nil)
        #expect(first !== second)
    }

    @Test
    func changingTheProviderKindReplacesTheCachedKernel() async {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        var config = deepSeekConfig()
        let deepSeekKernel = registry.controller(for: config)

        config.providerKind = .demo
        #expect(registry.controller(for: config) == nil)

        await Task.yield()
        #expect(deepSeekKernel?.isTornDown == true)

        config.providerKind = .deepSeek
        let rebuilt = registry.controller(for: config)
        #expect(rebuilt !== deepSeekKernel)
    }

    @Test
    func evictClearsTheProfileAfterTheKernelWasDroppedByAProviderChange() async {
        let spy = ProfileRemovalSpy()
        var config = deepSeekConfig()
        let registry = makeRegistry(spy: spy, existingProfiles: [config.id])
        _ = registry.controller(for: config)

        config.providerKind = .demo
        _ = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
    }

    @Test
    func evictClearsAProfileThatOutlivedTheAppRun() async {
        // This account had a profile on disk from an earlier run, and this run never built a kernel
        // for it (the provider kind was changed away from a web-login kind, then the app restarted).
        // Neither the cache nor the current kind can answer "was there a profile?" — only the store
        // query can.
        let spy = ProfileRemovalSpy()
        var config = deepSeekConfig()
        config.providerKind = .demo
        let registry = makeRegistry(spy: spy, existingProfiles: [config.id])

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
    }

    @Test
    func evictLeavesProfilesThatNeverExisted() async {
        let spy = ProfileRemovalSpy()
        // 网页会话型 provider：有 descriptor，但这台机器上从来没有它的 profile。
        // 这正是「新加一个 provider 再删掉」的路径 —— 无条件去删一个不存在的 store，
        // 会让 WebKit 在 removeDataStoreWithIdentifierImpl 里 SIGSEGV。
        let config = deepSeekConfig()
        let registry = makeRegistry(spy: spy)

        await registry.evict(config: config)

        #expect(spy.removed.isEmpty, "没有 profile 就不该去删，否则 WebKit 会崩")
    }

    @Test
    func evictLeavesProfilesThatNeverExistedForProvidersWithoutADescriptor() async {
        let spy = ProfileRemovalSpy()
        let config = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)
        let registry = makeRegistry(spy: spy)

        await registry.evict(config: config)

        #expect(spy.removed.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func removePersistentProfileCompletesForAnUnknownIdentifier() async {
        // Exercises the one path that calls the SDK removal API; a completion handler that never
        // fires would suspend this forever.
        await WebSessionRegistry.removePersistentProfile(UUID())
        #expect(Bool(true))
    }

    @Test(.timeLimit(.minutes(1)))
    func queriesTheRealStoreForAnIdentifierWithNoProfile() async {
        // Exercises the real SDK query rather than the injected stub: an identifier this app has
        // never written must report false, and the call must return promptly.
        #expect(await WebSessionRegistry.hasPersistentProfile(UUID()) == false)
    }
}
