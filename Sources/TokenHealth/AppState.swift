import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let defaultRefreshInterval: TimeInterval = 60 * 15
    static let minimumRefreshInterval: TimeInterval = 30

    @Published var configs: [ServiceConfig]
    @Published var snapshots: [UUID: ProviderUsageSnapshot] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var settingsSelectedID: UUID?
    @Published var nextRefreshAt: Date
    @Published var refreshInterval: TimeInterval
    @Published var lastRefreshAt: Date?
    @Published var pinnedConfigIDs: [UUID]
    @Published private(set) var exchangeRate: ExchangeRateTable
    @Published var reportHookConfig: ReportHookConfig
    @Published var isReporting = false
    @Published var lastReportMessage: String?
    @Published var lastReportSucceeded: Bool?

    private let configStore: ConfigStore
    private let providerFactory = ProviderFactory()
    private let usageReporter: UsageReporter
    private let rateStore: ExchangeRateStore
    private var refreshTimer: Timer?

    init(
        configStore: ConfigStore = ConfigStore(),
        usageReporter: UsageReporter = UsageReporter(),
        rateStore: ExchangeRateStore? = nil
    ) {
        self.configStore = configStore
        self.usageReporter = usageReporter
        let resolvedRateStore = rateStore ?? ExchangeRateStore(configStore: configStore)
        self.rateStore = resolvedRateStore
        configs = configStore.loadConfigs()
        reportHookConfig = configStore.loadReportHookConfig()
        let interval = Self.normalizedRefreshInterval(configStore.loadRefreshInterval())
        refreshInterval = interval
        nextRefreshAt = Date().addingTimeInterval(interval)
        exchangeRate = resolvedRateStore.table
        pinnedConfigIDs = configStore.loadPinnedConfigIDs()
        normalizeReportProviderSelection()
        normalizePinnedConfigIDs()
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
        nextRefreshAt = date.addingTimeInterval(refreshInterval)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        let normalized = Self.normalizedRefreshInterval(interval)
        guard normalized != refreshInterval else {
            return
        }
        refreshInterval = normalized
        configStore.saveRefreshInterval(normalized)
        scheduleNextRefresh()
    }

    static func normalizedRefreshInterval(_ interval: TimeInterval?) -> TimeInterval {
        guard let interval, interval.isFinite, interval > 0 else {
            return defaultRefreshInterval
        }
        return max(interval.rounded(), minimumRefreshInterval)
    }

    func addConfig(providerKind: ProviderKind = .kimiCode) -> UUID {
        let config = ServiceConfig(
            displayName: uniqueDisplayName(for: providerKind),
            providerKind: providerKind,
            authMode: providerKind.defaultsToBrowserLogin ? .browserLogin : .api
        )
        configs.append(config)
        settingsSelectedID = config.id
        saveConfigs()
        return config.id
    }

    private func uniqueDisplayName(for kind: ProviderKind) -> String {
        let base = kind.title
        let existing = Set(configs.map(\.displayName))
        guard existing.contains(base) else {
            return base
        }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    @discardableResult
    func deleteConfig(id: UUID) -> Bool {
        guard let config = configs.first(where: { $0.id == id }) else {
            return false
        }
        do {
            try configStore.deleteConfig(config, from: &configs)
            snapshots[id] = nil
            if pinnedConfigIDs.contains(id) {
                setPinned(id, false)
            }
            normalizeReportProviderSelection()
            lastError = nil
            Task {
                // Let any in-flight refresh finish: evicting mid-fetch would leave that account's
                // WebView alive, and the store removal requires it to be released first.
                for _ in 0 ..< 300 where isRefreshing {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                await WebSessionRegistry.shared.evict(config: config)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 被钉住的账号，**按账号列表的顺序**给出 —— 菜单栏项就按这个顺序摆。
    var pinnedConfigs: [ServiceConfig] {
        configs.filter { pinnedConfigIDs.contains($0.id) }
    }

    func isPinned(_ id: UUID) -> Bool {
        pinnedConfigIDs.contains(id)
    }

    func setPinned(_ id: UUID, _ isPinned: Bool) {
        var ids = pinnedConfigIDs
        if isPinned {
            guard !ids.contains(id) else {
                return
            }
            ids.append(id)
        } else {
            guard ids.contains(id) else {
                return
            }
            ids.removeAll { $0 == id }
        }
        pinnedConfigIDs = ids
        configStore.savePinnedConfigIDs(ids)
    }

    /// 指向已不存在的账号时清掉，避免菜单栏项一直等一个不会来的配置。
    private func normalizePinnedConfigIDs() {
        let known = Set(configs.map(\.id))
        let surviving = pinnedConfigIDs.filter(known.contains)
        guard surviving != pinnedConfigIDs else {
            return
        }
        pinnedConfigIDs = surviving
        configStore.savePinnedConfigIDs(surviving)
    }

    func refreshExchangeRate(force: Bool = false) async {
        let updated = force ? await rateStore.refreshNow() : await rateStore.refreshIfStale()
        if updated != exchangeRate {
            exchangeRate = updated
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
        normalizeReportProviderSelection()
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

        let selectedIDs = Set(reportHookConfig.providerConfigIDs)
        guard !selectedIDs.isEmpty else {
            lastReportSucceeded = false
            lastReportMessage = "Select one or more providers to report"
            return
        }
        let selectedConfigs = configs.filter { selectedIDs.contains($0.id) }
        guard !selectedConfigs.isEmpty else {
            lastReportSucceeded = false
            lastReportMessage = "Selected providers no longer exist"
            return
        }
        let enabledConfigs = selectedConfigs.filter(\.isEnabled)
        guard !enabledConfigs.isEmpty else {
            lastReportSucceeded = false
            lastReportMessage = "Selected providers are disabled"
            return
        }
        let providers = enabledConfigs.compactMap { config -> (config: ServiceConfig, snapshot: ProviderUsageSnapshot)? in
            guard let snapshot = snapshots[config.id] else {
                return nil
            }
            return (config: config, snapshot: snapshot)
        }
        guard !providers.isEmpty else {
            lastReportSucceeded = false
            lastReportMessage = "No selected providers have usage snapshots yet"
            return
        }

        let payload = UsageReportBuilder().build(
            clientID: reportHookConfig.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            providers: providers
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
            let reportedLabel: String
            if let provider = providers.first, providers.count == 1 {
                reportedLabel = provider.config.displayName
            } else {
                reportedLabel = "\(providers.count) providers"
            }
            let skippedCount = selectedConfigs.count - providers.count
            let skippedLabel = skippedCount > 0 ? " · skipped \(skippedCount)" : ""
            lastReportMessage = "Reported \(reportedLabel)\(skippedLabel) · HTTP \(statusCode)"
        } catch {
            lastReportSucceeded = false
            lastReportMessage = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard !isRefreshing else {
            return
        }
        await performRefresh()
        // 汇率不是用量的一部分，放在 isRefreshing 复位之后再拉：否则设置界面会在整个
        // 汇率请求期间显示「Refreshing」，删除账号时的在途刷新等待也会被一并拖长。
        await refreshExchangeRate()
    }

    private func performRefresh() async {
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshAt = Date()
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

    private func normalizeReportProviderSelection() {
        let selectedIDs = Set(reportHookConfig.providerConfigIDs)
        let normalizedIDs = configs.compactMap { config in
            selectedIDs.contains(config.id) ? config.id : nil
        }
        guard normalizedIDs != reportHookConfig.providerConfigIDs else {
            return
        }
        reportHookConfig.providerConfigIDs = normalizedIDs
        configStore.saveReportHookConfig(reportHookConfig)
    }
}
