import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct ZhipuWebSessionDescriptorTests {
    private let descriptor = ZhipuWebSessionDescriptor()

    @Test
    func filtersCookiesByBigmodelDomain() {
        #expect(descriptor.shouldIncludeCookie(domain: "bigmodel.cn"))
        #expect(descriptor.shouldIncludeCookie(domain: "open.bigmodel.cn"))
        #expect(descriptor.shouldIncludeCookie(domain: "BIGMODEL.CN"))
        // Substring matching, carried over verbatim from the old controller's cookie filter.
        #expect(!descriptor.shouldIncludeCookie(domain: "example.com"))
    }

    @Test
    func buildsCredentialFromExtractionResult() {
        let extraction = #"{"href":"https://bigmodel.cn/coding-plan/team/usage-stats","organizationID":"org-1","projectID":"proj-1"}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "bigmodel_token_production=tok-1; theme=dark",
            pageTitle: "GLM Coding Plan"
        )

        let decoded = encoded.flatMap { ZhipuWebSessionCredential.decode(from: $0) }
        #expect(decoded?.accessToken == "tok-1")
        #expect(decoded?.cookieHeader == "bigmodel_token_production=tok-1; theme=dark")
        #expect(decoded?.organizationID == "org-1")
        #expect(decoded?.projectID == "proj-1")
        // The extractor finds nothing in the extraction object (its keys are only href/id fields),
        // so the plan name comes from the page title.
        #expect(decoded?.planName == "GLM Coding Plan")
    }

    @Test
    func keepsTheRawCookieValueUnDecoded() {
        // The old Swift import stored `WKHTTPCookie.value` undecoded — only the usage script does
        // `decodeURIComponent` — so a percent-encoded value must be stored verbatim. Everything
        // after the first "=" is the value, because cookie values may contain "=".
        let encoded = descriptor.encodeCredential(
            extractionJSON: #"{"organizationID":"org-1"}"#,
            cookieHeader: "bigmodel_token_production=a%2Fb%3Dc=tail; theme=dark",
            pageTitle: nil
        )

        #expect(ZhipuWebSessionCredential.decode(from: encoded ?? "")?.accessToken == "a%2Fb%3Dc=tail")
    }

    @Test
    func matchesTheTokenCookieByItsFullNameOnly() {
        // The protocol's named-cookie rule: match the whole name before the first "=", never a
        // prefix, so a "bigmodel_token_production_v2" decoy cannot satisfy the lookup.
        let encoded = descriptor.encodeCredential(
            extractionJSON: #"{"organizationID":"org-1"}"#,
            cookieHeader: "bigmodel_token_production_v2=decoy; bigmodel_token_production=real",
            pageTitle: nil
        )

        #expect(ZhipuWebSessionCredential.decode(from: encoded ?? "")?.accessToken == "real")
    }

    @Test
    func hasNoAccessTokenWithoutTheNamedCookie() {
        let encoded = descriptor.encodeCredential(
            extractionJSON: #"{"organizationID":"org-1"}"#,
            cookieHeader: "theme=dark",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { ZhipuWebSessionCredential.decode(from: $0) }
        #expect(decoded?.accessToken == nil)
        #expect(decoded?.cookieHeader == "theme=dark")
    }

    @Test
    func importsOnTokenOrCookieAlone() {
        // `isEmpty` is token-and-cookie, so the credential is empty only when both are missing —
        // any matching cookie made the old controller import the session.
        #expect(descriptor.encodeCredential(extractionJSON: #"{"organizationID":"org-1"}"#, cookieHeader: nil, pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: #"{"organizationID":"org-1"}"#, cookieHeader: "", pageTitle: nil) == nil)

        let tokenOnly = descriptor.encodeCredential(
            extractionJSON: #"{"organizationID":"org-1"}"#,
            cookieHeader: "bigmodel_token_production=tok-1",
            pageTitle: nil
        )
        #expect(ZhipuWebSessionCredential.decode(from: tokenOnly ?? "")?.accessToken == "tok-1")

        let cookieOnly = descriptor.encodeCredential(
            extractionJSON: #"{"organizationID":"org-1"}"#,
            cookieHeader: "theme=dark",
            pageTitle: nil
        )
        #expect(ZhipuWebSessionCredential.decode(from: cookieOnly ?? "")?.cookieHeader == "theme=dark")
    }

    @Test
    func importsOnCookiesAloneWhenTheExtractionProducedNothing() {
        // The kernel passes "" as the extraction result when the page's script did not run, and the
        // old controller's `storageCredential ?? ZhipuWebSessionCredential()` fell through to a
        // cookie-only credential. A non-JSON (or empty) extraction must therefore still import
        // whenever cookies exist, exactly as Volcengine Ark already does.
        let malformed = descriptor.encodeCredential(
            extractionJSON: "not json",
            cookieHeader: "theme=dark",
            pageTitle: nil
        )
        #expect(ZhipuWebSessionCredential.decode(from: malformed ?? "")?.cookieHeader == "theme=dark")

        let noScript = descriptor.encodeCredential(
            extractionJSON: "",
            cookieHeader: "theme=dark",
            pageTitle: nil
        )
        #expect(ZhipuWebSessionCredential.decode(from: noScript ?? "")?.cookieHeader == "theme=dark")

        // A wholly empty input — no cookies and no extraction — still returns nil.
        #expect(descriptor.encodeCredential(extractionJSON: "not json", cookieHeader: nil, pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: "not json", cookieHeader: "", pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: "", cookieHeader: nil, pageTitle: nil) == nil)
    }

    @Test
    func dropsTheGenericPlatformTitle() {
        // 智谱AI开放平台 is the platform's generic page title; the old controller filtered it out.
        // The literal is data, not a comment.
        let generic = descriptor.encodeCredential(
            extractionJSON: #"{"organizationID":"org-1"}"#,
            cookieHeader: "bigmodel_token_production=tok-1",
            pageTitle: "智谱AI开放平台"
        )
        #expect(ZhipuWebSessionCredential.decode(from: generic ?? "")?.planName == nil)

        let titled = descriptor.encodeCredential(
            extractionJSON: #"{"organizationID":"org-1"}"#,
            cookieHeader: "bigmodel_token_production=tok-1",
            pageTitle: "GLM Coding Plan"
        )
        #expect(ZhipuWebSessionCredential.decode(from: titled ?? "")?.planName == "GLM Coding Plan")
    }

    @Test
    func returnsTextBodyAsUsageData() throws {
        let envelope = #"{"ok":true,"status":200,"hasAccessToken":true,"text":"{\"code\":200,\"data\":{\"limits\":[{\"type\":\"TOKENS_LIMIT\"}]}}"}"#
        let data = try descriptor.usageData(fromScriptResult: envelope)

        // The parser expects the site response body, not the script envelope (unlike DeepSeek and
        // OpenCode Go, which hand their parsers the whole envelope).
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["code"] != nil)
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
        // The credential carries a plan name, not an account name: two Zhipu accounts on the same
        // plan would show the same label, which misleads rather than identifies.
        var credential = ZhipuWebSessionCredential()
        credential.accessToken = "tok-1"
        credential.cookieHeader = "bigmodel_token_production=tok-1"
        credential.planName = "GLM Coding Plan"
        #expect(descriptor.accountLabel(fromCredential: credential.encodedForStorage()) == nil)
        #expect(descriptor.accountLabel(fromCredential: "garbage") == nil)
    }

    @Test
    func exposesProviderCopy() {
        #expect(descriptor.providerTitle == "Zhipu")
        #expect(descriptor.loginInstructions == "Log in with Zhipu, wait for usage stats to load, then import.")
        #expect(descriptor.missingSessionMessage == "No session found. Make sure Zhipu is logged in.")
        #expect(descriptor.loginURL.absoluteString == "https://bigmodel.cn/coding-plan/team/usage-stats")
        // The literal pins the default: the login page, usage endpoint and native endpoints all
        // share this host, so a future override would break the headless WebView's origin check.
        #expect(descriptor.originHost == "bigmodel.cn")
        #expect(descriptor.originHost == descriptor.loginURL.host)
    }

    private func expectInvalidResponse(_ scriptResult: String) {
        do {
            _ = try descriptor.usageData(fromScriptResult: scriptResult)
            Issue.record("expected an invalidResponse error for \(scriptResult)")
        } catch WebSessionError.invalidResponse(let providerTitle) {
            #expect(providerTitle == "Zhipu")
        } catch {
            Issue.record("unexpected error \(error) for \(scriptResult)")
        }
    }
}
