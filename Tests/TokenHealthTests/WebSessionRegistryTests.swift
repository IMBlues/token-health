import Foundation
import Testing
import WebKit
@testable import TokenHealth

@Suite
@MainActor
struct WebSessionRegistryTests {
    private final class ProfileClearSpy {
        var cleared: [UUID] = []
    }

    private func makeRegistry(spy: ProfileClearSpy) -> WebSessionRegistry {
        WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            clearProfile: { id in spy.cleared.append(id) }
        )
    }

    private func deepSeekConfig() -> ServiceConfig {
        ServiceConfig(displayName: "DeepSeek", providerKind: .deepSeek, authMode: .browserLogin)
    }

    @Test
    func reusesControllerForSameConfig() {
        let registry = makeRegistry(spy: ProfileClearSpy())
        let config = deepSeekConfig()

        let first = registry.controller(for: config)
        let second = registry.controller(for: config)

        #expect(first != nil)
        #expect(first === second)
    }

    @Test
    func separatesControllersPerConfig() {
        let registry = makeRegistry(spy: ProfileClearSpy())
        let first = deepSeekConfig()
        let second = deepSeekConfig()

        let firstController = registry.controller(for: first)
        let secondController = registry.controller(for: second)
        #expect(firstController !== secondController)
    }

    @Test
    func returnsNilForProvidersWithoutDescriptor() {
        let registry = makeRegistry(spy: ProfileClearSpy())
        let config = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)

        #expect(registry.controller(for: config) == nil)
    }

    @Test
    func evictRemovesControllerAndClearsProfile() async {
        let spy = ProfileClearSpy()
        let registry = makeRegistry(spy: spy)
        let config = deepSeekConfig()
        let first = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(spy.cleared == [config.id])
        #expect(registry.controller(for: config) !== first)
    }

    /// 「添加一个 provider 再删掉，这次运行没建过 kernel」—— 崩在这里第一次。
    /// 以前这一支会去问 `allDataStoreIdentifiers`，那个调用本身就会 SIGSEGV。
    @Test
    func evictClearsTheProfileOfAConfigThatNeverBuiltAKernel() async {
        let spy = ProfileClearSpy()
        let registry = makeRegistry(spy: spy)
        let config = deepSeekConfig()

        await registry.evict(config: config)

        #expect(spy.cleared == [config.id])
    }

    /// 加完就删、还没登录过的账号走的就是这条：没有 kernel，也不该被跳过。
    @Test
    func evictClearsTheProfileOfAFreshlyAddedAccount() async {
        let spy = ProfileClearSpy()
        let registry = makeRegistry(spy: spy)
        var config = deepSeekConfig()
        _ = registry.controller(for: config)

        // 改掉 provider 类型，缓存里那个 kernel 会被丢掉 —— 但盘上的 profile 还在。
        config.providerKind = .demo
        _ = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(spy.cleared == [config.id])
    }

    @Test
    func evictClearsTheProfileForProvidersWithoutAWebSession() async {
        let spy = ProfileClearSpy()
        let registry = makeRegistry(spy: spy)
        // codex / cursor 这类没有网页会话的账号也走 evict：清一遍是安全的，
        // 而「先判断有没有 profile」反而要付出崩溃的代价。
        let config = ServiceConfig(displayName: "Codex", providerKind: .codex, authMode: .api)

        await registry.evict(config: config)

        #expect(spy.cleared == [config.id])
    }

    @Test
    func evictTearsTheKernelDownBeforeClearingTheProfile() async {
        let spy = ProfileClearSpy()
        var tornDownWhenProfileCleared: Bool?
        var controller: WebSessionController?
        let registry = WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            clearProfile: { id in
                // Read at the SDK call, not after evict returns: a post-hoc assertion would stay
                // green if evict were reordered to clear the profile first.
                tornDownWhenProfileCleared = controller?.isTornDown
                spy.cleared.append(id)
            }
        )
        let config = deepSeekConfig()
        controller = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(tornDownWhenProfileCleared == true)
        #expect(spy.cleared == [config.id])
    }

    @Test
    func refusesToBuildAKernelWhileAnEvictionIsInFlight() async {
        let config = deepSeekConfig()
        var rebuiltDuringEviction: WebSessionController?

        var registry: WebSessionRegistry!
        registry = WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            clearProfile: { _ in rebuiltDuringEviction = registry.controller(for: config) }
        )
        _ = registry.controller(for: config)

        await registry.evict(config: config)

        // The probe fires while `evict` is suspended mid-flight (kernel already torn down, profile
        // not yet cleared). Without the tombstone it would build a new kernel on the profile that
        // the same `evict` is about to clear.
        #expect(rebuiltDuringEviction == nil)
    }

    @Test
    func rebuildingAfterEvictionYieldsAFreshKernel() async {
        let registry = makeRegistry(spy: ProfileClearSpy())
        let config = deepSeekConfig()
        let first = registry.controller(for: config)

        await registry.evict(config: config)
        let second = registry.controller(for: config)

        #expect(second != nil)
        #expect(first !== second)
    }

    @Test
    func changingTheProviderKindReplacesTheCachedKernel() async {
        let registry = makeRegistry(spy: ProfileClearSpy())
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
}

/// `WKWebsiteDataStore.allDataStoreIdentifiers` 和 `WKWebsiteDataStore.remove(forIdentifier:)`
/// 在某些 macOS 上会让 WebKit 在 `WebsiteDataStoreIO` 队列里 SIGSEGV（`os_unfair_lock_lock`
/// 踩在地址 0x40 上，一个只调这一句的空 App 都能复现）。这两条已经删掉了，但单元测试挡不住
/// 有人再把它们加回来 —— swift-testing 进程不是真正的 App bundle，那两个调用在测试里永远是
/// 绿的，只有在真 App 里才崩。所以这里从源码层面钉死。
@Suite
struct WebKitDataStoreAPIGuardTests {
    private static let forbidden = [
        "allDataStoreIdentifiers",
        "remove(forIdentifier:",
    ]

    @Test
    func noSourceFileCallsTheCrashingDataStoreAPIs() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TokenHealthTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources")

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        var scanned = 0
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else {
                continue
            }
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                // 注释里点名这些 API 是有意的（解释为什么不能用），只查真正的代码。
                let code = rawLine.components(separatedBy: "//").first ?? rawLine
                for token in Self.forbidden where code.contains(token) {
                    let name = file.lastPathComponent
                    offenders.append("\(name):\(index + 1) 用了 \(token)")
                }
            }
        }

        #expect(scanned > 0, "没扫到任何源文件，路径算错了")
        #expect(
            offenders.isEmpty,
            "这些 API 会让 WebKit 段错误，改走 WebSessionRegistry.clearPersistentProfile：\(offenders)"
        )
    }
}
