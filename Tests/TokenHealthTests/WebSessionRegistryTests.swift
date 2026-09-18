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
}
