import Darwin
import Foundation
import Security

struct CodexUsageProvider: UsageProvider {
    private static let cache = CodexRateLimitsCache()
    private let client: CodexAppServerClient

    init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
    }

    func fetchUsage(config: ServiceConfig, secrets _: ProviderSecrets) async -> ProviderUsageSnapshot {
        do {
            let response: CodexRateLimitsResponse
            let fetchedAt: Date
            let cacheKey = client.cacheKey
            switch await Self.cache.lookup(key: cacheKey, maxAge: 60, minimumRequestInterval: 60) {
            case let .cached(cached):
                response = cached.value
                fetchedAt = cached.fetchedAt
            case let .failed(error):
                throw error
            case .fetch:
                do {
                    response = try await client.fetchRateLimits()
                    fetchedAt = Date()
                    await Self.cache.store(response, key: cacheKey, fetchedAt: fetchedAt)
                } catch let error as CodexAppServerError {
                    await Self.cache.storeFailure(error, key: cacheKey, failedAt: Date())
                    throw error
                } catch {
                    await Self.cache.clearRequest(key: cacheKey)
                    throw error
                }
            case .throttled:
                throw CodexAppServerError.refreshThrottled
            }

            let mapped = CodexRateLimitsMapper.map(response)
            guard !mapped.usages.isEmpty else {
                return snapshot(
                    config: config,
                    state: .unavailable,
                    message: "Codex did not return any quota windows"
                )
            }

            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: mapped.planName,
                usages: mapped.usages,
                state: .ready,
                statusMessage: mapped.statusMessage,
                updatedAt: fetchedAt
            )
        } catch let error as CodexAppServerError {
            let state: ProviderUsageSnapshot.State = switch error {
            case .executableNotFound, .requestRejected:
                .needsConfiguration
            case .invalidResponse, .launchFailed, .processExited, .refreshThrottled, .responseTooLarge, .timeout:
                .unavailable
            }
            return snapshot(config: config, state: state, message: error.localizedDescription)
        } catch {
            return snapshot(config: config, state: .unavailable, message: "Codex quota is unavailable")
        }
    }

    private func snapshot(
        config: ServiceConfig,
        state: ProviderUsageSnapshot.State,
        message: String
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: config.id,
            serviceName: config.displayName,
            providerTitle: config.providerKind.title,
            usages: [],
            state: state,
            statusMessage: message,
            updatedAt: Date()
        )
    }
}

struct CodexAppServerClient: Sendable {
    static let arguments = [
        "app-server",
        "--stdio",
        "--disable", "plugins",
        "--disable", "apps",
        "-c", "analytics.enabled=false"
    ]

    private let testExecutableURL: URL?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        testExecutableURL = nil
        self.timeout = timeout
    }

    #if DEBUG
    init(testExecutableURL: URL, timeout: TimeInterval = 30) {
        self.testExecutableURL = testExecutableURL
        self.timeout = timeout
    }
    #endif

    var cacheKey: String {
        let executablePath = (testExecutableURL ?? CodexExecutableResolver.resolve())?.path ?? "missing"
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return "\(executablePath)|\(codexHome)"
    }

    func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        guard let executableURL = testExecutableURL ?? CodexExecutableResolver.resolve() else {
            throw CodexAppServerError.executableNotFound
        }

        let requestData: Data
        do {
            requestData = try CodexQuotaRPC.requestData(version: Self.appVersion)
        } catch {
            throw CodexAppServerError.invalidResponse
        }

        let responseData = try await CodexAppServerSession.run(
            executableURL: executableURL,
            arguments: Self.arguments,
            requestData: requestData,
            responseID: CodexQuotaRPC.responseID,
            timeout: timeout
        )

        let response: CodexRPCQuotaResponse
        do {
            response = try JSONDecoder().decode(CodexRPCQuotaResponse.self, from: responseData)
        } catch {
            throw CodexAppServerError.invalidResponse
        }

        if response.error != nil {
            throw CodexAppServerError.requestRejected
        }
        guard response.id == CodexQuotaRPC.responseID, let result = response.result else {
            throw CodexAppServerError.invalidResponse
        }
        return result
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

enum CodexQuotaRPC {
    static let responseID = 1
    static let outboundMethods = ["initialize", "initialized", "account/rateLimits/read"]

