import Foundation
import JavaScriptCore
import Testing
@testable import TokenHealth

/// Behavioural harness for `OpenCodeGoWebSessionDescriptor.usageFetchScript`: the string checks in
/// `OpenCodeGoWebSessionDescriptorTests` cannot catch a syntax error or a drift in the probe
/// policy, so this suite evaluates the shipped script in JavaScriptCore against a mocked
/// `XMLHttpRequest` and asserts on the returned envelope and the recorded requests.
@Suite
@MainActor
struct OpenCodeGoWebSessionScriptTests {
    private let descriptor = OpenCodeGoWebSessionDescriptor()

    /// The envelope always carries exactly these keys (absent and explicit null are equivalent to
    /// the consumers, but the script emits all of them).
    private static let envelopeKeys: Set<String> = [
        "ok", "status", "text", "hasSession", "goStatus", "session",
        "orgs", "workspaceId", "usageSummary", "usageByDay", "usageModels"
    ]

    /// A canned response for the mock. `throwsOnSend` simulates a `xhr.send()` that throws
    /// (offline, blocked) instead of completing.
    private struct MockResponse {
        var status: Int
        var body: String
        var throwsOnSend: String?

        init(status: Int, body: String, throwsOnSend: String? = nil) {
            self.status = status
            self.body = body
            self.throwsOnSend = throwsOnSend
        }
    }

    private struct Run {
        var raw: String
        var envelope: [String: Any]
        /// One entry per request the script made: its path and the `x-org-id` header it carried
        /// (nil when the header was not sent).
        var requests: [(path: String, orgId: String?)]
    }

    private enum HarnessError: Error {
        case javaScriptException(String)
        case scriptReturnedNoString
        case envelopeWasNotAnObject(String)
    }

