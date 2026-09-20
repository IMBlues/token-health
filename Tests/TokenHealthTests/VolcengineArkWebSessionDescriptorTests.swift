import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct VolcengineArkWebSessionDescriptorTests {
    private let descriptor = VolcengineArkWebSessionDescriptor()

    @Test
    func filtersCookiesByVolcengineDomain() {
        #expect(descriptor.shouldIncludeCookie(domain: "console.volcengine.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "volcengine.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "VOLCENGINE.COM"))
        // Substring matching, carried over verbatim from the old controller's isVolcengineCookie.
        #expect(!descriptor.shouldIncludeCookie(domain: "example.com"))
    }

    @Test
    func buildsCredentialFromExtractionResult() {
        let extraction = #"{"href":"https://console.volcengine.com/ark/region:cn-beijing/subscription/agent-plan","csrfToken":"csrf-1","accountName":"me@example.com"}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "csrfToken=csrf-2; other=1",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { VolcengineArkWebSessionCredential.decode(from: $0) }
        #expect(decoded?.cookieHeader == "csrfToken=csrf-2; other=1")
        #expect(decoded?.csrfToken == "csrf-1")
        #expect(decoded?.accountName == "me@example.com")
    }

    @Test
    func emptyExtractionCSRFWinsOverTheCookieHeader() {
        // The extraction script yields "" (not null) when the csrf cookie is missing, and the old
        // controller's `csrfToken ?? cookieCSRF` let "" beat the cookie-store value. The kernel
        // hands over a joined header instead of the cookie store, so the `??` order must hold:
        // "" from the extraction beats the header's value. Reversing it, or treating "" as absent,
        // would silently prefer the header.
        let extraction = #"{"csrfToken":"","accountName":"me@example.com"}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "csrfToken=from-header; other=1",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { VolcengineArkWebSessionCredential.decode(from: $0) }
        #expect(decoded?.csrfToken == "")
    }

    @Test
    func importsOnCookiesAloneWhenExtractionJSONIsMalformed() {
        // The old controller imported whenever cookies existed, even when the storage extraction
        // returned nothing parseable. Unlike DeepSeek's descriptor, this one must not return nil
        // for non-JSON.
        let encoded = descriptor.encodeCredential(
            extractionJSON: "not json",
            cookieHeader: "csrfToken=from-header; other=1",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { VolcengineArkWebSessionCredential.decode(from: $0) }
        #expect(decoded != nil)
        #expect(decoded?.cookieHeader == "csrfToken=from-header; other=1")
        // With no extraction value, the named cookie is pulled out of the joined header.
        #expect(decoded?.csrfToken == "from-header")
    }

    @Test
    func returnsNilWithoutCookies() {
        // `isEmpty` is cookie-only by design: the credential authenticates through the cookie
        // header, so a csrf token alone is not an importable session.
        let extraction = #"{"csrfToken":"csrf-1","accountName":"me@example.com"}"#
        #expect(descriptor.encodeCredential(extractionJSON: extraction, cookieHeader: nil, pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: extraction, cookieHeader: "", pageTitle: nil) == nil)
    }

    @Test
    func matchesTheCSRFCookieByItsFullNameOnly() {
        // The protocol's named-cookie rule: match before the first "=", never on a prefix, so a
        // "csrfTokenV2" decoy cannot satisfy a lookup for "csrfToken".
        let encoded = descriptor.encodeCredential(
            extractionJSON: "not json",
            cookieHeader: "csrfTokenV2=decoy; csrfToken=real",
            pageTitle: nil
        )

        #expect(VolcengineArkWebSessionCredential.decode(from: encoded ?? "")?.csrfToken == "real")
    }

    @Test
    func mapsTheChinesePageTitleToAgentPlan() {
        // 火山方舟 is the console's Chinese page title; the old controller mapped it to "Agent Plan".
        let encoded = descriptor.encodeCredential(
            extractionJSON: #"{"csrfToken":"csrf-1"}"#,
            cookieHeader: "csrfToken=csrf-1",
            pageTitle: "火山方舟"
        )

        #expect(VolcengineArkWebSessionCredential.decode(from: encoded ?? "")?.accountName == "Agent Plan")
    }

    @Test
    func returnsTextBodyAsUsageData() throws {
        let envelope = #"{"ok":true,"status":200,"hasCSRF":true,"text":"{\"Result\":{\"AFPWeekly\":{\"Used\":12,\"Quota\":100}}}"}"#
        let data = try descriptor.usageData(fromScriptResult: envelope)

        // The parser expects the raw API body, not the script envelope (which is what DeepSeek and
        // OpenCode Go hand their parsers).
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["Result"] != nil)
        #expect(object?["text"] == nil)
    }

    @Test
    func rejectsAnEmptyTextBody() {
        expectInvalidResponse(#"{"ok":true,"status":200,"text":""}"#)
        expectInvalidResponse(#"{"ok":true,"status":200,"hasCSRF":true}"#)
        expectInvalidResponse("not json")
    }

    @Test
    func decodesAccountLabelFromCredential() {
        var credential = VolcengineArkWebSessionCredential()
        credential.cookieHeader = "csrfToken=csrf-1"
        credential.accountName = "me@example.com"
        #expect(descriptor.accountLabel(fromCredential: credential.encodedForStorage()) == "me@example.com")

        var unnamed = VolcengineArkWebSessionCredential()
        unnamed.cookieHeader = "csrfToken=csrf-1"
        #expect(descriptor.accountLabel(fromCredential: unnamed.encodedForStorage()) == nil)

        unnamed.accountName = ""
        #expect(descriptor.accountLabel(fromCredential: unnamed.encodedForStorage()) == nil)
        #expect(descriptor.accountLabel(fromCredential: "garbage") == nil)
    }

    @Test
    func exposesProviderCopy() {
        #expect(descriptor.providerTitle == "Volcengine Ark")
        #expect(descriptor.loginInstructions == "Log in with Volcengine Ark, wait for Agent Plan to load, then import.")
        #expect(descriptor.missingSessionMessage == "No session found. Make sure Volcengine Ark is logged in.")
        #expect(descriptor.loginURL.absoluteString == "https://console.volcengine.com/ark/region:cn-beijing/subscription/agent-plan")
        #expect(descriptor.originHost == descriptor.loginURL.host)
    }

    private func expectInvalidResponse(_ scriptResult: String) {
        do {
            _ = try descriptor.usageData(fromScriptResult: scriptResult)
            Issue.record("expected an invalidResponse error for \(scriptResult)")
        } catch WebSessionError.invalidResponse(let providerTitle) {
            #expect(providerTitle == "Volcengine Ark")
        } catch {
            Issue.record("unexpected error \(error) for \(scriptResult)")
        }
    }
}
