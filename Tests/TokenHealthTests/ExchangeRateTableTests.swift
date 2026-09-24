import Foundation
import Testing
@testable import TokenHealth

struct ExchangeRateTableTests {
    private let table = ExchangeRateTable(
        base: "USD",
        rates: ["CNY": 6.7074],
        fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
        origin: .live
    )

    @Test
    func convertsAcrossTheBaseCurrency() {
        #expect(table.convert(100, from: "USD", to: "CNY") == Decimal(string: "670.74"))
        #expect(table.convert(Decimal(string: "670.74")!, from: "CNY", to: "USD")?.rounded(2) == Decimal(string: "100"))
    }

    @Test
    func convertingToTheSameCurrencyIsIdentity() {
        #expect(table.convert(12.34, from: "CNY", to: "cny") == Decimal(string: "12.34"))
        #expect(table.convert(12.34, from: "USD", to: "USD") == Decimal(string: "12.34"))
    }

    @Test
    func returnsNilForUnknownCurrencies() {
        #expect(table.convert(10, from: "USD", to: "EUR") == nil)
        #expect(table.convert(10, from: "JPY", to: "CNY") == nil)
        #expect(table.rate(from: "USD", to: "EUR") == nil)
    }

    @Test
    func rejectsNonPositiveRates() {
        let zeroed = ExchangeRateTable(base: "USD", rates: ["CNY": 0], fetchedAt: Date(), origin: .live)
        #expect(zeroed.convert(10, from: "USD", to: "CNY") == nil)

        let negative = ExchangeRateTable(base: "USD", rates: ["CNY": -7], fetchedAt: Date(), origin: .live)
        #expect(negative.convert(10, from: "USD", to: "CNY") == nil)
    }

    @Test
    func fallbackShipsAFixedRate() {
        #expect(ExchangeRateTable.fallback.origin == .fallback)
        #expect(ExchangeRateTable.fallback.rate(from: "USD", to: "CNY") == 7.2)
    }

    @Test
    func decodesOlderPayloadsThatOmitFields() throws {
        let json = Data(#"{"rates":{"CNY":7.1}}"#.utf8)
        let decoded = try JSONDecoder().decode(ExchangeRateTable.self, from: json)
        #expect(decoded.base == "USD")
        #expect(decoded.origin == .cache)
        #expect(decoded.rates == ["CNY": 7.1])
    }
}

private extension Decimal {
    func rounded(_ places: Int) -> Decimal {
        var input = self
        var result = Decimal()
        NSDecimalRound(&result, &input, places, .plain)
        return result
    }
}