    /// Responses are keyed by `path + "\n" + (x-org-id or "")`; an unkeyed request gets a 404 so a
    /// forgotten route fails the assertions instead of silently succeeding.
    private static let prelude = #"""
    globalThis.__requests = [];
    globalThis.__responses = {};
    globalThis.XMLHttpRequest = class {
      open(method, path) {
        this.__path = path;
        this.__headers = {};
      }
      setRequestHeader(name, value) {
        this.__headers[String(name).toLowerCase()] = String(value);
      }
      send() {
        const orgId = this.__headers['x-org-id'] || '';
        const response = globalThis.__responses[this.__path + '\n' + orgId] || { status: 404, body: '' };
        globalThis.__requests.push({ path: this.__path, orgId: orgId || null });
        if (response.throws) {
          throw new Error(response.throws);
        }
        this.status = response.status;
        this.responseText = response.body;
      }
    };
    """#

    private func runScript(responses: [String: MockResponse]) throws -> Run {
        let table: [String: [String: Any]] = responses.mapValues { response in
            var value: [String: Any] = ["status": response.status, "body": response.body]
            if let throwsOnSend = response.throwsOnSend {
                value["throws"] = throwsOnSend
            }
            return value
        }
        let tableJSON = String(decoding: try JSONSerialization.data(withJSONObject: table), as: UTF8.self)

        let context = try #require(JSContext(), "JavaScriptCore context should be available")
        context.evaluateScript(Self.prelude)
        context.evaluateScript("globalThis.__responses = \(tableJSON);")

        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9))
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            throw HarnessError.javaScriptException(String(describing: exception))
        }
        guard let raw = value?.toString(), value?.isString == true else {
            throw HarnessError.scriptReturnedNoString
        }
        guard let envelopeData = raw.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any] else {
            throw HarnessError.envelopeWasNotAnObject(raw)
        }

        let requests = (context.objectForKeyedSubscript("__requests")?.toArray() ?? [])
            .compactMap { element -> (path: String, orgId: String?)? in
                guard let object = element as? [String: Any], let path = object["path"] as? String else {
                    return nil
                }
                return (path, object["orgId"] as? String)
            }

        return Run(raw: raw, envelope: envelope, requests: requests)
    }

    @Test
    func emitsTheEnvelopeAndPicksTheWorkspaceWithAccess() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: #"[{"id":"w1"},{"id":"w2"}]"#),
            "/api/go/status\nw1": MockResponse(status: 200, body: #"{"subscriptionStatus":"inactive"}"#),
            "/api/go/status\nw2": MockResponse(status: 200, body: #"{"access":{"meters":{"week":{"limitMicroCents":1}}}}"#),
            "/api/usage/summary?range=30d\nw2": MockResponse(status: 200, body: #"{"totalMicroCents":5}"#),
            "/api/usage/cost-by-day?range=30d&bucket=day\nw2": MockResponse(status: 200, body: #"[{"day":"2026-09-01"}]"#),
            "/api/usage/models?range=30d&pageSize=100&costOrder=desc\nw2": MockResponse(status: 200, body: #"[{"model":"m"}]"#),
        ])

        #expect(Set(run.envelope.keys) == Self.envelopeKeys)
        #expect(run.envelope["ok"] as? Bool == true)
        #expect(run.envelope["status"] as? Int == 200)
        #expect(run.envelope["text"] as? String == "")
        #expect(run.envelope["hasSession"] as? Bool == true)
        #expect(run.envelope["workspaceId"] as? String == "w2")
        #expect((run.envelope["usageSummary"] as? [String: Any])?["totalMicroCents"] as? Int == 5)
        #expect(run.envelope["usageByDay"] is [Any])
        #expect(run.envelope["usageModels"] is [Any])

        // Both probes ran in order, each scoped to its own workspace; the first workspace's
        // "inactive" response was not adopted because the second has access.
        let probes = run.requests.filter { $0.path == "/api/go/status" }
        #expect(probes.map(\.orgId) == ["w1", "w2"])

        // The session and workspace-list requests are unscoped.
        let sessionRequest = try #require(run.requests.first { $0.path == "/auth/session" })
        #expect(sessionRequest.orgId == nil)
        let orgsRequest = try #require(run.requests.first { $0.path == "/api/me/orgs" })
        #expect(orgsRequest.orgId == nil)

        // The usage calls go to the chosen workspace.
        let usageRequests = run.requests.filter { $0.path.hasPrefix("/api/usage/") }
        #expect(usageRequests.count == 3)
        #expect(usageRequests.allSatisfy { $0.orgId == "w2" })
    }

    @Test
    func aFailedUsageCallOnlyDropsItsOwnKey() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: #"[{"id":"w1"}]"#),
            "/api/go/status\nw1": MockResponse(status: 200, body: #"{"access":{"meters":{}}}"#),
            "/api/usage/summary?range=30d\nw1": MockResponse(status: 500, body: "boom"),
            "/api/usage/cost-by-day?range=30d&bucket=day\nw1": MockResponse(status: 500, body: "boom"),
            "/api/usage/models?range=30d&pageSize=100&costOrder=desc\nw1": MockResponse(status: 500, body: "boom"),
        ])

        // The kernel throws on ok == false, so a failed usage call must not flip it.
        #expect(run.envelope["ok"] as? Bool == true)
        #expect(run.envelope["status"] as? Int == 200)
        #expect(run.envelope["text"] as? String == "")
        #expect(run.envelope["goStatus"] is [String: Any])
        #expect(run.envelope["usageSummary"] is NSNull)
        #expect(run.envelope["usageByDay"] is NSNull)
        #expect(run.envelope["usageModels"] is NSNull)
    }

    @Test
    func a2xxStatusBodyThatIsNotJSONFailsTheFetch() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: #"[{"id":"w1"}]"#),
            "/api/go/status\nw1": MockResponse(status: 200, body: "<html>login</html>"),
        ])

        // An expired session redirected to an HTML page must not read as "not subscribed", so the
        // synthetic copy wins over the (unparseable) body.
        #expect(run.envelope["ok"] as? Bool == false)
        #expect(run.envelope["status"] as? Int == 200)
        #expect(run.envelope["text"] as? String == "OpenCode Go status response was not JSON")
        #expect(run.envelope["goStatus"] is NSNull)
    }

    @Test
    func a2xxArrayStatusBodyIsNotTreatedAsASubscription() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: #"[{"id":"w1"}]"#),
            "/api/go/status\nw1": MockResponse(status: 200, body: "[]"),
        ])

        // `[]` is valid JSON but not a status object; the parser would read it as "not subscribed".
        #expect(run.envelope["ok"] as? Bool == false)
        #expect(run.envelope["status"] as? Int == 200)
        #expect(run.envelope["text"] as? String == "OpenCode Go status response was not JSON")
    }

    @Test
    func anOfflineOrgsRequestReportsItsOwnFailure() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 0, body: ""),
        ])

        // A transport failure is not "no workspace": the orgs request's own status and copy must
        // survive so the message is not a misdiagnosis.
        #expect(run.envelope["ok"] as? Bool == false)
        #expect(run.envelope["status"] as? Int == 0)
        #expect(run.envelope["text"] as? String == "OpenCode Go workspace list failed")
        #expect(!run.requests.contains { $0.path == "/api/go/status" })
    }

    @Test
    func anOrgsAuthFailureKeepsThe401ForSessionExpiry() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 401, body: ""),
            "/api/me/orgs\n": MockResponse(status: 401, body: "<html>login</html>"),
        ])

        // No probe ran, so this is the only place the expired-session signal can come from: the
        // kernel maps 401/403 to WebSessionError.sessionExpired.
        #expect(run.envelope["ok"] as? Bool == false)
        #expect(run.envelope["status"] as? Int == 401)
        #expect(run.envelope["text"] as? String == "<html>login</html>")
        #expect(descriptor.isAuthenticationFailure(scriptResultJSON: run.raw))
    }

    @Test
    func anEmptyWorkspaceListIsAPlain400() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: "[]"),
        ])

        #expect(run.envelope["ok"] as? Bool == false)
        #expect(run.envelope["status"] as? Int == 400)
        #expect(run.envelope["text"] as? String == "OpenCode Go has no workspace")
        #expect(run.envelope["workspaceId"] is NSNull)
        #expect(!descriptor.isAuthenticationFailure(scriptResultJSON: run.raw))
    }

    @Test
    func nonStringWorkspaceIDsAreIgnored() throws {
        // The numeric id comes first: an unfiltered map would probe it (and record a "42"
        // x-org-id) before reaching the real workspace.
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: #"[{"id":42},{"id":"w1"},{"name":"x"}]"#),
            "/api/go/status\nw1": MockResponse(status: 200, body: #"{"access":{"meters":{}}}"#),
            "/api/usage/summary?range=30d\nw1": MockResponse(status: 200, body: "{}"),
            "/api/usage/cost-by-day?range=30d&bucket=day\nw1": MockResponse(status: 200, body: "{}"),
            "/api/usage/models?range=30d&pageSize=100&costOrder=desc\nw1": MockResponse(status: 200, body: "{}"),
        ])

        // The native `workspaceIDs(fromOrgs:)` only accepts strings; a numeric id must not become
        // an x-org-id header or a non-string `workspaceId`.
        #expect(run.envelope["workspaceId"] as? String == "w1")
        #expect(run.requests.filter { $0.path == "/api/go/status" }.map(\.orgId) == ["w1"])
    }

    @Test
    func probesAtMostTheWorkspaceProbeLimit() throws {
        // Seven workspaces, none with access: the script must probe exactly the provider's
        // workspaceProbeLimit, so the cap stops being linked by comment alone. The extra ids were
        // given responses too — a drift in the slice would record them and fail the assertions.
        var responses: [String: MockResponse] = [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(
                status: 200,
                body: #"[{"id":"w1"},{"id":"w2"},{"id":"w3"},{"id":"w4"},{"id":"w5"},{"id":"w6"},{"id":"w7"}]"#
            ),
        ]
        for index in 1...7 {
            responses["/api/go/status\nw\(index)"] = MockResponse(status: 200, body: #"{"subscriptionStatus":"inactive"}"#)
        }
        let run = try runScript(responses: responses)

        let probes = run.requests.filter { $0.path == "/api/go/status" }
        #expect(probes.count == OpenCodeGoUsageProvider.workspaceProbeLimit)
        #expect(probes.map(\.orgId) == ["w1", "w2", "w3", "w4", "w5"])

        // No access anywhere: the first attempt stays as the fallback, so "not subscribed" reads
        // through with the first workspace.
        #expect(run.envelope["workspaceId"] as? String == "w1")
        #expect(run.envelope["ok"] as? Bool == true)
    }

    @Test
    func probingStopsAtTheFirstWorkspaceWithAccess() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: #"[{"id":"w1"},{"id":"w2"},{"id":"w3"}]"#),
            "/api/go/status\nw1": MockResponse(status: 200, body: #"{"subscriptionStatus":"inactive"}"#),
            "/api/go/status\nw2": MockResponse(status: 200, body: #"{"access":{"meters":{}}}"#),
        ])

        // The break at the first workspace with access must stop the loop: w3 is never probed.
        #expect(run.requests.filter { $0.path == "/api/go/status" }.map(\.orgId) == ["w1", "w2"])
        #expect(run.envelope["workspaceId"] as? String == "w2")
    }

    @Test
    func aThrowingSendDegradesToAFailedProbe() throws {
        let run = try runScript(responses: [
            "/auth/session\n": MockResponse(status: 200, body: #"{"user":{"id":"u1"}}"#),
            "/api/me/orgs\n": MockResponse(status: 200, body: #"[{"id":"w1"},{"id":"w2"}]"#),
            "/api/go/status\nw1": MockResponse(status: 0, body: "", throwsOnSend: "network dropped"),
            "/api/go/status\nw2": MockResponse(status: 200, body: #"{"access":{"meters":{}}}"#),
            "/api/usage/summary?range=30d\nw2": MockResponse(status: 200, body: "{}"),
            "/api/usage/cost-by-day?range=30d&bucket=day\nw2": MockResponse(status: 200, body: "{}"),
            "/api/usage/models?range=30d&pageSize=100&costOrder=desc\nw2": MockResponse(status: 200, body: "{}"),
        ])

        // One bad request must not abort the whole script; the probe is recorded as a failed
        // attempt and probing continues to the next workspace.
        #expect(run.envelope["ok"] as? Bool == true)
        #expect(run.envelope["workspaceId"] as? String == "w2")
        #expect(run.requests.filter { $0.path == "/api/go/status" }.map(\.orgId) == ["w1", "w2"])
    }
}