    static func requestData(version: String) throws -> Data {
        let messages: [[String: Any]] = [
            [
                "method": outboundMethods[0],
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "token_health",
                        "version": version
                    ]
                ]
            ],
            ["method": outboundMethods[1]],
            ["method": outboundMethods[2], "id": responseID]
        ]

        var data = Data()
        for message in messages {
            data.append(try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }
}

enum CodexExecutableResolver {
    static func resolve(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        for candidate in candidates(homeDirectory: homeDirectory) {
            let standardized = candidate.standardizedFileURL
            let resolved = standardized.resolvingSymlinksInPath()
            guard standardized.path.hasPrefix("/"),
                  resolved.path.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: resolved.path),
                  CodexExecutableVerifier.isTrustedOpenAIExecutable(resolved) else {
                continue
            }
            return resolved
        }
        return nil
    }

    private static func candidates(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            homeDirectory.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")
        ]
    }
}

private enum CodexExecutableVerifier {
    private static let openAITeamIdentifier = "2DC432GLL2"
    private static let codexSigningIdentifier = "codex"
    private static let requirementText = """
    identifier "codex" and anchor apple generic and \
    certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
    certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
    certificate leaf[subject.OU] = "2DC432GLL2"
    """

    static func isTrustedOpenAIExecutable(_ url: URL) -> Bool {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(staticCode, validationFlags, requirement) == errSecSuccess else {
            return false
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
              let signingIdentifier = information[kSecCodeInfoIdentifier] as? String else {
            return false
        }
        return teamIdentifier == openAITeamIdentifier && signingIdentifier == codexSigningIdentifier
    }
}

enum CodexAppServerError: LocalizedError, Sendable {
    case executableNotFound
    case invalidResponse
    case launchFailed
    case processExited
    case refreshThrottled
    case requestRejected
    case responseTooLarge
    case timeout

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Install the official ChatGPT or Codex desktop app, then sign in to Codex"
        case .requestRejected:
            "Codex rejected the quota request; update Codex and confirm ChatGPT sign-in"
        case .timeout:
            "Codex quota request timed out"
        case .refreshThrottled:
            "Codex quota refresh is limited to once per minute"
        case .invalidResponse:
            "Codex returned an unsupported quota response"
        case .launchFailed, .processExited:
            "Codex quota reader could not start"
        case .responseTooLarge:
            "Codex quota response exceeded the safety limit"
        }
    }
}

private final class CodexAppServerSession: @unchecked Sendable {
    private static let maxLineBytes = 1_048_576
    private static let maxOutputBytes = 2_097_152

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let ioQueue = DispatchQueue(label: "local.token-health.codex-app-server")
    private let requestData: Data
    private let responseID: Int
    private let timeout: TimeInterval
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Data, Error>?
    private var outputBuffer = Data()
    private var outputBytes = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var isFinished = false

    private init(
        executableURL: URL,
        arguments: [String],
        requestData: Data,
        responseID: Int,
        timeout: TimeInterval,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.requestData = requestData
        self.responseID = responseID
        self.timeout = timeout
        self.continuation = continuation
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        requestData: Data,
        responseID: Int,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let session = CodexAppServerSession(
                executableURL: executableURL,
                arguments: arguments,
                requestData: requestData,
                responseID: responseID,
                timeout: timeout,
                continuation: continuation
            )
            session.start()
        }
    }

    private func start() {
        do {
            try process.run()
            ioQueue.async { [self] in
                readOutput()
            }
            try inputPipe.fileHandleForWriting.write(contentsOf: requestData)
        } catch {
            complete(.failure(CodexAppServerError.launchFailed))
            return
        }

        let workItem = DispatchWorkItem { [self] in
            complete(.failure(CodexAppServerError.timeout))
        }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !isFinished else {
                return false
            }
            timeoutWorkItem = workItem
            return true
        }
        if shouldSchedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: workItem)
        }
    }

    private func readOutput() {
        while !lock.withLock({ isFinished }) {
            let data = outputPipe.fileHandleForReading.availableData
            guard !data.isEmpty else {
                complete(.failure(CodexAppServerError.processExited))
                return
            }
            handleOutput(data)
        }
    }

    private func handleOutput(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        var lines: [Data] = []
        let exceededLimit = lock.withLock { () -> Bool in
            guard !isFinished else {
                return false
            }
            outputBytes += data.count
            outputBuffer.append(data)
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                lines.append(Data(outputBuffer[..<newline]))
                outputBuffer.removeSubrange(...newline)
            }
            return outputBytes > Self.maxOutputBytes
                || outputBuffer.count > Self.maxLineBytes
                || lines.contains { $0.count > Self.maxLineBytes }
        }

        if exceededLimit {
            complete(.failure(CodexAppServerError.responseTooLarge))
            return
        }

        for line in lines where !line.isEmpty {
            guard let envelope = try? JSONDecoder().decode(CodexRPCIDEnvelope.self, from: line),
                  envelope.id == responseID else {
                continue
            }
            complete(.success(line))
            return
        }
    }

    private func complete(_ result: Result<Data, Error>) {
        let pending: (CheckedContinuation<Data, Error>, DispatchWorkItem?)? = lock.withLock {
            guard !isFinished, let continuation else {
                return nil
            }
            isFinished = true
            self.continuation = nil
            let workItem = timeoutWorkItem
            timeoutWorkItem = nil
            return (continuation, workItem)
        }
        guard let (continuation, workItem) = pending else {
            return
        }

        workItem?.cancel()
        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForReading.closeFile()
        if process.isRunning {
            process.terminate()
            let process = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                guard process.isRunning else {
                    return
                }
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        continuation.resume(with: result)
    }
}

