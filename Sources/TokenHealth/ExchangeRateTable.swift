import Foundation

/// 汇率表，只以单一基准币种存储，跨币种换算经基准中转。
struct ExchangeRateTable: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        case live
        case cache
        case fallback
    }

    static let baseCurrency = "USD"

    /// 联网失败且没有任何缓存时的兜底汇率，由设置界面明确标注。
    static let fallback = ExchangeRateTable(
        base: baseCurrency,
        rates: ["CNY": 7.2],
        fetchedAt: Date(timeIntervalSince1970: 0),
        origin: .fallback
    )

    var base: String
    var rates: [String: Double]
    var fetchedAt: Date
    var origin: Origin

    init(base: String, rates: [String: Double], fetchedAt: Date, origin: Origin) {
        self.base = base
        self.rates = rates
        self.fetchedAt = fetchedAt
        self.origin = origin
    }

    /// 解码按字段可选处理：换过形状的旧数据仍能读出来，走默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = try container.decodeIfPresent(String.self, forKey: .base) ?? Self.baseCurrency
        rates = try container.decodeIfPresent([String: Double].self, forKey: .rates) ?? [:]
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .cache
    }

    /// `rate(from:to:)` 的金额版本；缺失或非法汇率返回 nil，由调用方回退到原币种。
    func convert(_ amount: Decimal, from source: String, to target: String) -> Decimal? {
        guard let rate = rate(from: source, to: target) else {
            return nil
        }
        // Double 的二进制误差会顺着 Decimal 乘法传下去，先截到 6 位再转成十进制。
        let text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), rate)
        guard let decimalRate = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              decimalRate > 0 else {
            // 极端汇率（例如 1 CNY = 2e7 USD）会截成 0。与其返回一个静默变成 0 的金额，
            // 不如当作换不了，让调用方回退到原币种。
            return nil
        }
        return amount * decimalRate
    }

    func rate(from source: String, to target: String) -> Double? {
        let source = source.uppercased()
        let target = target.uppercased()
        if source == target {
            return 1
        }
        guard let sourceRate = rateAgainstBase(source), let targetRate = rateAgainstBase(target) else {
            return nil
        }
        let rate = targetRate / sourceRate
        return rate.isFinite && rate > 0 ? rate : nil
    }

    private func rateAgainstBase(_ currency: String) -> Double? {
        if currency == base.uppercased() {
            return 1
        }
        guard let rate = rates.first(where: { $0.key.uppercased() == currency })?.value,
              rate.isFinite, rate > 0 else {
            return nil
        }
        return rate
    }
}
