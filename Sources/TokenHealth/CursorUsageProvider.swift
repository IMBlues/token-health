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
            let now = Date()
            let dailySpend = await fetchDailySpend(accessToken: accessToken, mapped: mapped, today: now)
            return snapshot(config: config, mapped: mapped, dailySpend: dailySpend, fetchedAt: now, today: now)
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

    /// The per-day read is a nice-to-have: it only feeds the detail's dated sections, so a failed
    /// call returns nil and never fails the refresh. Its range comes from the same window the
    /// detail is cut with, so the request and the sections cannot disagree.
    private func fetchDailySpend(
        accessToken: String,
        mapped: CursorMappedUsage,
        today: Date
    ) async -> CursorDailySpendResponse? {
        let range = Self.dailySpendRange(mapped: mapped, today: today)
        do {
            return try await client.fetchDailySpend(
                accessToken: accessToken,
                periodStartMilliseconds: range.start,
                periodEndMilliseconds: range.end
            )
        } catch {
            return nil
        }
    }

    /// The daily-spend request range for one refresh, cut from the same window the detail uses.
    /// Internal rather than private: the live smoke test asks for the same range.
    static func dailySpendRange(mapped: CursorMappedUsage, today: Date) -> (start: Int64, end: Int64) {
        let window = CursorUsageDetail.window(
            cycleStart: mapped.billingCycleStart,
            cycleEnd: mapped.billingCycleEnd,
            today: today,
            calendar: UsageDetailSupport.utcCalendar()
        )
        return (milliseconds(since1970: window.fetchStart), milliseconds(since1970: window.fetchEnd))
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Internal rather than private: tests hand it synthetic data and a fixed `today` instead of
    /// touching the network or racing UTC midnight.
    func snapshot(
        config: ServiceConfig,
        mapped: CursorMappedUsage,
        dailySpend: CursorDailySpendResponse?,
        fetchedAt: Date,
        today: Date
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: config.id,
            serviceName: config.displayName,
            providerTitle: config.providerKind.title,
            planName: mapped.planName,
            usages: mapped.usages,
            detail: CursorUsageDetail.make(
                usages: mapped.usages,
                planBreakdown: mapped.breakdown,
                cycleStart: mapped.billingCycleStart,
                cycleEnd: mapped.billingCycleEnd,
                dailySpend: dailySpend,
                today: today
            ),
            state: .ready,
            statusMessage: "Read-only Cursor quota",
            updatedAt: fetchedAt
        )
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
    private static let usageSummaryEndpoint = URL(string: "https://api2.cursor.sh/auth/usage-summary")!
    private static let dailySpendEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetDailySpendByCategory"
    )!
    private static let maxResponseBytes = 1_048_576
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(accessToken: String) async throws -> CursorUsageSummary {
        var request = URLRequest(url: Self.usageSummaryEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse
        }
    }

    /// The dashboard's daily tokens per category. `group_by` 0 groups by model; the other
    /// groupings (`spend_type`, user/automation) are not used by the popover.
    func fetchDailySpend(
        accessToken: String,
        periodStartMilliseconds: Int64,
        periodEndMilliseconds: Int64
    ) async throws -> CursorDailySpendResponse {
        var request = URLRequest(url: Self.dailySpendEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "teamId": 0,
            "periodStartMs": periodStartMilliseconds,
            "periodEndMs": periodEndMilliseconds,
            "groupBy": 0
        ])

        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(CursorDailySpendResponse.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse
        }
    }

    /// The status, size and transport rules both reads share.
    private func responseData(for request: URLRequest) async throws -> Data {
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
        return data
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
    let grokbotPercentUsed: Double?
    let grokBotPercentUsed: Double?

    private enum CodingKeys: String, CodingKey { case plan, grokbotPercentUsed, grokBotPercentUsed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(CursorUsagePlan.self, forKey: .plan)
        grokbotPercentUsed = c.decodeCursorDoubleIfPresent(forKey: .grokbotPercentUsed)
        grokBotPercentUsed = c.decodeCursorDoubleIfPresent(forKey: .grokBotPercentUsed)
    }
}

