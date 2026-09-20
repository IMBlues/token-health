import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct KimiWebSessionDescriptorTests {
    private let descriptor = KimiWebSessionDescriptor()

    @Test
    func filtersCookiesByBothKimiDomains() {
        // Two domain families are accepted, matching the old controller's filter verbatim:
        // `domain.lowercased().contains("kimi") || domain.lowercased().contains("moonshot")`.
        // Matching is substring-based, so `evil-kimi.example.com` would also match.
        #expect(descriptor.shouldIncludeCookie(domain: "www.kimi.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "kimi.com"))
        #expect(descriptor.shouldIncludeCookie(domain: ".kimi.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "moonshot.cn"))
        #expect(descriptor.shouldIncludeCookie(domain: ".moonshot.cn"))
        #expect(descriptor.shouldIncludeCookie(domain: "MOONSHOT.CN"))
        #expect(!descriptor.shouldIncludeCookie(domain: "example.com"))
        #expect(!descriptor.shouldIncludeCookie(domain: "openai.com"))
    }

    @Test
    func buildsCredentialFromTheNestedTokenInfoString() {
        // The real page stores `volcano-token-info` as a JSON *string* inside the localStorage
        // dump, so this fixture reproduces that shape: the recursive helpers only resolve it by
        // re-parsing the embedded string. A plain nested object would pass this test while
        // covering none of that code.
        let extraction = #"{"href":"https://www.kimi.com/code/console","localStorage":{"access_token":"kimi-token-0123456789abcdef","plan_name":"Allegretto","volcano-token-info":"{\"userId\":\"traffic-1\",\"webId\":\"device-1\",\"ssid\":\"session-1\"}"},"sessionStorage":{}}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "theme=dark",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { KimiWebSessionCredential.decode(from: $0) }
        #expect(decoded?.accessToken == "kimi-token-0123456789abcdef")
        #expect(decoded?.cookieHeader == "theme=dark")
        #expect(decoded?.trafficID == "traffic-1")
        #expect(decoded?.deviceID == "device-1")
        #expect(decoded?.sessionID == "session-1")
        #expect(decoded?.planName == "Allegretto")
    }

    @Test
    func keepsATrafficIDOnlyExtraction() {
        // The pre-gate inside the moved `sessionCredential` nulls a wholly empty extraction but
        // must keep one that found no token yet does carry an embedded traffic id. Dropping the
        // traffic/device/session arms of that guard would lose the id here.
        let extraction = #"{"localStorage":{"volcano-token-info":"{\"userId\":\"traffic-1\"}"}}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "theme=dark",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { KimiWebSessionCredential.decode(from: $0) }
        #expect(decoded?.trafficID == "traffic-1")
        #expect(decoded?.accessToken == nil)
    }

    @Test
    func refusesAWhollyEmptyExtractionWithoutCookies() {
        let extraction = #"{"href":"https://www.kimi.com/code/console","localStorage":{},"sessionStorage":{}}"#
        #expect(descriptor.encodeCredential(extractionJSON: extraction, cookieHeader: nil, pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: extraction, cookieHeader: "", pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: "not json", cookieHeader: nil, pageTitle: nil) == nil)
    }

    @Test
    func importsOnCookieAlone() {
        // `isEmpty` is token-and-cookie: any matching cookie made the old controller import the
        // session, even when the storage extraction yielded nothing at all.
        let cookieOnly = descriptor.encodeCredential(
            extractionJSON: "not json",
            cookieHeader: "theme=dark",
            pageTitle: nil
        )

        #expect(KimiWebSessionCredential.decode(from: cookieOnly ?? "")?.cookieHeader == "theme=dark")
    }

    @Test
    func returnsTheTextBodyAsUsageData() throws {
        let envelope = #"{"ok":true,"status":200,"hasAccessToken":true,"text":"{\"usages\":[{\"scope\":\"FEATURE_CODING\"}]}"}"#
        let data = try descriptor.usageData(fromScriptResult: envelope)

        // The parser expects the site response body, not the script envelope (unlike DeepSeek and
        // OpenCode Go, which hand their parsers the whole envelope).
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["usages"] != nil)
        #expect(object?["text"] == nil)
    }

    @Test
    func rejectsAnEmptyTextBody() {
        expectInvalidResponse(#"{"ok":true,"status":200,"text":""}"#)
        expectInvalidResponse(#"{"ok":true,"status":200,"hasAccessToken":true}"#)
        expectInvalidResponse("not json")
    }

    @Test
    func hasNoAccountLabel() {
        // The credential carries no account identifier (only a plan name), so the label is always
        // nil and settings keeps showing "stored locally" for Kimi.
        var credential = KimiWebSessionCredential()
        credential.accessToken = "tok-1"
        credential.cookieHeader = "theme=dark"
        credential.planName = "Allegretto"
        #expect(descriptor.accountLabel(fromCredential: credential.encodedForStorage()) == nil)
        #expect(descriptor.accountLabel(fromCredential: "garbage") == nil)
    }

    @Test
    func exposesProviderCopy() {
        #expect(descriptor.providerTitle == "Kimi")
        #expect(descriptor.loginInstructions == "Log in with Kimi, wait for Console to load, then import.")
        #expect(descriptor.missingSessionMessage == "No session found. Make sure Kimi Console is logged in.")
        #expect(descriptor.loginURL.absoluteString == "https://www.kimi.com/code/console?from=kfc_overview_topbar")
        // The default origin is load-bearing: the usage script posts to a relative path, so the
        // headless page must stay on www.kimi.com.
        #expect(descriptor.originHost == "www.kimi.com")
        #expect(descriptor.originHost == descriptor.loginURL.host)
    }

    private func expectInvalidResponse(_ scriptResult: String) {
        do {
            _ = try descriptor.usageData(fromScriptResult: scriptResult)
            Issue.record("expected an invalidResponse error for \(scriptResult)")
        } catch WebSessionError.invalidResponse(let providerTitle) {
            #expect(providerTitle == "Kimi")
        } catch {
            Issue.record("unexpected error \(error) for \(scriptResult)")
        }
    }
}
