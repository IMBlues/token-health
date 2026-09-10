import Foundation

struct CursorUsageProvider: UsageProvider {
    private let client: CursorUsageClient
    private let credentialReader: CursorLocalSessionReader

    init(
        client: CursorUsageClient = CursorUsageClient(),
        credentialReader: CursorLocalSessionReader = CursorLocalSessionReader()
    ) {
        self.client = client
        self.credentialReader = credentialReader
    }

    func fetchUsage(config: ServiceConfig, secrets _: ProviderSecrets) async -> ProviderUsageSnapshot {
        do {
            let accessToken = try credentialReader.readAccessToken()
            let response = try await client.fetchUsage(accessToken: accessToken)
            let mapped = try CursorUsageMapper.map(response)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: mapped.planName,
                usages: mapped.usages,
                state: .ready,
                statusMessage: "Read-only Cursor quota",
                updatedAt: Date()
            )
        } catch let error as CursorUsageError {
            let state: ProviderUsageSnapshot.State = switch error {
            case .cursorDataNotFound, .notSignedIn, .sessionExpired:
                .needsConfiguration
            case .invalidResponse, .readerFailed, .requestFailed, .responseTooLarge:
                .unavailable
            }
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                usages: [],
                state: state,
                statusMessage: error.localizedDescription,
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(
                config: config,
                message: "Cursor quota is unavailable"
            )
        }
    }
}

struct CursorLocalSessionReader: Sendable {
    private static let maxTokenBytes = 16_384
    private let databaseURL: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        databaseURL = homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    #if DEBUG
    init(testDatabaseURL: URL) {
        databaseURL = testDatabaseURL
    }
    #endif

    func readAccessToken() throws -> String {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CursorUsageError.cursorDataNotFound
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            databaseURL.path,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CursorUsageError.readerFailed
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CursorUsageError.readerFailed
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= Self.maxTokenBytes,
              let value = String(data: data, encoding: .utf8) else {
            throw CursorUsageError.readerFailed
        }
        let accessToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw CursorUsageError.notSignedIn
        }
        return accessToken
    }
}

struct CursorUsageClient: Sendable {
    private static let endpoint = URL(string: "https://api2.cursor.sh/auth/usage-summary")!
    private static let maxResponseBytes = 1_048_576
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(accessToken: String) async throws -> CursorUsageSummary {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorUsageError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CursorUsageError.sessionExpired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CursorUsageError.requestFailed(httpResponse.statusCode)
        }
        guard data.count <= Self.maxResponseBytes else {
            throw CursorUsageError.responseTooLarge
        }

        do {
            return try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse
        }
    }
}

struct CursorUsageSummary: Decodable, Sendable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let isUnlimited: Bool?
    let individualUsage: CursorAccountUsage?
}

struct CursorAccountUsage: Decodable, Sendable {
    let plan: CursorUsagePlan?
}

struct CursorUsagePlan: Decodable, Sendable {
    let enabled: Bool?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
    let grokbotPercentUsed: Double?
    let grokPercentUsed: Double?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case autoPercentUsed
        case apiPercentUsed
        case totalPercentUsed
        case grokbotPercentUsed
        case grokPercentUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        autoPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .autoPercentUsed)
        apiPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .apiPercentUsed)
        totalPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .totalPercentUsed)
        grokbotPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .grokbotPercentUsed)
        grokPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .grokPercentUsed)
    }
}

struct CursorMappedUsage: Equatable, Sendable {
    let planName: String?
    let usages: [TokenUsage]
}

enum CursorUsageMapper {
    static func map(_ response: CursorUsageSummary) throws -> CursorMappedUsage {
        guard let plan = response.individualUsage?.plan else {
            throw CursorUsageError.invalidResponse
        }

        let resetDate = response.billingCycleEnd.flatMap(parseDate)
        var usages: [TokenUsage] = []
        if let autoPercentUsed = plan.autoPercentUsed {
            usages.append(
                monthlyUsage(
                    label: "Auto + Composer",
                    percentage: autoPercentUsed,
                    resetDate: resetDate
                )
            )
        }
        if let apiPercentUsed = plan.apiPercentUsed {
            usages.append(
                monthlyUsage(
                    label: "API",
                    percentage: apiPercentUsed,
                    resetDate: resetDate
                )
            )
        }
        if let grokbotPercentUsed = plan.grokbotPercentUsed ?? plan.grokPercentUsed {
            usages.append(
                monthlyUsage(
                    label: "Grokbot",
                    percentage: grokbotPercentUsed,
                    resetDate: resetDate
                )
            )
        }

        if usages.isEmpty, let totalPercentUsed = plan.totalPercentUsed {
            usages.append(
                monthlyUsage(
                    label: "Included usage",
                    percentage: totalPercentUsed,
                    resetDate: resetDate
                )
            )
        }
        guard !usages.isEmpty else {
            throw CursorUsageError.invalidResponse
        }

        return CursorMappedUsage(
            planName: planDisplayName(response.membershipType),
            usages: usages
        )
    }

    private static func monthlyUsage(
        label: String,
        percentage: Double,
        resetDate: Date?
    ) -> TokenUsage {
        let rounded = percentage.isFinite ? percentage.rounded() : 0
        let clamped = min(max(rounded, 0), 100)
        return TokenUsage(
            window: .month,
            label: label,
            used: Int(clamped),
            limit: 100,
            resetDate: resetDate,
            unit: "%"
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func planDisplayName(_ rawValue: String?) -> String? {
        guard let rawValue,
              !rawValue.isEmpty,
              rawValue.caseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        switch rawValue.lowercased() {
        case "pro":
            return "Pro"
        case "pro_plus", "proplus":
            return "Pro Plus"
        case "ultra":
            return "Ultra"
        case "hobby", "free":
            return "Hobby"
        case "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        default:
            return rawValue
                .split(whereSeparator: { $0 == "_" || $0 == "-" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

enum CursorUsageError: LocalizedError, Sendable {
    case cursorDataNotFound
    case invalidResponse
    case notSignedIn
    case readerFailed
    case requestFailed(Int)
    case responseTooLarge
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .cursorDataNotFound:
            "Install the official Cursor app and sign in"
        case .notSignedIn:
            "Sign in to the official Cursor app"
        case .sessionExpired:
            "Cursor session expired; sign in again"
        case .readerFailed:
            "Cursor login session could not be read"
        case .requestFailed(let statusCode):
            "Cursor quota request failed with HTTP \(statusCode)"
        case .responseTooLarge:
            "Cursor quota response exceeded the safety limit"
        case .invalidResponse:
            "Cursor returned an unsupported quota response"
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeCursorDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}
