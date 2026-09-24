import Foundation
import Testing
@testable import TokenHealth

private struct DetailStubFetcher: ExchangeRateFetching {
    func fetchTable() async throws -> ExchangeRateTable { throw StubFailure() }
}

private struct StubFailure: Error {}

@MainActor
struct AppStateRefreshTests {
    private func makeState(defaults: UserDefaults) -> AppState {
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        return AppState(
            configStore: store,
            usageReporter: UsageReporter(),
            rateStore: ExchangeRateStore(configStore: store, fetcher: DetailStubFetcher())
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "app-state-refresh-tests-\(UUID().uuidString)")!
    }

    private func snapshot(_ id: UUID, serviceName: String, detail: UsageDetail?) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: id,
            serviceName: serviceName,
            providerTitle: "DeepSeek",
            usages: [
                TokenUsage(
                    window: .balance, label: "Balance CNY", used: 0, limit: nil,
                    resetDate: nil, unit: "CNY", displayValue: "1.00 CNY"
                )
            ],
            detail: detail,
            state: .ready,
            statusMessage: "ok",
            updatedAt: Date()
        )
    }

    private let sampleDetail = UsageDetail(
        headline: [DetailStat(label: "CNY", value: "1.00 CNY")],
        groups: [DetailGroup(title: "Today", values: [DetailStat(label: "Requests", value: "3")])]
    )

    // MARK: - 单账号刷新

    @Test
    func refreshingOneAccountLeavesTheOthersAlone() async {
        let state = makeState(defaults: makeDefaults())
        let pinned = state.addConfig(providerKind: .kimiCode)
        let other = state.addConfig(providerKind: .kimiCode)
        state.snapshots[pinned] = snapshot(pinned, serviceName: "Pinned", detail: nil)
        state.snapshots[other] = snapshot(other, serviceName: "Other", detail: nil)

        await state.refresh(configID: pinned)

        #expect(state.snapshots[other]?.serviceName == "Other", "别的账号的快照不该被动过")
    }

    @Test
    func refusesWhileAWholeRefreshIsRunning() async {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.snapshots[id] = snapshot(id, serviceName: "Kimi", detail: sampleDetail)
        state.isRefreshing = true

        await state.refresh(configID: id)

        #expect(state.snapshots[id]?.detail != nil, "整体刷新进行中时单账号刷新直接返回")
    }

    @Test
    func refusesForADisabledAccount() async {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.configs[0].isEnabled = false
        state.snapshots[id] = snapshot(id, serviceName: "Kimi", detail: sampleDetail)

        await state.refresh(configID: id)

        #expect(state.snapshots[id]?.detail != nil)
    }

    @Test
    func singleAccountRefreshDoesNotClaimTheWholeAppJustRefreshed() async {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)

        await state.refresh(configID: id)

        #expect(state.lastRefreshAt == nil, "面板表头那句讲的是整体刷新的新鲜度")
    }

    // MARK: - 失败时保留上次的详情

    /// 合并规则本身。直接走 `storeSnapshot` —— 它是快照的唯一写入路径。
    @Test
    func storeSnapshotKeepsTheLastGoodDetailWhenTheFetchFails() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        let previous = snapshot(id, serviceName: "Kimi", detail: sampleDetail)
        state.snapshots[id] = previous

        state.storeSnapshot(
            ProviderUsageSnapshot.unavailable(config: state.configs[0], message: "HTTP 503"),
            for: id
        )

        #expect(state.snapshots[id]?.state == .unavailable)
        #expect(
            state.snapshots[id]?.detail == sampleDetail,
            "失败要保留上次的数字，否则浮层会被清空、菜单栏项还会被打回旧菜单"
        )
        #expect(state.snapshots[id]?.statusMessage == "HTTP 503", "错误信息仍然要能显示出来")
        #expect(state.snapshots[id]?.updatedAt == previous.updatedAt, "保留旧时间戳，别谎报数据是刚刚取的")
    }

    @Test
    func storeSnapshotReplacesTheDetailOutrightWhenReady() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.snapshots[id] = snapshot(id, serviceName: "Kimi", detail: sampleDetail)

        state.storeSnapshot(snapshot(id, serviceName: "Kimi", detail: nil), for: id)

        #expect(state.snapshots[id]?.detail == nil, "成功取数时以新结果为准，不做合并")
    }

    @Test
    func storeSnapshotKeepsNothingOnTheFirstFailure() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)

        state.storeSnapshot(
            ProviderUsageSnapshot.unavailable(config: state.configs[0], message: "HTTP 503"),
            for: id
        )

        #expect(state.snapshots[id]?.detail == nil)
    }

    /// 端到端：单账号刷新走的确实是同一个合并路径。
    /// `.kimiCode` 配 `.api` 且凭据为空时，provider 直接返回 unavailable，不发任何请求。
    @Test
    func aFailedSingleAccountRefreshGoesThroughTheSameMerge() async {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        let previous = snapshot(id, serviceName: "Kimi", detail: sampleDetail)
        state.snapshots[id] = previous

        await state.refresh(configID: id)

        #expect(state.snapshots[id]?.state == .unavailable)
        #expect(state.snapshots[id]?.detail == sampleDetail, "单账号刷新也必须保住旧 detail")
        #expect(state.snapshots[id]?.updatedAt == previous.updatedAt)
    }
}
