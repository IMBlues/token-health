import SwiftUI

struct SettingsView: View {
    private static let reportingSelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @EnvironmentObject private var appState: AppState
    @State private var selectedID: UUID?
    @State private var apiKey = ""
    @State private var password = ""
    @State private var reportBearerToken = ""
    @State private var loadedSecretID: UUID?
    @State private var isKimiLoginInProgress = false
    @State private var apiKeyStoredValue = false
    @State private var reportTokenStoredValue = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(appState.configs) { config in
                        HStack {
                            Image(systemName: iconName(for: config.providerKind))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.displayName)
                                    .lineLimit(1)
                                Text(config.providerKind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "line.3.horizontal")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .tag(config.id)
                    }
                    .onMove { source, destination in
                        appState.moveConfigs(fromOffsets: source, toOffset: destination)
                    }

                    Section("Integrations") {
                        HStack {
                            Image(systemName: "arrow.up.forward.app")
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Usage reporting")
                                Text("HTTPS hook")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .tag(Self.reportingSelectionID)
                    }
                }

                Divider()

                HStack {
                    Button {
                        selectedID = appState.addConfig()
                        loadSecretsIfNeeded(force: true)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add plan")

                    Button {
                        if let selectedID {
                            if appState.deleteConfig(id: selectedID) {
                                self.selectedID = appState.configs.first?.id ?? Self.reportingSelectionID
                                loadSecretsIfNeeded(force: true)
                            }
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedID == nil || selectedID == Self.reportingSelectionID)
                    .help("Remove plan")

                    Spacer()
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
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

                Section {
                    if binding.wrappedValue.providerKind.usesLocalLogin {
                        LabeledContent("Source", value: "Official Codex app")
                        LabeledContent("Access", value: "Quota only")
                        LabeledContent("Status", value: codexStatusText(for: binding.wrappedValue))
                    } else if usesManagedWebLogin(binding.wrappedValue) {
                        Text(apiKeyStoredValue ? "\(binding.wrappedValue.providerKind.title) web session stored locally" : "\(binding.wrappedValue.providerKind.title) web session not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            startWebLogin(for: binding.wrappedValue.providerKind)
                        } label: {
                            Label(
                                isKimiLoginInProgress ? "Waiting for login" : "Login with \(binding.wrappedValue.providerKind.title)",
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                        .disabled(isKimiLoginInProgress)
                    } else {
                        TextField("API endpoint", text: binding.apiEndpoint)
                        SecureField("API key", text: $apiKey)
                    }
                }

                if !usesManagedWebLogin(binding.wrappedValue),
                   !binding.wrappedValue.providerKind.usesLocalLogin,
                   binding.wrappedValue.providerKind != .deepSeek {
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

                HStack {
                    Button("Save") {
                        saveCurrentSecrets()
                        appState.saveConfigs()
                        Task {
                            await appState.refreshAll()
                        }
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Refresh") {
                        saveCurrentSecrets()
                        appState.saveConfigs()
                        Task {
                            await appState.refreshAll()
                        }
                    }
                }
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
                                Image(systemName: iconName(for: config.providerKind))
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

    private func loadSecretsIfNeeded(force: Bool = false) {
        guard let selectedID else {
            apiKey = ""
            password = ""
            loadedSecretID = nil
            return
        }
        if selectedID == Self.reportingSelectionID {
            apiKey = ""
            password = ""
            apiKeyStoredValue = false
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
            loadedSecretID = selectedID
            return
        }
        let secrets = appState.loadSecrets(for: selectedID)
        apiKey = ""
        password = secrets.password
        apiKeyStoredValue = !secrets.apiKey.isEmpty
        loadedSecretID = selectedID
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
    }

    private func startWebLogin(for provider: ProviderKind) {
        guard let selectedID else {
            return
        }

        isKimiLoginInProgress = true
        let completion: (Result<String, Error>) -> Void = { result in
            isKimiLoginInProgress = false

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
                Task {
                    await appState.refreshAll()
                }
            case let .failure(error):
                appState.lastError = error.localizedDescription
            }
        }

        switch provider {
        case .kimiCode:
            KimiWebLoginController.shared.startLogin(completion: completion)
        case .zhipuCode:
            ZhipuWebLoginController.shared.startLogin(completion: completion)
        case .deepSeek:
            DeepSeekWebLoginController.shared.startLogin(completion: completion)
        case .miniMax:
            MiniMaxWebLoginController.shared.startLogin(completion: completion)
        case .volcengineArk:
            VolcengineArkWebLoginController.shared.startLogin(completion: completion)
        case .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            isKimiLoginInProgress = false
        }
    }

    private func usesManagedWebLogin(_ config: ServiceConfig) -> Bool {
        config.providerKind.usesWebSession || (config.providerKind.supportsWebLogin && config.authMode == .browserLogin)
    }

    private func codexStatusText(for config: ServiceConfig) -> String {
        if appState.isRefreshing {
            return "Refreshing"
        }
        guard let snapshot = appState.snapshots[config.id], snapshot.providerTitle == ProviderKind.codex.title else {
            return "Waiting for refresh"
        }
        return snapshot.statusMessage
    }

    private func iconName(for provider: ProviderKind) -> String {
        switch provider {
        case .openAI:
            "sparkles"
        case .anthropic:
            "text.bubble"
        case .cursor:
            "cursorarrow"
        case .codex:
            "chevron.left.forwardslash.chevron.right"
        case .kimiCode:
            "moon.stars"
        case .zhipuCode:
            "brain.head.profile"
        case .deepSeek:
            "waveform.path.ecg"
        case .miniMax:
            "m.circle"
        case .volcengineArk:
            "flame"
        case .genericHTTP:
            "network"
        case .demo:
            "chart.bar"
        }
    }
}
