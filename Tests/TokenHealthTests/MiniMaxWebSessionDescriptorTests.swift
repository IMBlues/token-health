import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct MiniMaxWebSessionDescriptorTests {
    private let descriptor = MiniMaxWebSessionDescriptor()

    @Test
    func filtersCookiesByBothMiniMaxDomains() {
        // Two domain families are accepted, matching the old controller's filter verbatim:
        // `domain.lowercased().contains("minimaxi.com") || domain.lowercased().contains("minimax.io")`.
        // Matching is substring-based, so `evilminimaxi.com.example` would also match.
        #expect(descriptor.shouldIncludeCookie(domain: "platform.minimaxi.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "www.minimaxi.com"))
        #expect(descriptor.shouldIncludeCookie(domain: ".minimaxi.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "minimax.io"))
        #expect(descriptor.shouldIncludeCookie(domain: ".minimax.io"))
        #expect(descriptor.shouldIncludeCookie(domain: "MINIMAXI.COM"))
        #expect(!descriptor.shouldIncludeCookie(domain: "example.com"))
        #expect(!descriptor.shouldIncludeCookie(domain: "openai.com"))
    }

    @Test
    func buildsCredentialFromExtractionResult() {
        let extraction = #"{"href":"https://platform.minimaxi.com/console/usage","accessToken":"tok-1","groupID":"group-123","accountName":"alice@example.com"}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "minimax_group_id_v2=cookie-group; theme=dark",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { MiniMaxWebSessionCredential.decode(from: $0) }
        #expect(decoded?.accessToken == "tok-1")
        #expect(decoded?.cookieHeader == "minimax_group_id_v2=cookie-group; theme=dark")
        #expect(decoded?.groupID == "group-123")
        #expect(decoded?.accountName == "alice@example.com")
    }

    @Test
    func prefersTheExtractedGroupIDOverTheCookie() {
        let encoded = descriptor.encodeCredential(
            extractionJSON: #"{"accessToken":"tok-1","groupID":"from-extraction","accountName":"alice"}"#,
            cookieHeader: "minimax_group_id_v2=from-cookie",
            pageTitle: nil
        )

        #expect(MiniMaxWebSessionCredential.decode(from: encoded ?? "")?.groupID == "from-extraction")
    }

    @Test
    func keepsAnEmptyExtractedGroupIDInsteadOfTheCookie() {
        // The extraction script always emits `groupID` — `""` when it found nothing — so the `??`
        // order, not an emptiness test, decides: an empty extracted value beats a populated
        // `minimax_group_id_v2` cookie. Rewriting this as `if groupID.isEmpty { … }` would silently
        // swap in the cookie value here.
        let encoded = descriptor.encodeCredential(
            extractionJSON: #"{"accessToken":"tok-1","groupID":"","accountName":"alice"}"#,
            cookieHeader: "minimax_group_id_v2=from-cookie",
            pageTitle: nil
        )

        #expect(MiniMaxWebSessionCredential.decode(from: encoded ?? "")?.groupID == "")
    }

    @Test
    func fallsBackToTheGroupIDCookieOnlyWhenTheExtractionIsNotJSON() {
        // The old controller only reached its cookie group id when the extraction produced no JSON
        // at all (`storageCredential ?? MiniMaxWebSessionCredential()` followed by `??`).
        let encoded = descriptor.encodeCredential(
            extractionJSON: "not json",
            cookieHeader: "minimax_group_id_v2=from-cookie",
            pageTitle: nil
        )

        #expect(MiniMaxWebSessionCredential.decode(from: encoded ?? "")?.groupID == "from-cookie")
    }

    @Test
    func readsTheGroupIDCookieByItsFullNameOnly() {
        // The protocol's named-cookie rule: match the whole name before the first "=", never a
        // prefix, so a "minimax_group_id_v2_x" decoy cannot satisfy the lookup.
        let encoded = descriptor.encodeCredential(
            extractionJSON: "not json",
            cookieHeader: "minimax_group_id_v2_x=decoy; minimax_group_id_v2=real",
            pageTitle: nil
        )

        #expect(MiniMaxWebSessionCredential.decode(from: encoded ?? "")?.groupID == "real")
    }

    @Test
    func importsOnTokenOrCookieAlone() {
        // `isEmpty` is token-and-cookie, so the credential is empty only when both are missing —
        // any matching cookie made the old controller import the session.
        #expect(descriptor.encodeCredential(extractionJSON: #"{"accessToken":"","groupID":"","accountName":""}"#, cookieHeader: nil, pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: #"{"accessToken":"","groupID":"","accountName":""}"#, cookieHeader: "", pageTitle: nil) == nil)

        let tokenOnly = descriptor.encodeCredential(
            extractionJSON: #"{"accessToken":"tok-1","groupID":"","accountName":""}"#,
            cookieHeader: nil,
            pageTitle: nil
        )
        #expect(MiniMaxWebSessionCredential.decode(from: tokenOnly ?? "")?.accessToken == "tok-1")

        let cookieOnly = descriptor.encodeCredential(
            extractionJSON: "not json",
            cookieHeader: "theme=dark",
            pageTitle: nil
        )
        #expect(MiniMaxWebSessionCredential.decode(from: cookieOnly ?? "")?.cookieHeader == "theme=dark")
    }

    @Test
    func returnsWholeEnvelopeAsUsageData() throws {
        let envelope = #"{"ok":true,"status":200,"text":"{\"code\":200}","hasAccessToken":true,"hasGroupID":true,"subscription":{"a":1},"remains":{"b":2},"credits":{"c":3},"summary":{"d":4}}"#
        let data = try descriptor.usageData(fromScriptResult: envelope)

        // The parser reads the envelope's own subscription/remains/credits/summary keys (like
        // DeepSeek and OpenCode Go), not a single site response body.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["subscription"] != nil)
        #expect(object?["remains"] != nil)
        #expect(object?["credits"] != nil)
        #expect(object?["summary"] != nil)
        #expect(object?["text"] as? String == #"{"code":200}"#)
    }

    @Test
    func fallsBackToThePageTitleForTheAccountName() {
        // Like the group id, the page title is only consulted when the extraction carries no
        // `accountName` value; a parsed extraction always emits the key.
        let titled = descriptor.encodeCredential(
            extractionJSON: #"{"accessToken":"tok-1","groupID":""}"#,
            cookieHeader: nil,
            pageTitle: "Alice"
        )
        #expect(MiniMaxWebSessionCredential.decode(from: titled ?? "")?.accountName == "Alice")

        // The platform's own title is filtered out, as in the old controller.
        let generic = descriptor.encodeCredential(
            extractionJSON: #"{"accessToken":"tok-1","groupID":""}"#,
            cookieHeader: nil,
            pageTitle: "MiniMax Platform"
        )
        #expect(MiniMaxWebSessionCredential.decode(from: generic ?? "")?.accountName == nil)
    }

    @Test
    func exposesAccountLabelFromCredential() {
        var credential = MiniMaxWebSessionCredential()
        credential.accessToken = "tok-1"
        credential.groupID = "group-123"
        credential.accountName = "alice@example.com"
        #expect(descriptor.accountLabel(fromCredential: credential.encodedForStorage()) == "alice@example.com")

        credential.accountName = nil
        #expect(descriptor.accountLabel(fromCredential: credential.encodedForStorage()) == nil)
        credential.accountName = ""
        #expect(descriptor.accountLabel(fromCredential: credential.encodedForStorage()) == nil)
        #expect(descriptor.accountLabel(fromCredential: "garbage") == nil)
    }

    @Test
    func exposesProviderCopy() {
        #expect(descriptor.providerTitle == "MiniMax")
        #expect(descriptor.loginInstructions == "Log in with MiniMax Platform, wait for Usage to load, then import.")
        #expect(descriptor.missingSessionMessage == "No session found. Make sure MiniMax Platform is logged in.")
        #expect(descriptor.loginURL.absoluteString == "https://platform.minimaxi.com/console/usage")
        // The default origin is load-bearing: the usage script reads access_token/user_detail/
        // minimax_current_group_id from this origin's localStorage and reaches www.minimaxi.com
        // only through absolute URLs. Overriding originHost to www.minimaxi.com would compile and
        // still "work" while making every fetch reload the whole page first.
        #expect(descriptor.originHost == "platform.minimaxi.com")
        #expect(descriptor.originHost == descriptor.loginURL.host)
    }
}