private struct CodexRPCIDEnvelope: Decodable {
    let id: Int?
}

private struct CodexRPCQuotaResponse: Decodable {
    let id: Int
    let result: CodexRateLimitsResponse?
    let error: CodexRPCErrorPayload?
}

private struct CodexRPCErrorPayload: Decodable {}

struct CodexRateLimitsResponse: Decodable, Sendable {
    let rateLimits: CodexRateLimitSnapshot?
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
}

struct CodexRateLimitSnapshot: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?
    let rateLimitReachedType: String?
}

struct CodexRateLimitWindow: Decodable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMins
        case resetsAt
    }

    init(usedPercent: Int, windowDurationMins: Int?, resetsAt: Int64?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let usedPercent = container.decodeFlexibleIntIfPresent(forKey: .usedPercent) else {
            throw DecodingError.dataCorruptedError(
                forKey: .usedPercent,
                in: container,
                debugDescription: "Expected a numeric usedPercent"
            )
        }
        self.usedPercent = usedPercent
        windowDurationMins = container.decodeFlexibleIntIfPresent(forKey: .windowDurationMins)
        resetsAt = container.decodeFlexibleInt64IfPresent(forKey: .resetsAt)
    }
}

struct CodexMappedUsage: Sendable {
    let planName: String?
    let usages: [TokenUsage]
    let statusMessage: String
}

enum CodexRateLimitsMapper {
    static func map(_ response: CodexRateLimitsResponse) -> CodexMappedUsage {
        let buckets = response.rateLimitsByLimitId ?? [:]
        let mainSelection: (id: String?, value: CodexRateLimitSnapshot, labelPrefix: String?)?
        if let codex = buckets["codex"] {
            mainSelection = ("codex", codex, nil)
        } else if let legacy = response.rateLimits {
            mainSelection = (legacy.limitId, legacy, nil)
        } else if let first = buckets.sorted(by: { $0.key < $1.key }).first {
            let name = first.value.limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
            mainSelection = (first.key, first.value, name?.isEmpty == false ? name : first.key)
        } else {
            mainSelection = nil
        }
        guard let mainSelection else {
            return CodexMappedUsage(planName: nil, usages: [], statusMessage: "Codex quota unavailable")
        }
        let main = mainSelection.value
        var mappedUsages = usages(for: main, labelPrefix: mainSelection.labelPrefix)

        for (id, bucket) in buckets.sorted(by: { $0.key < $1.key }) where id != mainSelection.id {
            let label = bucket.limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
            mappedUsages.append(contentsOf: usages(for: bucket, labelPrefix: label?.isEmpty == false ? label : id))
        }

        return CodexMappedUsage(
            planName: planDisplayName(main.planType),
            usages: mappedUsages,
            statusMessage: main.rateLimitReachedType == nil ? "Read-only Codex quota" : "Codex quota reached"
        )
    }

