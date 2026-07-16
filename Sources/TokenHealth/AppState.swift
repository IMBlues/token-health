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
    @Published var reportHookConfig: ReportHookConfig
    @Published var isReporting = false
    @Published var lastReportMessage: String?
    @Published var lastReportSucceeded: Bool?

    private let configStore: ConfigStore
    private let providerFactory = ProviderFactory()
    private let usageReporter: UsageReporter
    private var refreshTimer: Timer?

    init(configStore: ConfigStore = ConfigStore(), usageReporter: UsageReporter = UsageReporter()) {
        self.configStore = configStore
        self.usageReporter = usageReporter
        configs = configStore.loadConfigs()
        reportHookConfig = configStore.loadReportHookConfig()
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)
        if let selectedID = reportHookConfig.providerConfigID,
           !configs.contains(where: { $0.id == selectedID }) {
            reportHookConfig.providerConfigID = nil
            configStore.saveReportHookConfig(reportHookConfig)
        }
        do {
            try configStore.migrateLegacySecrets(for: configs)
        } catch {
            lastError = error.localizedDescription
        }

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
            if reportHookConfig.providerConfigID == id {
                reportHookConfig.providerConfigID = nil
                configStore.saveReportHookConfig(reportHookConfig)
            }
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

    @discardableResult
    func saveSecrets(_ secrets: ProviderSecrets, for id: UUID) -> Bool {
        do {
            try configStore.saveSecrets(secrets, for: id)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func loadReportHookToken() -> String {
        configStore.loadReportHookToken()
    }

    @discardableResult
    func saveReportHookConfig(bearerToken: String? = nil) -> Bool {
        configStore.saveReportHookConfig(reportHookConfig)
        guard let bearerToken else {
            return true
        }
        do {
            try configStore.saveReportHookToken(bearerToken)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func reportUsage() async {
        guard reportHookConfig.isEnabled, !isReporting else {
            return
        }

        guard let providerConfigID = reportHookConfig.providerConfigID else {
            lastReportSucceeded = false
            lastReportMessage = "Select a provider to report"
            return
        }
        guard let config = configs.first(where: { $0.id == providerConfigID }) else {
            lastReportSucceeded = false
            lastReportMessage = "Selected provider no longer exists"
            return
        }
        guard config.isEnabled else {
            lastReportSucceeded = false
            lastReportMessage = "Selected provider is disabled"
            return
        }
        guard let snapshot = snapshots[providerConfigID] else {
            lastReportSucceeded = false
            lastReportMessage = "No usage snapshot available for \(config.displayName)"
            return
        }

        let payload = UsageReportBuilder().build(
            clientID: reportHookConfig.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            config: config,
            snapshot: snapshot
        )
        guard !payload.accounts.isEmpty else {
            lastReportSucceeded = false
            lastReportMessage = "No usage snapshots available to report"
            return
        }

        isReporting = true
        defer { isReporting = false }
        do {
            let statusCode = try await usageReporter.report(
                config: reportHookConfig,
                bearerToken: configStore.loadReportHookToken(),
                payload: payload
            )
            lastReportSucceeded = true
            lastReportMessage = "Reported \(config.displayName) · HTTP \(statusCode)"
        } catch {
            lastReportSucceeded = false
            lastReportMessage = error.localizedDescription
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

        if reportHookConfig.isEnabled {
            await reportUsage()
        }
    }
}
