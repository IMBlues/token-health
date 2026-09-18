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

    private func makeRegistry(spy: ProfileRemovalSpy) -> WebSessionRegistry {
        WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
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
        let spy = ProfileRemovalSpy()
        let registry = makeRegistry(spy: spy)
        let config = deepSeekConfig()

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
        let registry = makeRegistry(spy: spy)
        var config = deepSeekConfig()
        _ = registry.controller(for: config)

        config.providerKind = .demo
        _ = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func removePersistentProfileCompletesForAnUnknownIdentifier() async {
        // Exercises the one path that calls the SDK removal API; a completion handler that never
        // fires would suspend this forever.
        await WebSessionRegistry.removePersistentProfile(UUID())
        #expect(Bool(true))
    }
}
