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

        clearLocalLoginSecrets()
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

    @discardableResult
    func deleteConfig(id: UUID) -> Bool {
        guard let config = configs.first(where: { $0.id == id }) else {
            return false
        }
        do {
            try configStore.deleteConfig(config, from: &configs)
            snapshots[id] = nil
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func moveConfigs(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else {
            return
        }

        let movingConfigs = source.sorted().map { configs[$0] }
        for index in source.sorted(by: >) {
            configs.remove(at: index)
        }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = max(0, min(configs.count, destination - removedBeforeDestination))
        configs.insert(contentsOf: movingConfigs, at: insertionIndex)
        saveConfigs()
    }

    func saveConfigs() {
        for index in configs.indices where configs[index].providerKind.usesWebSession || configs[index].providerKind.usesLocalLogin {
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
        clearLocalLoginSecrets()
        configStore.saveConfigs(configs)
    }

    private func clearLocalLoginSecrets() {
        for config in configs where config.providerKind.usesLocalLogin {
            do {
                try configStore.saveSecrets(.empty, for: config.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
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
            let secrets = config.providerKind.usesLocalLogin ? ProviderSecrets.empty : configStore.loadSecrets(for: config.id)
            let provider = providerFactory.provider(for: config)
            snapshots[config.id] = await provider.fetchUsage(config: config, secrets: secrets)
        }
    }
}