    private static func usages(for snapshot: CodexRateLimitSnapshot, labelPrefix: String?) -> [TokenUsage] {
        var result: [TokenUsage] = []
        if let primary = snapshot.primary {
            result.append(usage(from: primary, fallbackWindow: .fiveHours, fallbackLabel: "Primary", labelPrefix: labelPrefix))
        }
        if let secondary = snapshot.secondary {
            result.append(usage(from: secondary, fallbackWindow: .week, fallbackLabel: "Secondary", labelPrefix: labelPrefix))
        }
        return result
    }

    private static func usage(
        from value: CodexRateLimitWindow,
        fallbackWindow: UsageWindow,
        fallbackLabel: String,
        labelPrefix: String?
    ) -> TokenUsage {
        let descriptor = windowDescriptor(
            durationMinutes: value.windowDurationMins,
            fallbackWindow: fallbackWindow,
            fallbackLabel: fallbackLabel
        )
        let label = labelPrefix.map { "\($0) · \(descriptor.label ?? descriptor.window.title)" } ?? descriptor.label
        return TokenUsage(
            window: descriptor.window,
            label: label,
            used: min(max(value.usedPercent, 0), 100),
            limit: 100,
            resetDate: value.resetsAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            unit: "%"
        )
    }

    private static func windowDescriptor(
        durationMinutes: Int?,
        fallbackWindow: UsageWindow,
        fallbackLabel: String
    ) -> (window: UsageWindow, label: String?) {
        switch durationMinutes {
        case 300:
            return (.fiveHours, nil)
        case 10_080:
            return (.week, nil)
        case let .some(minutes) where minutes > 0:
            return (fallbackWindow, durationLabel(minutes: minutes))
        default:
            return (fallbackWindow, fallbackLabel)
        }
    }

    private static func durationLabel(minutes: Int) -> String {
        if minutes.isMultiple(of: 10_080) {
            return "\(minutes / 10_080)w"
        }
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)d"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private static func planDisplayName(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty, rawValue != "unknown" else {
            return nil
        }
        switch rawValue {
        case "prolite":
            return "Pro Lite"
        case "self_serve_business_usage_based":
            return "Business"
        case "enterprise_cbp_usage_based":
            return "Enterprise"
        default:
            return rawValue
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(exactly: value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value) ?? Double(value).flatMap { Int(exactly: $0.rounded()) }
        }
        return nil
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(exactly: value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value) ?? Double(value).flatMap { Int64(exactly: $0.rounded()) }
        }
        return nil
    }
}

private struct CodexRateLimitsCacheEntry: Sendable {
    let fetchedAt: Date
    let value: CodexRateLimitsResponse
}

private struct CodexRateLimitsFailureEntry: Sendable {
    let failedAt: Date
    let error: CodexAppServerError
}

private enum CodexRateLimitsLookup: Sendable {
    case cached(CodexRateLimitsCacheEntry)
    case failed(CodexAppServerError)
    case fetch
    case throttled
}

private actor CodexRateLimitsCache {
    private var entries: [String: CodexRateLimitsCacheEntry] = [:]
    private var failures: [String: CodexRateLimitsFailureEntry] = [:]
    private var lastRequestDates: [String: Date] = [:]

    func lookup(key: String, maxAge: TimeInterval, minimumRequestInterval: TimeInterval) -> CodexRateLimitsLookup {
        let now = Date()
        if let entry = entries[key], now.timeIntervalSince(entry.fetchedAt) < maxAge {
            return .cached(entry)
        }
        if let failure = failures[key], now.timeIntervalSince(failure.failedAt) < minimumRequestInterval {
            return .failed(failure.error)
        }
        if let lastRequestDate = lastRequestDates[key], now.timeIntervalSince(lastRequestDate) < minimumRequestInterval {
            return .throttled
        }
        lastRequestDates[key] = now
        return .fetch
    }

    func store(_ value: CodexRateLimitsResponse, key: String, fetchedAt: Date) {
        entries[key] = CodexRateLimitsCacheEntry(fetchedAt: fetchedAt, value: value)
        failures[key] = nil
    }

    func storeFailure(_ error: CodexAppServerError, key: String, failedAt: Date) {
        failures[key] = CodexRateLimitsFailureEntry(failedAt: failedAt, error: error)
    }

    func clearRequest(key: String) {
        lastRequestDates[key] = nil
    }
}
