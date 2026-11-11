import Foundation
import Testing
@testable import TokenHealth

private struct ConfigPersistenceRateFetcher: ExchangeRateFetching {
    func fetchTable() async throws -> ExchangeRateTable { throw URLError(.notConnectedToInternet) }
}

@MainActor
struct AppStateConfigPersistenceTests {
    private func makeState(defaults: UserDefaults, secrets: InMemorySecretStore = InMemorySecretStore()) -> AppState {
        let store = ConfigStore(defaults: defaults, secretStore: secrets)
        return AppState(
            configStore: store,
            rateStore: ExchangeRateStore(configStore: store, fetcher: ConfigPersistenceRateFetcher())
        )
    }

    @Test
    func disablingAnAccountSurvivesRelaunchWithoutSaveAndRefresh() {
        let defaults = UserDefaults(suiteName: "config-persistence-tests-\(UUID().uuidString)")!
        let state = makeState(defaults: defaults)
        let id = state.addConfig(providerKind: .demo)

        state.configs[0].isEnabled = false

        let relaunched = makeState(defaults: defaults)
        #expect(relaunched.configs.first(where: { $0.id == id })?.isEnabled == false)
    }

    @Test
    func theLatestEditsReplaceTheLastExplicitlySavedSnapshot() {
        let defaults = UserDefaults(suiteName: "config-persistence-tests-\(UUID().uuidString)")!
        let state = makeState(defaults: defaults)
        _ = state.addConfig(providerKind: .demo)
        state.configs[0].isEnabled = false
        state.saveConfigs()

        state.configs[0].isEnabled = true
        state.configs[0].displayName = "Renamed account"
        state.configs[0].displayCurrency = "USD"

        let relaunched = makeState(defaults: defaults)
        #expect(relaunched.configs[0].isEnabled)
        #expect(relaunched.configs[0].displayName == "Renamed account")
        #expect(relaunched.configs[0].displayCurrency == "USD")
    }

    @Test
    func reportingEditsSurviveRelaunchWithoutPressingSave() {
        let defaults = UserDefaults(suiteName: "config-persistence-tests-\(UUID().uuidString)")!
        let state = makeState(defaults: defaults)
        let id = state.addConfig(providerKind: .demo)
        state.reportHookConfig.providerConfigIDs = [id]
        state.reportHookConfig.endpoint = "https://report.example.com/usage"
        state.reportHookConfig.isEnabled = true

        let relaunched = makeState(defaults: defaults)
        #expect(relaunched.reportHookConfig.isEnabled)
        #expect(relaunched.reportHookConfig.endpoint == "https://report.example.com/usage")
        #expect(relaunched.reportHookConfig.providerConfigIDs == [id])

        state.reportHookConfig.isEnabled = false
        #expect(makeState(defaults: defaults).reportHookConfig.isEnabled == false)
    }

    @Test
    func ordinaryEditsDoNotOverwriteStoredSecrets() throws {
        let defaults = UserDefaults(suiteName: "config-persistence-tests-\(UUID().uuidString)")!
        let secrets = InMemorySecretStore()
        let state = makeState(defaults: defaults, secrets: secrets)
        let id = state.addConfig(providerKind: .demo)
        let credential = ProviderSecrets(apiKey: "test-key", password: "test-password")
        try secrets.saveSecrets(credential, for: id)

        state.configs[0].isEnabled = false
        state.configs[0].displayName = "Disabled"

        #expect(secrets.loadSecrets(for: id) == credential)
        #expect(makeState(defaults: defaults).configs[0].displayName == "Disabled")
    }
}
