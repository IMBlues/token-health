import Foundation
import Testing
@testable import TokenHealth

@Suite
struct WebSessionCredentialTests {
    @Test
    func roundTripsAllFields() {
        let credential = DeepSeekWebSessionCredential(
            accessToken: "token-123",
            cookieHeader: "a=1; b=2",
            accountName: "user@example.com"
        )

        let encoded = credential.encodedForStorage()
        #expect(encoded.hasPrefix("deepseek-web-session:"))

        #expect(DeepSeekWebSessionCredential.decode(from: encoded) == credential)
    }

    @Test
    func decodesLegacyStoredFormat() {
        let legacy = #"deepseek-web-session:{"accessToken":"legacy-token","cookieHeader":"c=3","accountName":"old@example.com"}"#
        let decoded = DeepSeekWebSessionCredential.decode(from: legacy)

        #expect(decoded?.accessToken == "legacy-token")
        #expect(decoded?.cookieHeader == "c=3")
        #expect(decoded?.accountName == "old@example.com")
    }

    @Test
    func rejectsForeignPrefix() {
        #expect(DeepSeekWebSessionCredential.decode(from: #"kimi-web-session:{"accessToken":"x"}"#) == nil)
    }

    @Test
    func rejectsCorruptedJSON() {
        #expect(DeepSeekWebSessionCredential.decode(from: "deepseek-web-session:{not json") == nil)
    }

    @Test
    func reportsEmptinessFromAccessToken() {
        #expect(DeepSeekWebSessionCredential(accessToken: nil, cookieHeader: "a=1", accountName: nil).isEmpty)
        #expect(!DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: nil).isEmpty)
    }

    @Test
    func exposesAccountLabelOnlyWhenNamed() {
        #expect(DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: "me@x.com").accountLabel == "me@x.com")
        #expect(DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: "").accountLabel == nil)
        #expect(DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: nil).accountLabel == nil)
    }

    @Test
    func roundTripsAConformerWithADifferentFieldSet() {
        let credential = SyntheticCredential(cookieHeader: "c=1", note: "n")

        let decoded = SyntheticCredential.decode(from: credential.encodedForStorage())

        #expect(decoded == credential)
        #expect(SyntheticCredential.decode(from: "deepseek-web-session:{}") == nil)
    }

    @Test
    func decodesLegacyStringMissingOptionalKeys() {
        let decoded = DeepSeekWebSessionCredential.decode(from: #"deepseek-web-session:{"accessToken":"t"}"#)

        #expect(decoded?.accessToken == "t")
        #expect(decoded?.cookieHeader == nil)
        #expect(decoded?.accountName == nil)
    }

    private struct SyntheticCredential: WebSessionCredential {
        static let storagePrefix = "synthetic-web-session:"
        var cookieHeader: String?
        var note: String?

        var isEmpty: Bool { (cookieHeader ?? "").isEmpty }
        var debugSummary: String { "cookie=\((cookieHeader ?? "").isEmpty ? "no" : "yes")" }
        var accountLabel: String? { nil }
    }
}
