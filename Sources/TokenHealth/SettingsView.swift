import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedID: UUID?
    @State private var apiKey = ""
    @State private var password = ""
    @State private var loadedSecretID: UUID?
    @State private var isKimiLoginInProgress = false
    @State private var apiKeyStoredValue = false

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
                            appState.deleteConfig(id: selectedID)
                            self.selectedID = appState.configs.first?.id
                            loadSecretsIfNeeded(force: true)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedID == nil)
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
            appState.settingsSelectedID = selectedID
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
        if let binding = selectedConfigBinding {
            Form {
                Section {
                    TextField("Name", text: binding.displayName)

                    Picker("Provider", selection: binding.providerKind) {
                        ForEach(ProviderKind.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    if !binding.wrappedValue.providerKind.usesWebSession {
                        Picker("Auth", selection: binding.authMode) {
                            ForEach(AuthMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }

                    Toggle("Enabled", isOn: binding.isEnabled)
                }

                Section {
                    if usesManagedWebLogin(binding.wrappedValue) {
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

                if !usesManagedWebLogin(binding.wrappedValue), binding.wrappedValue.providerKind != .deepSeek {
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

    private var selectedConfigBinding: Binding<ServiceConfig>? {
        guard let selectedID, let index = appState.configs.firstIndex(where: { $0.id == selectedID }) else {
            return nil
        }
        return $appState.configs[index]
    }

    private func loadSecretsIfNeeded(force: Bool = false) {
        guard let selectedID else {
            apiKey = ""
            password = ""
            loadedSecretID = nil
            return
        }
        guard force || selectedID != loadedSecretID else {
            return
        }
        let secrets = appState.loadSecrets(for: selectedID)
        apiKey = ""
        password = secrets.password
        apiKeyStoredValue = !secrets.apiKey.isEmpty
        loadedSecretID = selectedID
    }

    private func saveCurrentSecrets() {
        guard let selectedID else {
            return
        }
        let existingSecrets = appState.loadSecrets(for: selectedID)
        let nextAPIKey = apiKey.isEmpty ? existingSecrets.apiKey : apiKey
        appState.saveSecrets(ProviderSecrets(apiKey: nextAPIKey, password: password), for: selectedID)
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
                appState.saveSecrets(ProviderSecrets(apiKey: credential, password: password), for: selectedID)
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
        case .openAI, .anthropic, .cursor, .genericHTTP, .demo:
            isKimiLoginInProgress = false
        }
    }

    private func usesManagedWebLogin(_ config: ServiceConfig) -> Bool {
        config.providerKind.usesWebSession || (config.providerKind.supportsWebLogin && config.authMode == .browserLogin)
    }

    private func iconName(for provider: ProviderKind) -> String {
        switch provider {
        case .openAI:
            "sparkles"
        case .anthropic:
            "text.bubble"
        case .cursor:
            "cursorarrow"
        case .kimiCode:
            "moon.stars"
        case .zhipuCode:
            "brain.head.profile"
        case .deepSeek:
            "waveform.path.ecg"
        case .miniMax:
            "m.circle"
        case .genericHTTP:
            "network"
        case .demo:
            "chart.bar"
        }
    }
}
