import Foundation
import Testing
@testable import TokenHealth

private struct StubFetcher: ExchangeRateFetching {
    var result: Result<ExchangeRateTable, Error>

    func fetchTable() async throws -> ExchangeRateTable {
        try result.get()
    }
}

private struct StubError: Error {}

@MainActor
struct ExchangeRateStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "exchange-rate-tests-\(UUID().uuidString)")!
    }

    private func liveTable(rate: Double, at date: Date) -> ExchangeRateTable {
        ExchangeRateTable(base: "USD", rates: ["CNY": rate], fetchedAt: date, origin: .live)
    }

    @Test
    func startsFromTheFallbackWhenNothingIsCached() {
        let store = ExchangeRateStore(
            configStore: ConfigStore(defaults: makeDefaults()),
            fetcher: StubFetcher(result: .failure(StubError()))
        )
        #expect(store.table.origin == .fallback)
    }

    @Test
    func aFreshFetchIsStoredAndPublished() async {
        let defaults = makeDefaults()
        let store = ExchangeRateStore(
            configStore: ConfigStore(defaults: defaults),
            fetcher: StubFetcher(result: .success(liveTable(rate: 6.5, at: Date())))
        )

        await store.refreshNow()

        #expect(store.table.origin == .live)
        #expect(store.table.rates["CNY"] == 6.5)
        #expect(ConfigStore(defaults: defaults).loadExchangeRate()?.rates["CNY"] == 6.5)
    }

    @Test
    func aFailedFetchKeepsTheCachedRate() async {
        let defaults = makeDefaults()
        let cache = ConfigStore(defaults: defaults)
        cache.saveExchangeRate(liveTable(rate: 6.4, at: Date().addingTimeInterval(-60)))

        let store = ExchangeRateStore(
            configStore: cache,
            fetcher: StubFetcher(result: .failure(StubError()))
        )
        await store.refreshNow()

        #expect(store.table.rates["CNY"] == 6.4)
        #expect(store.table.origin == .cache)
    }

    @Test
    func aFreshCacheIsNotRefetched() async {
        let defaults = makeDefaults()
        let cache = ConfigStore(defaults: defaults)
        cache.saveExchangeRate(liveTable(rate: 6.4, at: Date()))

        let store = ExchangeRateStore(
            configStore: cache,
            fetcher: StubFetcher(result: .success(liveTable(rate: 9.9, at: Date())))
        )
        await store.refreshIfStale()

        #expect(store.table.rates["CNY"] == 6.4, "a cache younger than the TTL must not be refetched")
    }

    @Test
    func aStaleCacheIsRefetched() async {
        let defaults = makeDefaults()
        let cache = ConfigStore(defaults: defaults)
        cache.saveExchangeRate(liveTable(rate: 6.4, at: Date().addingTimeInterval(-ExchangeRateStore.ttl - 60)))

        let store = ExchangeRateStore(
            configStore: cache,
            fetcher: StubFetcher(result: .success(liveTable(rate: 9.9, at: Date())))
        )
        await store.refreshIfStale()

        #expect(store.table.rates["CNY"] == 9.9)
        #expect(store.table.origin == .live)
    }

    @Test
    func aFallbackTableIsAlwaysConsideredStale() {
        let store = ExchangeRateStore(
            configStore: ConfigStore(defaults: makeDefaults()),
            fetcher: StubFetcher(result: .failure(StubError()))
        )
        #expect(store.isStale)
    }
}
