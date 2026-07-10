import Foundation
@testable import TokenHealth

enum CodexTestSupport {
    struct RPCSummary {
        let methods: [String]
        let keySets: [Set<String>]
        let initializeParamKeys: Set<String>
        let clientInfoKeys: Set<String>
        let clientName: String?
        let clientVersion: String?
        let wireText: String
    }

    struct ConfigMigrationResult {
        let loadedLegacy: Bool
        let preservedLegacy: Bool
        let loadedCurrent: Bool
        let usesLocalLogin: Bool
        let usesWebSession: Bool
    }

    static func rpcSummary(version: String) throws -> RPCSummary {
        let data = try CodexQuotaRPC.requestData(version: version)
        let messages = try data.split(separator: 0x0A).map { line -> [String: Any] in
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw CodexAppServerError.invalidResponse
            }
            return object
        }
        guard let wireText = String(data: data, encoding: .utf8) else {
            throw CodexAppServerError.invalidResponse
        }
        guard let initializeParams = messages[0]["params"] as? [String: Any],
              let clientInfo = initializeParams["clientInfo"] as? [String: Any] else {
            throw CodexAppServerError.invalidResponse
        }
        return RPCSummary(
            methods: messages.compactMap { $0["method"] as? String },
            keySets: messages.map { Set($0.keys) },
            initializeParamKeys: Set(initializeParams.keys),
            clientInfoKeys: Set(clientInfo.keys),
            clientName: clientInfo["name"] as? String,
            clientVersion: clientInfo["version"] as? String,
            wireText: wireText
        )
    }

    static func resetTimestamp(_ usage: TokenUsage) -> Int64? {
        usage.resetDate.map { Int64($0.timeIntervalSince1970) }
    }

    static func decodeRateLimits(_ json: String) throws -> CodexRateLimitsResponse {
        try JSONDecoder().decode(CodexRateLimitsResponse.self, from: Data(json.utf8))
    }

    static func rateLimitsDecodeFails(_ json: String) -> Bool {
        do {
            _ = try decodeRateLimits(json)
            return false
        } catch {
            return true
        }
    }

    static func fetchFromFakeAppServer() async throws -> CodexRateLimitsResponse {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        IFS= read -r _
        IFS= read -r _
        IFS= read -r _
        printf '%s\\n' '{"method":"remoteControl/status/changed","params":{}}'
        printf '%s\\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":21,"windowDurationMins":300,"resetsAt":1783665814},"secondary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1784252614},"planType":"plus"}}}'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        return try await CodexAppServerClient(testExecutableURL: executable, timeout: 3).fetchRateLimits()
    }

    static var liveCodexCheckEnabled: Bool {
        ProcessInfo.processInfo.environment["TOKEN_HEALTH_LIVE_CODEX"] == "1"
    }

    static func fetchLiveCodexQuota() async throws -> CodexRateLimitsResponse {
        try await CodexAppServerClient().fetchRateLimits()
    }

    static func configMigrationResult() throws -> ConfigMigrationResult {
        let suiteName = "TokenHealthTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CodexAppServerError.invalidResponse
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacy = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)
        let legacyData = try JSONEncoder().encode([legacy])
        defaults.set(legacyData, forKey: "service.configs.v1")
        defaults.set(Data("invalid".utf8), forKey: "service.configs.v2")

        let store = ConfigStore(defaults: defaults)
        let loadedLegacy = store.loadConfigs() == [legacy]

        let codex = ServiceConfig(displayName: "Codex", providerKind: .codex, authMode: .api)
        store.saveConfigs([legacy, codex])

        return ConfigMigrationResult(
            loadedLegacy: loadedLegacy,
            preservedLegacy: defaults.data(forKey: "service.configs.v1") == legacyData,
            loadedCurrent: store.loadConfigs() == [legacy, codex],
            usesLocalLogin: codex.providerKind.usesLocalLogin,
            usesWebSession: codex.providerKind.usesWebSession
        )
    }
}
