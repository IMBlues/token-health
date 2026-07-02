import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let refreshInterval: TimeInterval = 60 * 15

    @Published var configs: [ServiceConfig]
    @Published var snapshots: [UUID: ProviderUsageSnapshot] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var settingsSelectedID: UUID?
    @Published var nextRefreshAt: Date

    private let configStore: ConfigStore
    private let providerFactory = ProviderFactory()
    private var refreshTimer: Timer?

    init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore
        configs = configStore.loadConfigs()
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)

        scheduleNextRefresh()

        Task {
            await refreshAll()
        }
    }

    private func scheduleNextRefresh(from date: Date = Date()) {
        refreshTimer?.invalidate()
        nextRefreshAt = date.addingTimeInterval(Self.refreshInterval)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    func addConfig() -> UUID {
        let config = ServiceConfig(displayName: "Kimi Code", providerKind: .kimiCode, authMode: .api)
        configs.append(config)
        settingsSelectedID = config.id
        saveConfigs()
        return config.id
    }

    func deleteConfig(id: UUID) {
        guard let config = configs.first(where: { $0.id == id }) else {
            return
        }
        configStore.deleteConfig(config, from: &configs)
        snapshots[id] = nil
    }

    func saveConfigs() {
        for index in configs.indices where configs[index].providerKind.usesWebSession {
            configs[index].authMode = .api
            configs[index].apiEndpoint = ""
            configs[index].usageDataPath = ""
            configs[index].username = ""
        }
        for index in configs.indices where configs[index].providerKind == .deepSeek && configs[index].authMode == .browserLogin {
            configs[index].apiEndpoint = ""
            configs[index].usageDataPath = ""
            configs[index].username = ""
        }
        configStore.saveConfigs(configs)
    }

    func loadSecrets(for id: UUID) -> ProviderSecrets {
        configStore.loadSecrets(for: id)
    }

    func saveSecrets(_ secrets: ProviderSecrets, for id: UUID) {
        do {
            try configStore.saveSecrets(secrets, for: id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleNextRefresh()
        }

        for config in configs where config.isEnabled {
            let secrets = configStore.loadSecrets(for: config.id)
            let provider = providerFactory.provider(for: config)
            snapshots[config.id] = await provider.fetchUsage(config: config, secrets: secrets)
        }
    }
}
