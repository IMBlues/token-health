import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct OpenCodeGoWebSessionDescriptorTests {
    private let descriptor = OpenCodeGoWebSessionDescriptor()

    @Test
    func filtersCookiesByOpenCodeDomain() {
        #expect(descriptor.shouldIncludeCookie(domain: "opencode.ai"))
        #expect(descriptor.shouldIncludeCookie(domain: "console.opencode.ai"))
        #expect(descriptor.shouldIncludeCookie(domain: ".opencode.ai"))
        // This provider matches on the exact domain or the ".opencode.ai" suffix, unlike the other
        // five, which use substring matching. A future refactor to `contains("opencode")` would
        // silently widen the predicate, so the lookalike domains below must stay rejected.
        #expect(!descriptor.shouldIncludeCookie(domain: "evil-opencode.ai"))
        #expect(!descriptor.shouldIncludeCookie(domain: "notopencode.ai"))
        #expect(!descriptor.shouldIncludeCookie(domain: "example.com"))
    }

    @Test
    func buildsCredentialFromExtractionResult() {
        let encoded = descriptor.encodeCredential(
            extractionJSON: #"{}"#,
            cookieHeader: "session=abc123; foo=bar",
            pageTitle: "Dashboard"
        )

        let decoded = encoded.flatMap { OpenCodeGoWebSessionCredential.decode(from: $0) }
        #expect(decoded?.cookieHeader == "session=abc123; foo=bar")
        #expect(decoded?.accountName == "Dashboard")
    }

    @Test
    func returnsNilWithoutCookie() {
        // The cookie is the whole credential — there is no access token — so an import with no
        // cookie must fail even when a page title is available.
        #expect(descriptor.encodeCredential(extractionJSON: #"{}"#, cookieHeader: nil, pageTitle: "Dashboard") == nil)
        #expect(descriptor.encodeCredential(extractionJSON: #"{}"#, cookieHeader: "", pageTitle: "Dashboard") == nil)
    }

    @Test
    func returnsWholeEnvelopeAsUsageData() throws {
        let envelope = #"{"ok":true,"status":200,"text":"","hasSession":true,"goStatus":{"subscriptionStatus":"active"},"session":{"user":{"id":"u1"}}}"#
        let data = try descriptor.usageData(fromScriptResult: envelope)

        // The parser normalizes the envelope itself, so it must receive the whole script result,
        // not just the envelope's `text` body (which is empty on success).
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["goStatus"] != nil)
        #expect(object?["session"] != nil)
    }

    @Test
    func decodesAccountLabelFromCredential() {
        var credential = OpenCodeGoWebSessionCredential()
        credential.cookieHeader = "session=abc123"
        credential.accountName = "user@example.com"
        #expect(descriptor.accountLabel(fromCredential: credential.encodedForStorage()) == "user@example.com")

        var unnamed = OpenCodeGoWebSessionCredential()
        unnamed.cookieHeader = "session=abc123"
        #expect(descriptor.accountLabel(fromCredential: unnamed.encodedForStorage()) == nil)
        #expect(descriptor.accountLabel(fromCredential: "garbage") == nil)
    }

    @Test
    func usageScriptCoversTheConsoleEndpoints() {
        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9))

        for path in ["/api/me/orgs", "/api/go/status", "/api/usage/summary", "/api/usage/cost-by-day", "/api/usage/models"] {
            #expect(script.contains(path), "脚本少打了 \(path)")
        }
        #expect(script.contains("x-org-id"))
        #expect(script.contains("usageSummary"))
        #expect(script.contains("usageByDay"))
        #expect(script.contains("usageModels"))
        // ok/status/text must keep describing the go/status request alone: the kernel throws on
        // ok == false, so a failed usage call must not be able to fail the whole refresh.
        #expect(script.contains("ok: !failed"))
        // A 2xx whose body is not JSON (an expired session redirected to an HTML page) must fail
        // the fetch, not read as "not subscribed".
        #expect(script.contains("status.json !== null"))
        // When no probe ran (the workspace list itself failed), the orgs request's 401/403 must
        // survive into the envelope so the kernel still maps an expired session — a synthetic 400
        // would read as a plain error.
        #expect(script.contains("orgsFailed"))
    }

    @Test
    func exposesProviderCopy() {
        #expect(descriptor.providerTitle == "OpenCode Go")
        #expect(descriptor.loginInstructions == "Log in with GitHub or Google at opencode.ai/auth, wait for the console to load, then import.")
        #expect(descriptor.missingSessionMessage == "No session found. Make sure the OpenCode console is logged in.")
        // The literal pins the default origin: the usage script requests relative paths, so the
        // headless page must stay on console.opencode.ai.
        #expect(descriptor.originHost == "console.opencode.ai")
        #expect(descriptor.originHost == descriptor.loginURL.host)
    }
}
