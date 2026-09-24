import Foundation
import Testing
@testable import TokenHealth

private struct StubFetcher: ExchangeRateFetching {
    func fetchTable() async throws -> ExchangeRateTable {
        throw StubError()
    }
}

private struct StubError: Error {}

@MainActor
struct AppStatePinnedProviderTests {
    /// 汇率源与凭据存放处都要注入：兜底汇率永远是「过期」的，用真的 fetcher 会让每个用例都发一次
    /// 到 api.frankfurter.app 的请求；而真实的钥匙串在测试进程里会卡住（系统授权框）。
    private func makeState(defaults: UserDefaults) -> AppState {
        let configStore = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        return AppState(
            configStore: configStore,
            usageReporter: UsageReporter(),
            rateStore: ExchangeRateStore(configStore: configStore, fetcher: StubFetcher())
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "app-state-pin-tests-\(UUID().uuidString)")!
    }

    @Test
    func pinningSeveralAccountsKeepsThemApart() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let first = state.addConfig(providerKind: .kimiCode)
        let second = state.addConfig(providerKind: .zhipuCode)

        state.setPinned(first, true)
        #expect(state.isPinned(first))
        #expect(!state.isPinned(second))

        state.setPinned(second, true)
        #expect(state.isPinned(first), "pinning a second account must not evict the first")
        #expect(state.isPinned(second))
        #expect(ConfigStore(defaults: defaults, secretStore: InMemorySecretStore()).loadPinnedConfigIDs().count == 2)
    }

    @Test
    func pinnedConfigsFollowTheAccountListOrder() {
        let state = makeState(defaults: makeDefaults())
        let first = state.addConfig(providerKind: .kimiCode)
        let second = state.addConfig(providerKind: .zhipuCode)
        let third = state.addConfig(providerKind: .openCodeGo)

        // 倒着钉，顺序仍然按账号列表来。
        state.setPinned(third, true)
        state.setPinned(first, true)
        state.setPinned(second, true)

        #expect(state.pinnedConfigs.map(\.id) == [first, second, third])
    }

    @Test
    func unpinningRemovesOnlyThatAccount() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let first = state.addConfig(providerKind: .kimiCode)
        let second = state.addConfig(providerKind: .zhipuCode)

        state.setPinned(first, true)
        state.setPinned(second, true)
        state.setPinned(first, false)

        #expect(!state.isPinned(first))
        #expect(state.isPinned(second))
        #expect(state.pinnedConfigs.map(\.id) == [second])
        #expect(ConfigStore(defaults: defaults, secretStore: InMemorySecretStore()).loadPinnedConfigIDs() == [second])
    }

    @Test
    func pinningTwiceIsIdempotent() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)

        state.setPinned(id, true)
        state.setPinned(id, true)

        #expect(state.pinnedConfigIDs == [id])
    }

    @Test
    func deletingOnePinnedAccountLeavesTheOthers() {
        let state = makeState(defaults: makeDefaults())
        let first = state.addConfig(providerKind: .kimiCode)
        let second = state.addConfig(providerKind: .zhipuCode)
        let third = state.addConfig(providerKind: .openCodeGo)

        state.setPinned(first, true)
        state.setPinned(second, true)
        state.setPinned(third, true)
        #expect(state.deleteConfig(id: second))

        #expect(state.pinnedConfigIDs == [first, third])
        #expect(state.pinnedConfigs.map(\.id) == [first, third])
    }

    @Test
    func aStoredPinPointingAtADeletedAccountIsDroppedOnLaunch() {
        let defaults = makeDefaults()
        let first = makeState(defaults: defaults)
        let kept = first.addConfig(providerKind: .kimiCode)
        let gone = first.addConfig(providerKind: .zhipuCode)
        first.setPinned(kept, true)
        first.setPinned(gone, true)

        // 模拟另一个会话把第二个账号删了，只留下一个悬空的 pin。
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        store.saveConfigs(store.loadConfigs().filter { $0.id != gone })

        let relaunched = makeState(defaults: defaults)

        #expect(relaunched.pinnedConfigIDs == [kept])
        #expect(store.loadPinnedConfigIDs() == [kept])
    }

    @Test
    func pilingUpPinsSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = makeState(defaults: defaults)
        let ids = [
            first.addConfig(providerKind: .kimiCode),
            first.addConfig(providerKind: .zhipuCode)
        ]
        ids.forEach { first.setPinned($0, true) }

        let reloaded = makeState(defaults: defaults)

        #expect(reloaded.pinnedConfigIDs == ids)
        #expect(reloaded.pinnedConfigs.map(\.id) == ids)
    }

    @Test
    func aPinnedAccountExposesItsSnapshot() throws {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.setPinned(id, true)

        #expect(state.pinnedConfigs.map(\.id) == [id])
        #expect(state.snapshots[id] == nil, "还没有刷新过")

        state.snapshots[id] = ProviderUsageSnapshot(
            id: id,
            serviceName: "Kimi",
            providerTitle: "Kimi Code",
            usages: [TokenUsage(window: .fiveHours, used: 1, limit: 10)],
            state: .ready,
            statusMessage: "ok",
            updatedAt: Date()
        )

        let pinned = try #require(state.pinnedConfigs.first)
        #expect(state.snapshots[pinned.id]?.usages.count == 1)
    }

    @Test
    func theExchangeRateStartsFromTheCachedValue() {
        let defaults = makeDefaults()
        ConfigStore(defaults: defaults, secretStore: InMemorySecretStore()).saveExchangeRate(
            ExchangeRateTable(
                base: "USD",
                rates: ["CNY": 6.6],
                fetchedAt: Date(),
                origin: .live
            )
        )

        let state = makeState(defaults: defaults)

        #expect(state.exchangeRate.rates["CNY"] == 6.6)
        #expect(state.exchangeRate.origin == .live)
    }
}
