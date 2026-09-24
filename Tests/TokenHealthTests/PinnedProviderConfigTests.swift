import Foundation
import Testing
@testable import TokenHealth

struct PinnedProviderConfigTests {
    private func makeStore() -> ConfigStore {
        let suite = UserDefaults(suiteName: "pinned-provider-tests-\(UUID().uuidString)")!
        return ConfigStore(defaults: suite)
    }

    @Test
    func pinnedConfigIDRoundTrips() {
        let store = makeStore()
        #expect(store.loadPinnedConfigID() == nil)

        let id = UUID()
        store.savePinnedConfigID(id)
        #expect(store.loadPinnedConfigID() == id)

        store.savePinnedConfigID(nil)
        #expect(store.loadPinnedConfigID() == nil)
    }

    @Test
    func exchangeRateRoundTrips() {
        let store = makeStore()
        #expect(store.loadExchangeRate() == nil)

        let table = ExchangeRateTable(
            base: "USD",
            rates: ["CNY": 6.9],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            origin: .live
        )
        store.saveExchangeRate(table)
        #expect(store.loadExchangeRate() == table)
    }

    @Test
    func decodesLegacyConfigsWithoutADisplayCurrency() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","displayName":"DeepSeek","providerKind":"deepSeek",
          "authMode":"api","isEnabled":true}]
        """
        let configs = try JSONDecoder().decode([ServiceConfig].self, from: Data(json.utf8))

        #expect(configs.count == 1)
        #expect(configs[0].displayCurrency == nil)
    }

    @Test
    func encodesAndDecodesADisplayCurrency() throws {
        var config = ServiceConfig(displayName: "DeepSeek", providerKind: .deepSeek, authMode: .api)
        config.displayCurrency = "CNY"

        let data = try JSONEncoder().encode([config])
        let decoded = try JSONDecoder().decode([ServiceConfig].self, from: data)

        #expect(decoded[0].displayCurrency == "CNY")
    }

    @Test
    func savingConfigsKeepsTheDisplayCurrency() {
        let defaults = UserDefaults(suiteName: "pinned-provider-tests-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults)
        var config = ServiceConfig(displayName: "DeepSeek", providerKind: .deepSeek, authMode: .api)
        config.displayCurrency = "USD"

        store.saveConfigs([config])

        #expect(store.loadConfigs().first?.displayCurrency == "USD")
    }
}
