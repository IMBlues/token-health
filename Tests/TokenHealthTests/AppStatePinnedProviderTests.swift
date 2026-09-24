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
    func pinningIsExclusiveAndPersists() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let first = state.addConfig(providerKind: .kimiCode)
        let second = state.addConfig(providerKind: .zhipuCode)

        state.setPinnedConfigID(first)
        #expect(state.pinnedConfigID == first)

        state.setPinnedConfigID(second)
        #expect(state.pinnedConfigID == second)
        #expect(ConfigStore(defaults: defaults).loadPinnedConfigID() == second)
    }

    @Test
    func unpinningClearsTheStoredValue() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let id = state.addConfig(providerKind: .kimiCode)

        state.setPinnedConfigID(id)
        state.setPinnedConfigID(nil)

        #expect(state.pinnedConfigID == nil)
        #expect(ConfigStore(defaults: defaults).loadPinnedConfigID() == nil)
    }

    @Test
    func deletingThePinnedConfigClearsThePin() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let pinned = state.addConfig(providerKind: .kimiCode)
        let other = state.addConfig(providerKind: .zhipuCode)

        state.setPinnedConfigID(pinned)
        #expect(state.deleteConfig(id: pinned))

        #expect(state.pinnedConfigID == nil)
        #expect(state.pinnedConfigID != other)
    }

    @Test
    func deletingAnotherConfigKeepsThePin() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let pinned = state.addConfig(providerKind: .kimiCode)
        let other = state.addConfig(providerKind: .zhipuCode)

        state.setPinnedConfigID(pinned)
        #expect(state.deleteConfig(id: other))

        #expect(state.pinnedConfigID == pinned)
    }

    @Test
    func pinnedSnapshotIsReachableByID() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.setPinnedConfigID(id)

        #expect(state.pinnedConfig?.id == id)
        #expect(state.pinnedSnapshot == nil)

        state.snapshots[id] = ProviderUsageSnapshot(
            id: id,
            serviceName: "Kimi",
            providerTitle: "Kimi Code",
            usages: [TokenUsage(window: .fiveHours, used: 1, limit: 10)],
            state: .ready,
            statusMessage: "ok",
            updatedAt: Date()
        )

        #expect(state.pinnedSnapshot?.usages.count == 1)
    }

    @Test
    func pinnedConfigIsNilWhenThePinPointsNowhere() {
        let state = makeState(defaults: makeDefaults())
        state.setPinnedConfigID(UUID())

        #expect(state.pinnedConfig == nil)
        #expect(state.pinnedSnapshot == nil)
    }

    @Test
    func aStoredPinPointingAtADeletedAccountIsDroppedOnLaunch() {
        let defaults = makeDefaults()
        let store = ConfigStore(defaults: defaults)
        store.savePinnedConfigID(UUID())

        let state = makeState(defaults: defaults)

        #expect(state.pinnedConfigID == nil)
        #expect(store.loadPinnedConfigID() == nil)
    }

    @Test
    func theExchangeRateStartsFromTheCachedValue() {
        let defaults = makeDefaults()
        ConfigStore(defaults: defaults).saveExchangeRate(
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