struct CursorUsagePlan: Decodable, Sendable {
    let enabled: Bool?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
    let grokbotPercentUsed: Double?
    let grokPercentUsed: Double?
    let grokBotPercentUsed: Double?
    /// Included / bonus / total, in cents. The popover's spend strip reads this.
    let breakdown: CursorPlanBreakdown?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case autoPercentUsed
        case apiPercentUsed
        case totalPercentUsed
        case grokbotPercentUsed
        case grokPercentUsed
        case grokBotPercentUsed
        case breakdown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        autoPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .autoPercentUsed)
        apiPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .apiPercentUsed)
        totalPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .totalPercentUsed)
        grokbotPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .grokbotPercentUsed)
        grokPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .grokPercentUsed)
        grokBotPercentUsed = container.decodeCursorDoubleIfPresent(forKey: .grokBotPercentUsed)
        breakdown = try? container.decodeIfPresent(CursorPlanBreakdown.self, forKey: .breakdown)
    }
}

/// The plan's spend split, in cents (`2000` is $20).
struct CursorPlanBreakdown: Decodable, Equatable, Sendable {
    let included: Int?
    let bonus: Int?
    let total: Int?

    private enum CodingKeys: String, CodingKey {
        case included
        case bonus
        case total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        included = container.decodeCursorIntIfPresent(forKey: .included)
        bonus = container.decodeCursorIntIfPresent(forKey: .bonus)
        total = container.decodeCursorIntIfPresent(forKey: .total)
    }
}

/// One response from the dashboard's daily-token read. Every field is lenient: a missing piece
/// drops that row, never the whole response.
struct CursorDailySpendResponse: Decodable, Sendable {
    let dailySpend: [CursorDailySpendRow]?
}

struct CursorDailySpendRow: Decodable, Sendable {
    /// Epoch milliseconds of the day's UTC midnight, which the backend writes as a string.
    let dayMilliseconds: Int64?
    let category: String?
    let totalTokens: Int64?

    private enum CodingKeys: String, CodingKey {
        case day
        case category
        case totalTokens
    }

    init(from decoder: Decoder) throws {
        // A row that is not even an object becomes an all-nil row, which the detail builder
        // drops. Letting it throw would take the whole array — and every other row — with it.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            dayMilliseconds = nil
            category = nil
            totalTokens = nil
            return
        }
        dayMilliseconds = container.decodeCursorInt64IfPresent(forKey: .day)
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        totalTokens = container.decodeCursorInt64IfPresent(forKey: .totalTokens)
    }
}

struct CursorMappedUsage: Equatable, Sendable {
    let planName: String?
    let usages: [TokenUsage]
    /// Both halves of the billing cycle, when the response carried them. The detail's window is
    /// cut from these; a missing or unparseable half falls back to a 30-day window.
    let billingCycleStart: Date?
    let billingCycleEnd: Date?
    let breakdown: CursorPlanBreakdown?
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
        if let grokbotPercentUsed = plan.grokbotPercentUsed ?? plan.grokPercentUsed ?? plan.grokBotPercentUsed ?? response.individualUsage?.grokbotPercentUsed ?? response.individualUsage?.grokBotPercentUsed {
            usages.append(
                monthlyUsage(
                    label: "Grokbot",
                    percentage: grokbotPercentUsed,
                    resetDate: resetDate
                )
            )
        } else if let autoPercentUsed = plan.autoPercentUsed {
            // Cursor currently reports Grokbot models inside the Auto bucket rather
            // than exposing a separate percentage. Keep the pool visible until the
            // API provides a dedicated Grokbot value.
            usages.append(
                monthlyUsage(
                    label: "Grokbot (included in Auto)",
                    percentage: autoPercentUsed,
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
            usages: usages,
            billingCycleStart: response.billingCycleStart.flatMap(parseDate),
            billingCycleEnd: response.billingCycleEnd.flatMap(parseDate),
            breakdown: plan.breakdown
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

    /// The daily read writes its integers as JSON strings (`"49474832"`) while the usage summary
    /// writes the same kinds of numbers bare, so both spellings have to decode.
    func decodeCursorIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            guard value.isFinite, let converted = Int(exactly: value.rounded(.towardZero)) else {
                return nil
            }
            return converted
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeCursorInt64IfPresent(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            guard value.isFinite, let converted = Int64(exactly: value.rounded(.towardZero)) else {
                return nil
            }
            return converted
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}
