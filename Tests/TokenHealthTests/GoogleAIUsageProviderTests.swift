import Foundation
import Testing
@testable import TokenHealth

/// Records what the provider actually put on the wire and answers with canned payloads, so the
/// whole fetch path — credential file, token refresh, both RPCs — runs without a network.
private actor StubTransport {
    struct Call: Sendable {
        var url: String
        var bearer: String?
        var body: String
        var userAgent: String?
    }

    private(set) var calls: [Call] = []
    /// The client ids and secrets the token endpoint will accept. Anything else is `invalid_client`,
    /// which is exactly how Google answers a mismatched Antigravity client.
    private var acceptedClients: Set<String> = []
    private var responses: [String: (status: Int, body: String)] = [:]

    func accept(clientID: String, secret: String, accessToken: String) {
        acceptedClients.insert("\(clientID)|\(secret)")
        responses["POST \(tokenEndpoint)"] = (
            200,
            #"{"access_token":"\#(accessToken)","expires_in":3600,"token_type":"Bearer"}"#
        )
    }

    func respond(to url: String, status: Int = 200, with body: String) {
        responses["POST \(url)"] = (status, body)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        calls.append(Call(
            url: url,
            bearer: request.value(forHTTPHeaderField: "Authorization"),
            body: body,
            userAgent: request.value(forHTTPHeaderField: "User-Agent")
        ))

        guard let canned = responses["POST \(url)"] else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        if url == tokenEndpoint {
            let fields = Self.formFields(body)
            let key = "\(fields["client_id"] ?? "")|\(fields["client_secret"] ?? "")"
            guard acceptedClients.contains(key) else {
                return (
                    Data(#"{"error":"invalid_client"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                )
            }
        }
        return (
            Data(canned.body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: nil, headerFields: nil)!
        )
    }

    private static func formFields(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            fields[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return fields
    }
}

private let tokenEndpoint = "https://oauth2.googleapis.com/token"
private let codeAssistEndpoint = "https://cloudcode-pa.googleapis.com"

struct GoogleAIUsageProviderTests {
    private let config = ServiceConfig(displayName: "Google AI", providerKind: .googleAI, authMode: .api)

    private var loadCodeAssist: String {
        #"""
        {
          "currentTier": { "id": "free-tier", "name": "Antigravity" },
          "paidTier": { "id": "g1-pro-tier", "name": "Google AI Pro" },
          "cloudaicompanionProject": "aicode-consumers"
        }
        """#
    }

    private var quotaSummary: String {
        #"""
        {
          "groups": [
            { "displayName": "Gemini Models", "buckets": [
                { "window": "weekly", "resetTime": "2026-10-23T07:03:07Z", "remainingFraction": 0.4 },
                { "window": "5h", "resetTime": "2026-10-16T12:03:07Z", "remainingFraction": 1 }
              ] },
            { "displayName": "Claude and GPT models", "buckets": [
                { "window": "weekly", "resetTime": "2026-10-23T07:03:07Z", "remainingFraction": 1 },
                { "window": "5h", "resetTime": "2026-10-16T12:03:07Z", "remainingFraction": 1 }
              ] }
          ]
        }
        """#
    }

    private var availableModels: String {
        #"""
        {
          "models": {
            "gemini-3.6-flash-high": {
              "displayName": "Gemini 3.6 Flash (High)",
              "quotaInfo": { "remainingFraction": 0.6, "resetTime": "2026-10-16T12:16:27Z" }
            },
            "claude-opus-5-5-high": {
              "displayName": "Claude Opus 5.5 (High)",
              "quotaInfo": { "remainingFraction": 0.2, "resetTime": "2026-10-16T12:16:27Z" }
            }
          }
        }
        """#
    }

    /// A token file plus an Antigravity binary carrying the two ids and two secrets, and a
    /// transport that accepts only the real pairing.
    ///
    /// The clock is pinned rather than left at `Date()`: the fixture's expiry is a fixed instant,
    /// so a test that reads the real clock flips from "fresh" to "expired" the moment the wall
    /// clock walks past it, and every assertion about the fresh path starts failing at 15:52.
    private func makeHarness(
        accessToken: String = "ya29.fresh",
        expiry: String = "2026-10-16T15:52:07.431752+08:00",
        now: Date? = ISO8601DateFormatter().date(from: "2026-10-16T07:00:00Z"),
        acceptClients: [(clientID: String, secret: String, accessToken: String)] = []
    ) async throws -> (provider: GoogleAIUsageProvider, transport: StubTransport, credentialURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let credentialURL = directory.appendingPathComponent("jetski-standalone-oauth-token")
        try Data(#"""
        {"token":{"access_token":"\#(accessToken)","refresh_token":"1//0e","expiry":"\#(expiry)"}}
        """#.utf8).write(to: credentialURL)

        let binaryURL = directory.appendingPathComponent("language_server")
        try Data(#"""
        ...runtime\#(GoogleAIFixtureCredentials.clientIDOne)[Auth...
        ...arena\#(GoogleAIFixtureCredentials.clientIDTwo)http:...
        ...authorize\#(GoogleAIFixtureCredentials.secretOne)https://cloudcode...
        ...\#(GoogleAIFixtureCredentials.secretTwo)decoding...
        """#.utf8).write(to: binaryURL)

        let transport = StubTransport()
        for client in acceptClients {
            await transport.accept(clientID: client.clientID, secret: client.secret, accessToken: client.accessToken)
        }
        let summary = quotaSummary
        let models = availableModels
        let codeAssist = loadCodeAssist
        await transport.respond(to: "\(codeAssistEndpoint)/v1internal:loadCodeAssist", with: codeAssist)
        await transport.respond(to: "\(codeAssistEndpoint)/v1internal:retrieveUserQuotaSummary", with: summary)
        await transport.respond(to: "\(codeAssistEndpoint)/v1internal:fetchAvailableModels", with: models)

        let clock = now ?? Date()
        let environment = GoogleAIUsageProvider.Environment(
            credentialFileURL: credentialURL,
            antigravityBinaryURL: binaryURL,
            tokenEndpoint: URL(string: tokenEndpoint)!,
            codeAssistEndpoint: URL(string: codeAssistEndpoint)!,
            userAgent: "antigravity/2.23.1",
            now: { clock },
            send: { try await transport.send($0) }
        )
        return (GoogleAIUsageProvider(environment: environment), transport, credentialURL)
    }

    @Test
    func aFreshTokenIsUsedWithoutAskingForANewOne() async throws {
        let harness = try await makeHarness()

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.state == .ready)
        let calls = await harness.transport.calls
        #expect(!calls.contains { $0.url == tokenEndpoint }, "the token was still fresh")
        #expect(calls.allSatisfy { $0.bearer == "Bearer ya29.fresh" })
    }

    @Test
    func anExpiredTokenIsRefreshedBeforeTheFirstCall() async throws {
        let harness = try await makeHarness(
            expiry: "2020-01-01T00:00:00Z",
            acceptClients: [(
                clientID: "\(GoogleAIFixtureCredentials.clientIDTwo)",
                secret: "\(GoogleAIFixtureCredentials.secretTwo)",
                accessToken: "ya29.renewed"
            )]
        )

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.state == .ready)
        let calls = await harness.transport.calls
        // The renewal has to land before the first RPC: every later call carries the new token.
        #expect(calls.contains { $0.url == tokenEndpoint })
        #expect(calls.allSatisfy { $0.url == tokenEndpoint || $0.bearer == "Bearer ya29.renewed" })
    }

    @Test
    func everyCandidateIsTriedUntilGoogleAcceptsOne() async throws {
        // The real pairing is the last of the four, so a scanner that stopped at the first
        // candidate — or that paired an id with the wrong secret — would never refresh.
        let harness = try await makeHarness(
            expiry: "2020-01-01T00:00:00Z",
            acceptClients: [(
                clientID: "\(GoogleAIFixtureCredentials.clientIDTwo)",
                secret: "\(GoogleAIFixtureCredentials.secretTwo)",
                accessToken: "ya29.renewed"
            )]
        )

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.state == .ready)
        let tokenCalls = await harness.transport.calls.filter { $0.url == tokenEndpoint }
        #expect(tokenCalls.count == 4, "all four id-and-secret pairings, the accepted one last")
    }

    @Test
    func everyCallIdentifiesAsAnAntigravityClient() async throws {
        // Not decoration: without a User-Agent naming Antigravity, `loadCodeAssist` answers with an
        // `UNSUPPORTED_CLIENT` tier and withholds the account's project, and every quota call after
        // it comes back 403 SUBSCRIPTION_REQUIRED.
        let harness = try await makeHarness()

        _ = await harness.provider.fetchUsage(config: config, secrets: .empty)

        let calls = await harness.transport.calls
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.userAgent?.lowercased().contains("antigravity") == true })
    }

    @Test
    func everyCallCarriesTheAntigravityVersion() async throws {
        // The backend reads the version off the User-Agent and trims what it sends back to a client
        // it does not recognise: an unversioned `antigravity` came back with 29 models where
        // `antigravity/2.23.1` came back with 35, and the daily host dropped a whole quota group.
        let harness = try await makeHarness()

        _ = await harness.provider.fetchUsage(config: config, secrets: .empty)

        let calls = await harness.transport.calls
        #expect(calls.allSatisfy { $0.userAgent == "antigravity/2.23.1" })
    }

    @Test
    func aMissingTokenFileAsksTheUserToLogIn() async throws {
        let harness = try await makeHarness()
        try FileManager.default.removeItem(at: harness.credentialURL)

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.state == .needsConfiguration)
        #expect(snapshot.statusMessage == "Log in with Antigravity")
    }

    @Test
    func aRefreshGoogleRefusesIsUnavailable() async throws {
        // No accepted client at all: every candidate comes back `invalid_client`.
        let harness = try await makeHarness(expiry: "2020-01-01T00:00:00Z")

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.usages.isEmpty)
    }

    @Test
    func aQuotaRpcThatFailsIsUnavailable() async throws {
        let harness = try await makeHarness()
        await harness.transport.respond(
            to: "\(codeAssistEndpoint)/v1internal:retrieveUserQuotaSummary",
            status: 500,
            with: "boom"
        )

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.state == .unavailable)
    }

    @Test
    func aModelCatalogueThatFailsOnlyCostsTheTable() async throws {
        let harness = try await makeHarness()
        await harness.transport.respond(
            to: "\(codeAssistEndpoint)/v1internal:fetchAvailableModels",
            status: 500,
            with: "boom"
        )

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.state == .ready)
        let detail = try #require(snapshot.detail)
        #expect(!detail.headline.isEmpty, "the quota rows are still there")
        #expect(detail.tables.isEmpty, "only the per-model table is missing")
    }

    // MARK: - the snapshot the fetch path builds

    @Test
    func aSummaryBecomesFourLabelledQuotaWindows() async throws {
        let harness = try await makeHarness()

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)

        #expect(snapshot.planName == "Google AI Pro")
        #expect(
            snapshot.usages.map(\.label) == [
                "Gemini Week", "Gemini 5h", "Claude & GPT Week", "Claude & GPT 5h"
            ]
        )
        #expect(snapshot.usages.map(\.used) == [60, 0, 0, 0])
    }

    @Test
    func theDetailCarriesTheQuotaRowsAndThePerModelTable() async throws {
        let harness = try await makeHarness()

        let snapshot = await harness.provider.fetchUsage(config: config, secrets: .empty)
        let detail = try #require(snapshot.detail)

        // The headline is the same four windows the menu bar draws bars for, so it comes back in
        // the display order rather than the order the summary happened to list them in.
        #expect(detail.headline.map(\.label) == ["Gemini 5h", "Gemini Week", "Claude & GPT 5h", "Claude & GPT Week"])
        #expect(
            Set(detail.headline.map(\.label)) == Set(snapshot.usages.map(\.label)),
            "headline 就是那四条额度，不该另解析一遍"
        )
        let table = try #require(detail.tables.first)
        #expect(table.title == "By model")
        #expect(table.rows.map(\.name) == ["Claude Opus 5.5 (High)", "Gemini 3.6 Flash (High)"])
        #expect(table.rows.first?.cells.first == "80%")
    }

    @Test
    func theHeadlineLabelsAreUniqueForThePopoversForEach() throws {
        // `DetailStat.id` is the label, so a repeated one breaks the popover's ForEach.
        let usage = stubSnapshotUsages()
        let detail = try #require(
            GoogleAIUsageDetail.make(summary: Data(quotaSummary.utf8), models: Data(availableModels.utf8), usages: usage)
        )

        #expect(Set(detail.headline.map(\.label)).count == detail.headline.count)
        for table in detail.tables {
            #expect(Set(table.rows.map(\.name)).count == table.rows.count)
        }
    }

    private func stubSnapshotUsages() -> [TokenUsage] {
        [
            TokenUsage(window: .week, label: "Gemini Week", used: 60, limit: 100, unit: "%"),
            TokenUsage(window: .fiveHours, label: "Gemini 5h", used: 0, limit: 100, unit: "%")
        ]
    }
}
