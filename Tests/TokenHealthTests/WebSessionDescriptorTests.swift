import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct WebSessionDescriptorTests {
    private let descriptor = DeepSeekWebSessionDescriptor()

    @Test
    func filtersCookiesByDeepSeekDomain() {
        #expect(descriptor.shouldIncludeCookie(domain: "platform.deepseek.com"))
        #expect(descriptor.shouldIncludeCookie(domain: ".deepseek.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "DEEPSEEK.COM"))
        // Filtering is substring matching (carried over from the old implementation), so a
        // domain like notdeepseek.example.com would also match; here we only assert on domains
        // that truly do not contain the "deepseek" substring.
        #expect(!descriptor.shouldIncludeCookie(domain: "example.com"))
        #expect(!descriptor.shouldIncludeCookie(domain: "example.org"))
        #expect(!descriptor.shouldIncludeCookie(domain: "openai.com"))
    }

    @Test
    func buildsCredentialFromExtractionResult() {
        let extraction = #"{"href":"https://platform.deepseek.com/usage","accessToken":"tok-1","userSummary":{"email":"me@example.com"}}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "c=1",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { DeepSeekWebSessionCredential.decode(from: $0) }
        #expect(decoded?.accessToken == "tok-1")
        #expect(decoded?.cookieHeader == "c=1")
        #expect(decoded?.accountName == "me@example.com")
    }

    @Test
    func fallsBackToPageTitleWhenSummaryHasNoAccount() {
        let extraction = #"{"accessToken":"tok-2","userSummary":null}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: nil,
            pageTitle: "me@example.com"
        )

        #expect(DeepSeekWebSessionCredential.decode(from: encoded ?? "")?.accountName == "me@example.com")
    }

    @Test
    func returnsNilWhenNoAccessToken() {
        #expect(descriptor.encodeCredential(extractionJSON: #"{"accessToken":""}"#, cookieHeader: "c=1", pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: "not json", cookieHeader: "c=1", pageTitle: nil) == nil)
    }

    @Test
    func scansNestedSummaryForAccountIdentifier() {
        #expect(DeepSeekWebSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["phone": "13800000000"]]) == "13800000000")
        #expect(DeepSeekWebSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["nickname": "blues", "email": "a@b.co"]]) == "a@b.co")
        #expect(DeepSeekWebSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["id": "12345678"]]) == "12345678")
        // Email wins over numeric ids: numeric fields like created_at sort before email by key
        // name, so they must not displace the email.
        #expect(DeepSeekWebSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["created_at": "1789000000", "email": "a@b.co"]]) == "a@b.co")
        #expect(DeepSeekWebSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["created_at": "1789000000"]]) == nil)
        #expect(DeepSeekWebSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["nickname": "blues"]]) == nil)
        #expect(DeepSeekWebSessionDescriptor.accountLabel(fromSummary: nil) == nil)
    }

    @Test
    func returnsWholeEnvelopeAsUsageData() throws {
        let envelope = #"{"ok":true,"status":200,"summary":{"a":1},"amount":{"b":2},"cost":{"c":3}}"#
        let data = try descriptor.usageData(fromScriptResult: envelope)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["summary"] != nil)
        #expect(object?["amount"] != nil)
        #expect(object?["cost"] != nil)
    }

    @Test
    func usageScriptMentionsRequestedMonth() {
        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9))
        #expect(script.contains("month=9&year=2026"))
    }

    @Test
    func buildsTheCurrentUTCMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date()
        let context = WebSessionFetchContext.currentUTC(now: now)

        #expect(context.year == calendar.component(.year, from: now))
        #expect(context.month == calendar.component(.month, from: now))
    }

    @Test
    func extractionScriptRequestsUserSummary() {
        let script = descriptor.extractionScript
        #expect(script.contains("summary.send()"))
        #expect(script.contains("/api/v0/users/get_user_summary"))
    }

    @Test
    func treatsUnauthorizedEnvelopeAsAuthenticationFailure() {
        #expect(descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":false,"status":401,"text":"unauthorized"}"#))
        #expect(descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":false,"status":403,"text":"forbidden"}"#))
        #expect(!descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":false,"status":500,"text":"boom"}"#))
        #expect(!descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":true,"status":200,"text":""}"#))
        #expect(!descriptor.isAuthenticationFailure(scriptResultJSON: "not json"))
    }

    @Test
    func parsesScriptEnvelope() {
        let envelope = WebSessionScriptEnvelope.parse(#"{"ok":false,"status":403,"text":"forbidden","extra":1}"#)
        #expect(envelope?.ok == false)
        #expect(envelope?.status == 403)
        #expect(envelope?.text == "forbidden")
        #expect(WebSessionScriptEnvelope.parse("not json") == nil)
        #expect(WebSessionScriptEnvelope.object(from: #"{"hasAccessToken":true}"#)?["hasAccessToken"] as? Bool == true)
        #expect(WebSessionScriptEnvelope.object(from: "not json") == nil)
    }

    @Test
    func factoryKnowsEveryMigratedProvider() {
        let factory = WebSessionDescriptorFactory()
        #expect(factory.descriptor(for: .deepSeek) != nil)
        #expect(factory.descriptor(for: .openCodeGo) != nil)
        #expect(factory.descriptor(for: .kimiCode) == nil)
        #expect(factory.descriptor(for: .demo) == nil)
    }

    @Test
    func exposesProviderCopy() {
        #expect(descriptor.providerTitle == "DeepSeek")
        #expect(descriptor.loginInstructions == "Log in with DeepSeek Platform, wait for Usage to load, then import.")
        #expect(descriptor.missingSessionMessage == "No session found. Make sure DeepSeek Platform is logged in.")
        #expect(descriptor.originHost == descriptor.loginURL.host)
    }

    @Test
    func errorDescriptionsAreUserFacing() {
        #expect(WebSessionError.unsupportedProvider.errorDescription == "This provider does not support web login")
        #expect(WebSessionError.cancelled(providerTitle: "Kimi").errorDescription == "Kimi login cancelled")
        #expect(WebSessionError.sessionExpired(providerTitle: "Kimi").errorDescription == "Kimi session expired. Log in again for this account.")
        #expect(WebSessionError.loadTimeout(providerTitle: "Kimi", seconds: 20).errorDescription == "Kimi page did not load within 20 seconds.")
        #expect(WebSessionError.invalidResponse(providerTitle: "Kimi").errorDescription == "Kimi usage response was invalid")
        #expect(WebSessionError.requestFailed(providerTitle: "Kimi", message: "boom").errorDescription == "boom")
    }

    @Test
    func allowsOverridingTheAuthFailureRule() {
        // Guards the A3 fix: a conformer's own implementation must win through the protocol.
        // The call must go through the existential — a concrete-typed call binds statically to the
        // conformer's member and would pass even without the requirement.
        let descriptor: any WebSessionDescriptor = OverridingDescriptor()
        #expect(descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":false,"status":500,"text":""}"#))
    }

    private struct OverridingDescriptor: WebSessionDescriptor {
        let providerTitle = "Override"
        let loginInstructions = "Log in with Override."
        let missingSessionMessage = "No session found."
        let loginURL = URL(string: "https://example.com/usage")!

        func shouldIncludeCookie(domain: String) -> Bool { false }
        var extractionScript: String { "0" }
        func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? { nil }
        func usageFetchScript(context: WebSessionFetchContext) -> String { "0" }
        func usageData(fromScriptResult scriptResultJSON: String) throws -> Data { Data(scriptResultJSON.utf8) }
        func accountLabel(fromCredential credential: String) -> String? { nil }
        func isAuthenticationFailure(scriptResultJSON: String) -> Bool { true }
    }
}
