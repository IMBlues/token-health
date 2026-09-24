import SwiftUI

struct SettingsView: View {
    private static let reportingSelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let generalSelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @EnvironmentObject private var appState: AppState
    @State private var selectedID: UUID?
    @State private var apiKey = ""
    @State private var password = ""
    @State private var reportBearerToken = ""
    @State private var refreshIntervalText = ""
    @State private var loadedSecretID: UUID?
    @State private var storedAccountLabel: String?
    @State private var isWebLoginInProgress = false
    @State private var apiKeyStoredValue = false
    @State private var reportTokenStoredValue = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(appState.configs) { config in
                        // 单行。provider 类型不再占第二行 —— 详情面板里的 Provider 字段已经有了。
                        // 行尾也刻意不放拖拽把手：macOS 的可重排列表不画那个符号，直接拖行本身就重排。
                        HStack(spacing: 10) {
                            Image(nsImage: ProviderIcon.image(for: config.providerKind, size: 16, tint: .labelColor))
                                .frame(width: 18)
                            Text(config.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .tag(config.id)
                    }
                    .onMove { source, destination in
                        appState.moveConfigs(fromOffsets: source, toOffset: destination)
                    }

                    Section("General") {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .frame(width: 18)
                            Text("Refresh")
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .tag(Self.generalSelectionID)
                    }

                    Section("Integrations") {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.forward.app")
                                .frame(width: 18)
                            Text("Usage reporting")
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .tag(Self.reportingSelectionID)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .toolbar {
                // 增删放工具栏，底部那条按钮条整条去掉 —— 与现在的系统设置一致。
                ToolbarItemGroup(placement: .navigation) {
                    Menu {
                        ForEach(ProviderKind.allCases) { kind in
                            Button(kind.title) {
                                addConfig(kind)
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add a provider")

                    Button {
                        removeSelectedConfig()
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(!canRemoveSelection)
                    .help("Remove the selected provider")
                }
            }
        } detail: {
            detail
        }
        .onAppear {
            if selectedID == nil {
                selectedID = appState.settingsSelectedID ?? appState.configs.first?.id
            }
            loadSecretsIfNeeded(force: true)
        }
        .onChange(of: selectedID) {
            if selectedID != Self.reportingSelectionID {
                appState.settingsSelectedID = selectedID
            }
            loadSecretsIfNeeded(force: true)
        }
        .onChange(of: appState.settingsSelectedID) {
            if selectedID != appState.settingsSelectedID {
                selectedID = appState.settingsSelectedID
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selectedID == Self.reportingSelectionID {
            reportHookDetail
        } else if selectedID == Self.generalSelectionID {
            generalDetail
        } else if let binding = selectedConfigBinding {
            Form {
                Section {
                    TextField("Name", text: binding.displayName)

                    Picker("Provider", selection: binding.providerKind) {
                        ForEach(ProviderKind.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    if !binding.wrappedValue.providerKind.usesWebSession && !binding.wrappedValue.providerKind.usesLocalLogin {
                        Picker("Auth", selection: binding.authMode) {
                            ForEach(AuthMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }

                    Toggle("Enabled", isOn: binding.isEnabled)
                }

                Section("Menu Bar") {
                    Toggle("Pin to menu bar", isOn: pinBinding(for: binding))

                    if binding.wrappedValue.providerKind == .deepSeek {
                        Picker("Display currency", selection: binding.displayCurrency) {
                            Text("Original").tag(String?.none)
                            Text("CNY").tag(String?.some("CNY"))
                            Text("USD").tag(String?.some("USD"))
                        }

                        LabeledContent("Exchange rate") {
                            HStack(spacing: 6) {
                                Text(exchangeRateSummary)
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task {
                                        await appState.refreshExchangeRate(force: true)
                                    }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Refresh exchange rate")
                            }
                        }
                    }

                    Text("Each pinned account gets its own menu bar item: the provider logo, then one thin bar per quota window. Items follow the order of the account list above. The other icon keeps managing everything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if binding.wrappedValue.providerKind.usesLocalLogin {
                        LabeledContent("Source", value: localLoginSource(for: binding.wrappedValue.providerKind))
                        LabeledContent("Access", value: localLoginAccess(for: binding.wrappedValue.providerKind))
                        LabeledContent("Status", value: localLoginStatusText(for: binding.wrappedValue))
                    } else if usesManagedWebLogin(binding.wrappedValue) {
                        Text(webSessionStatusText(for: binding.wrappedValue))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            startWebLogin(for: binding.wrappedValue.providerKind)
                        } label: {
                            Label(
                                isWebLoginInProgress ? "Waiting for login" : "Login with \(binding.wrappedValue.providerKind.title)",
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                        .disabled(isWebLoginInProgress)
                    } else {
                        if !binding.wrappedValue.providerKind.usesSingleAPIKeyOnly {
                            TextField("API endpoint", text: binding.apiEndpoint)
                        }
                        SecureField(apiKeyStoredValue ? "API key stored" : "API key", text: $apiKey)
                        if apiKeyStoredValue {
                            HStack {
                                LabeledContent("API key", value: "••••••••")
                                Button {
                                    clearAPIKey()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Clear API key")
                            }
                        }
                    }
                }

                if !usesManagedWebLogin(binding.wrappedValue),
                   !binding.wrappedValue.providerKind.usesLocalLogin,
                   binding.wrappedValue.providerKind != .deepSeek,
                   !binding.wrappedValue.providerKind.usesSingleAPIKeyOnly {
                    Section {
                        TextField("Local usage JSON or folder", text: binding.usageDataPath)
                    }

                    Section {
                        TextField("Username", text: binding.username)
                        SecureField("Password", text: $password)
                    }
                }

                if let error = appState.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                // 这里原来是 Save 与 Refresh 两个按钮 —— 它们做的事一模一样（保存密钥 + 保存配置 +
                // 刷新全部），只是其中一个带回车快捷键。合并成一个。
                Button("Save & Refresh") {
                    saveCurrentSecrets()
                    appState.saveConfigs()
                    Task {
                        await appState.refreshAll()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .formStyle(.grouped)
            .padding()
            .onChange(of: binding.wrappedValue.providerKind) {
                loadSecretsIfNeeded(force: true)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("No plan selected")
                    .foregroundStyle(.secondary)
                Button("Add Plan") {
                    selectedID = appState.addConfig()
                    loadSecretsIfNeeded(force: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var generalDetail: some View {
        Form {
            Section {
                LabeledContent("Auto-refresh interval") {
                    HStack(spacing: 6) {
                        TextField("", text: $refreshIntervalText, prompt: Text("Seconds"))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            .accessibilityLabel("Auto-refresh interval in seconds")
                            .onSubmit(applyRefreshIntervalText)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                        Stepper(
                            "",
                            value: refreshIntervalSecondsBinding,
                            in: Int(AppState.minimumRefreshInterval)...max(refreshIntervalSecondsBinding.wrappedValue, 86_400),
                            step: 30
                        )
                        .labelsHidden()
                    }
                }
                Text("Minimum \(Int(AppState.minimumRefreshInterval)) seconds. Press Return to apply a typed value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshIntervalText = refreshIntervalDisplayText }
        .onChange(of: appState.refreshInterval) { refreshIntervalText = refreshIntervalDisplayText }
    }

    private var refreshIntervalDisplayText: String {
        String(Int(appState.refreshInterval.rounded()))
    }

    private var refreshIntervalSecondsBinding: Binding<Int> {
        Binding {
            Int(appState.refreshInterval.rounded())
        } set: { seconds in
            appState.setRefreshInterval(TimeInterval(seconds))
        }
    }

    private func applyRefreshIntervalText() {
        guard let seconds = Double(refreshIntervalText.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite else {
            refreshIntervalText = refreshIntervalDisplayText
            return
        }
        appState.setRefreshInterval(seconds)
        refreshIntervalText = refreshIntervalDisplayText
    }

    private var reportHookDetail: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $appState.reportHookConfig.isEnabled)
            }

            Section("Providers") {
                if appState.configs.isEmpty {
                    Text("No providers configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.configs) { config in
                        Toggle(isOn: reportProviderSelectionBinding(for: config)) {
                            HStack(spacing: 10) {
                                Image(nsImage: ProviderIcon.image(for: config.providerKind, size: 16, tint: .labelColor))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(config.displayName)
                                        .lineLimit(1)
                                    Text(config.providerKind.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if !config.isEnabled {
                                    Text("Disabled")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 58, alignment: .trailing)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(
                            !config.isEnabled &&
                            !appState.reportHookConfig.providerConfigIDs.contains(config.id)
                        )
                        .frame(minHeight: 36)
                    }
                }
            }

            Section {
                TextField("Endpoint", text: $appState.reportHookConfig.endpoint)
                TextField("Client ID", text: $appState.reportHookConfig.clientID)
                TextField(
                    "Pinned certificate SHA-256 (optional)",
                    text: $appState.reportHookConfig.pinnedCertificateSHA256
                )
                .font(.system(.body, design: .monospaced))
            }

            Section {
                SecureField(reportTokenStoredValue ? "Bearer token stored" : "Bearer token", text: $reportBearerToken)

                if reportTokenStoredValue {
                    HStack {
                        LabeledContent("Authorization", value: "Stored in Keychain")
                        Button {
                            if appState.saveReportHookConfig(bearerToken: "") {
                                reportBearerToken = ""
                                reportTokenStoredValue = false
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear bearer token")
                    }
                }
            }

            if let message = appState.lastReportMessage {
                Section {
                    LabeledContent("Last report") {
                        HStack(spacing: 6) {
                            Image(systemName: appState.lastReportSucceeded == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(appState.lastReportSucceeded == true ? .green : .orange)
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let error = appState.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Save") {
                    saveReportHookSettings()
                }
                .keyboardShortcut(.defaultAction)

                Button {
                    saveReportHookSettings()
                    Task {
                        await appState.reportUsage()
                    }
                } label: {
                    Label(appState.isReporting ? "Reporting" : "Report now", systemImage: "paperplane")
                }
                .disabled(
                    appState.isReporting ||
                    !appState.reportHookConfig.isEnabled ||
                    selectedEnabledReportProviders.isEmpty ||
                    appState.reportHookConfig.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    appState.reportHookConfig.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var selectedConfigBinding: Binding<ServiceConfig>? {
        guard let selectedID, let index = appState.configs.firstIndex(where: { $0.id == selectedID }) else {
            return nil
        }
        return $appState.configs[index]
    }

    /// 加号菜单里列**全部** provider。以前只有登录型的能加，Cursor / Codex / OpenAI 这些
    /// 得先「New plan」再进详情页改 Provider —— 那正是「配置 UI 别扭」的来源之一。
    private func addConfig(_ kind: ProviderKind) {
        selectedID = appState.addConfig(providerKind: kind)
        loadSecretsIfNeeded(force: true)
    }

    private var canRemoveSelection: Bool {
        guard let selectedID else {
            return false
        }
        return appState.configs.contains { $0.id == selectedID }
    }

    private func removeSelectedConfig() {
        guard let selectedID, canRemoveSelection else {
            return
        }
        if appState.deleteConfig(id: selectedID) {
            self.selectedID = appState.configs.first?.id ?? Self.reportingSelectionID
            loadSecretsIfNeeded(force: true)
        }
    }

    private var selectedEnabledReportProviders: [ServiceConfig] {
        let selectedIDs = Set(appState.reportHookConfig.providerConfigIDs)
        return appState.configs.filter { $0.isEnabled && selectedIDs.contains($0.id) }
    }

    private func reportProviderSelectionBinding(for config: ServiceConfig) -> Binding<Bool> {
        Binding {
            appState.reportHookConfig.providerConfigIDs.contains(config.id)
        } set: { isSelected in
            var selectedIDs = Set(appState.reportHookConfig.providerConfigIDs)
            if isSelected {
                selectedIDs.insert(config.id)
            } else {
                selectedIDs.remove(config.id)
            }
            appState.reportHookConfig.providerConfigIDs = appState.configs.compactMap { candidate in
                selectedIDs.contains(candidate.id) ? candidate.id : nil
            }
        }
    }

    private func pinBinding(for binding: Binding<ServiceConfig>) -> Binding<Bool> {
        Binding {
            appState.isPinned(binding.wrappedValue.id)
        } set: { isPinned in
            appState.setPinned(binding.wrappedValue.id, isPinned)
        }
    }

    private var exchangeRateSummary: String {
        let table = appState.exchangeRate
        guard let rate = table.rate(from: "USD", to: "CNY") else {
            return "Unavailable"
        }
        let value = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), rate)
        switch table.origin {
        case .live:
            return "USD → CNY \(value) · live · \(StatusMenuSummary.relativeAge(from: table.fetchedAt, now: Date()))"
        case .cache:
            return "USD → CNY \(value) · cached · \(StatusMenuSummary.relativeAge(from: table.fetchedAt, now: Date()))"
        case .fallback:
            return "USD → CNY \(value) · built-in default, never fetched"
        }
    }

    private func loadSecretsIfNeeded(force: Bool = false) {
        guard let selectedID else {
            apiKey = ""
            password = ""
            loadedSecretID = nil
            storedAccountLabel = nil
            return
        }
        if selectedID == Self.generalSelectionID {
            apiKey = ""
            password = ""
            apiKeyStoredValue = false
            storedAccountLabel = nil
            loadedSecretID = selectedID
            return
        }
        if selectedID == Self.reportingSelectionID {
            apiKey = ""
            password = ""
            apiKeyStoredValue = false
            storedAccountLabel = nil
            reportBearerToken = ""
            reportTokenStoredValue = !appState.loadReportHookToken().isEmpty
            loadedSecretID = selectedID
            return
        }
        guard force || selectedID != loadedSecretID else {
            return
        }
        if appState.configs.first(where: { $0.id == selectedID })?.providerKind.usesLocalLogin == true {
            apiKey = ""
            password = ""
            apiKeyStoredValue = false
            storedAccountLabel = nil
            loadedSecretID = selectedID
            return
        }
        let secrets = appState.loadSecrets(for: selectedID)
        apiKey = ""
        password = secrets.password
        apiKeyStoredValue = !secrets.apiKey.isEmpty
        storedAccountLabel = webSessionAccountLabel(for: selectedID, credential: secrets.apiKey)
        loadedSecretID = selectedID
    }

    private func webSessionAccountLabel(for configID: UUID, credential: String) -> String? {
        guard !credential.isEmpty,
              let kind = appState.configs.first(where: { $0.id == configID })?.providerKind,
              let descriptor = WebSessionDescriptorFactory().descriptor(for: kind) else {
            return nil
        }
        return descriptor.accountLabel(fromCredential: credential)
    }

    private func saveReportHookSettings() {
        let rawPin = appState.reportHookConfig.pinnedCertificateSHA256
        if let normalizedPin = TLSCertificatePin.normalizedSHA256(rawPin) {
            appState.reportHookConfig.pinnedCertificateSHA256 = normalizedPin
        }
        if reportBearerToken.isEmpty {
            appState.saveReportHookConfig()
        } else {
            if appState.saveReportHookConfig(bearerToken: reportBearerToken) {
                reportTokenStoredValue = true
                reportBearerToken = ""
            }
        }
    }

    private func saveCurrentSecrets() {
        guard let selectedID else {
            return
        }
        if appState.configs.first(where: { $0.id == selectedID })?.providerKind.usesLocalLogin == true {
            appState.saveSecrets(.empty, for: selectedID)
            apiKey = ""
            password = ""
            apiKeyStoredValue = false
            loadedSecretID = selectedID
            return
        }
        let existingSecrets = appState.loadSecrets(for: selectedID)
        let nextAPIKey = apiKey.isEmpty ? existingSecrets.apiKey : apiKey
        guard appState.saveSecrets(
            ProviderSecrets(apiKey: nextAPIKey, password: password),
            for: selectedID
        ) else {
            apiKeyStoredValue = false
            return
        }
        apiKey = ""
        apiKeyStoredValue = !nextAPIKey.isEmpty
        loadedSecretID = selectedID
        // The picker does not reload secrets, so refresh the label here: a config switched to API
        // mode and saved would otherwise still claim the old web-session account.
        storedAccountLabel = webSessionAccountLabel(for: selectedID, credential: nextAPIKey)
    }

    private func clearAPIKey() {
        guard let selectedID else {
            return
        }
        let existing = appState.loadSecrets(for: selectedID)
        if appState.saveSecrets(ProviderSecrets(apiKey: "", password: existing.password), for: selectedID) {
            apiKey = ""
            apiKeyStoredValue = false
            loadedSecretID = selectedID
        }
    }

    private func startWebLogin(for provider: ProviderKind) {
        guard let selectedID else {
            return
        }

        isWebLoginInProgress = true
        let completion: (Result<String, Error>) -> Void = { result in
            isWebLoginInProgress = false

            switch result {
            case let .success(credential):
                guard appState.saveSecrets(
                    ProviderSecrets(apiKey: credential, password: password),
                    for: selectedID
                ) else {
                    apiKey = credential
                    apiKeyStoredValue = false
                    return
                }
                apiKey = ""
                apiKeyStoredValue = true
                if let index = appState.configs.firstIndex(where: { $0.id == selectedID }) {
                    if appState.configs[index].providerKind.usesWebSession {
                        appState.configs[index].authMode = .api
                    }
                    appState.configs[index].apiEndpoint = ""
                    appState.saveConfigs()
                }
                loadSecretsIfNeeded(force: true)
                Task {
                    await appState.refreshAll()
                }
            case let .failure(error):
                appState.lastError = error.localizedDescription
            }
        }

        switch provider {
        case .kimiCode, .deepSeek, .zhipuCode, .miniMax, .volcengineArk, .openCodeGo:
            guard let config = appState.configs.first(where: { $0.id == selectedID }),
                  let controller = WebSessionRegistry.shared.controller(for: config) else {
                isWebLoginInProgress = false
                appState.lastError = "This session is being removed. Try again in a moment."
                return
            }
            controller.startLogin(completion: completion)
        case .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            isWebLoginInProgress = false
        }
    }

    private func webSessionStatusText(for config: ServiceConfig) -> String {
        let title = config.providerKind.title
        guard apiKeyStoredValue else {
            return "\(title) web session not connected"
        }
        guard loadedSecretID == config.id, let storedAccountLabel else {
            return "\(title) web session stored locally"
        }
        return "\(title) web session connected: \(storedAccountLabel)"
    }

    private func usesManagedWebLogin(_ config: ServiceConfig) -> Bool {
        config.providerKind.usesWebSession || (config.providerKind.supportsWebLogin && config.authMode == .browserLogin)
    }

    private func localLoginStatusText(for config: ServiceConfig) -> String {
        if appState.isRefreshing {
            return "Refreshing"
        }
        guard let snapshot = appState.snapshots[config.id],
              snapshot.providerTitle == config.providerKind.title else {
            return "Waiting for refresh"
        }
        return snapshot.statusMessage
    }

    private func localLoginSource(for provider: ProviderKind) -> String {
        switch provider {
        case .cursor:
            "Official Cursor app"
        case .codex:
            "Official Codex app"
        case .openAI, .anthropic, .kimiCode, .zhipuCode, .deepSeek, .miniMax, .volcengineArk, .openCodeGo, .genericHTTP, .demo:
            provider.title
        }
    }

    private func localLoginAccess(for provider: ProviderKind) -> String {
        provider == .cursor ? "Monthly quota" : "Quota only"
    }
}
