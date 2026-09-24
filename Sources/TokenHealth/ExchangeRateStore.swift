import Foundation

/// 汇率来源。抽成协议是为了让缓存与回退逻辑能在测试里不碰网络。
protocol ExchangeRateFetching: Sendable {
    func fetchTable() async throws -> ExchangeRateTable
}

/// Frankfurter 提供 ECB 数据，无需 API key，返回形如
/// `{"amount":1.0,"base":"USD","date":"2026-09-23","rates":{"CNY":6.7074}}`。
struct FrankfurterRateFetcher: ExchangeRateFetching {
    static let endpoint = URL(string: "https://api.frankfurter.app/latest?from=USD&to=CNY")!

    var session: URLSession = .shared

    private struct Response: Decodable {
        let base: String
        let rates: [String: Double]
    }

    func fetchTable() async throws -> ExchangeRateTable {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.rates.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return ExchangeRateTable(
            base: decoded.base,
            rates: decoded.rates,
            fetchedAt: Date(),
            origin: .live
        )
    }
}

/// 持有当前汇率，负责抓取与回退。AppState 拥有它，并把结果发布给界面。
@MainActor
final class ExchangeRateStore {
    static let ttl: TimeInterval = 12 * 60 * 60

    private let configStore: ConfigStore
    private let fetcher: any ExchangeRateFetching
    private var isRefreshing = false

    private(set) var table: ExchangeRateTable

    init(
        configStore: ConfigStore = ConfigStore(),
        fetcher: any ExchangeRateFetching = FrankfurterRateFetcher()
    ) {
        self.configStore = configStore
        self.fetcher = fetcher
        table = configStore.loadExchangeRate() ?? .fallback
    }

    var isStale: Bool {
        Date().timeIntervalSince(table.fetchedAt) >= Self.ttl
    }

    /// 启动与每次刷新后调用；只有缓存过期才真的发请求。
    @discardableResult
    func refreshIfStale() async -> ExchangeRateTable {
        guard isStale else {
            return table
        }
        return await refreshNow()
    }

    /// 设置里的手动刷新按钮。
    @discardableResult
    func refreshNow() async -> ExchangeRateTable {
        guard !isRefreshing else {
            return table
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await fetcher.fetchTable()
            table = fetched
            configStore.saveExchangeRate(fetched)
            return fetched
        } catch {
            // 拿不到就用手里最好的那份：来源从 live 降级为 cache，没有缓存时仍是 fallback。
            // 这是展示层的降级，不写 AppState.lastError。
            if table.origin == .live {
                table = ExchangeRateTable(
                    base: table.base,
                    rates: table.rates,
                    fetchedAt: table.fetchedAt,
                    origin: .cache
                )
            }
            return table
        }
    }
}
