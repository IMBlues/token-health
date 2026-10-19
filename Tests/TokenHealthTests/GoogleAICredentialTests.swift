import Foundation
import Testing
@testable import TokenHealth

struct GoogleAICredentialTests {
    /// The shape Antigravity writes to `~/.gemini/jetski-standalone-oauth-token`.
    private var antigravityTokenFile: Data {
        Data(#"""
        {
          "token": {
            "access_token": "ya29.a0AX07EXAMPLE",
            "token_type": "Bearer",
            "refresh_token": "1//0eEXAMPLE",
            "expiry": "2026-10-16T15:52:07.431752+08:00"
          },
          "auth_method": "consumer",
          "id_token": "eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJleGFtcGxlIn0.signature"
        }
        """#.utf8)
    }

    @Test
    func anAntigravityTokenFileDecodes() throws {
        let credential = try #require(GoogleAICredential.decode(from: antigravityTokenFile))

        #expect(credential.accessToken == "ya29.a0AX07EXAMPLE")
        #expect(credential.refreshToken == "1//0eEXAMPLE")
    }

    @Test
    func theExpiryIsReadIncludingItsOffset() throws {
        let credential = try #require(GoogleAICredential.decode(from: antigravityTokenFile))
        let utc = try #require(ISO8601DateFormatter().date(from: "2026-10-16T07:52:07Z"))

        // 15:52 at +08:00 is 07:52 UTC. Reading it as a floating local time would put the expiry
        // eight hours out and the app would keep sending a dead token. The tolerance is only for
        // the fractional second the two parses round differently.
        let expiry = try #require(credential.expiry)
        #expect(abs(expiry.timeIntervalSince(utc)) < 1)
    }

    @Test
    func aFileWithoutAnAccessTokenIsNotACredential() {
        let json = Data(#"{"token":{"refresh_token":"1//0e"}}"#.utf8)

        #expect(GoogleAICredential.decode(from: json) == nil)
    }

    @Test
    func aFileThatIsNotJSONIsNotACredential() {
        #expect(GoogleAICredential.decode(from: Data("not json".utf8)) == nil)
    }

    @Test
    func aCredentialWellInsideItsLifetimeIsFresh() throws {
        let credential = try #require(GoogleAICredential.decode(from: antigravityTokenFile))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-16T07:00:00Z"))

        #expect(credential.isFresh(now: now))
    }

    @Test
    func aCredentialAboutToExpireIsNotFresh() throws {
        let credential = try #require(GoogleAICredential.decode(from: antigravityTokenFile))
        // One minute before the expiry, inside the leeway: a request sent now would come back
        // 401 halfway through the refresh cycle.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-16T07:51:30Z"))

        #expect(!credential.isFresh(now: now))
    }

    @Test
    func aCredentialWithNoExpiryIsGivenTheBenefitOfTheDoubt() throws {
        let json = Data(#"{"token":{"access_token":"ya29.example"}}"#.utf8)
        let credential = try #require(GoogleAICredential.decode(from: json))

        // Nothing to compare against, so the request is the only thing that can tell us. Refusing
        // to try without a refresh token would leave the account permanently dark.
        #expect(credential.isFresh(now: Date()))
    }

    @Test
    func anExpiredCredentialWithoutARefreshTokenIsStillNotFresh() throws {
        let json = Data(#"{"token":{"access_token":"ya29.example","expiry":"2000-01-01T00:00:00Z"}}"#.utf8)
        let credential = try #require(GoogleAICredential.decode(from: json))

        #expect(!credential.isFresh(now: Date()))
        #expect(credential.refreshToken == nil)
    }
}

struct GoogleAIOAuthClientScannerTests {
    /// Verbatim surroundings of the two client ids and two secrets in Antigravity's language
    /// server binary. The neighbouring text matters: Go pools string constants with no separator,
    /// so a secret is butted straight up against `https` and `decoding`, and a client id against
    /// `runtime` and `arena`.
    private var binaryText: String {
        """
        Remote Control user setting is offruntime.Goexit called in a thread that was not created by the Go runtime\(GoogleAIFixtureCredentials.clientIDOne)[AuthProvider] SetUserTier called
        Overriding CloudCodeServerURL via CLOUD_CODE_URL environment variable: %quser arena chunk size is smaller than a heap arena, but doesn't divide a\(GoogleAIFixtureCredentials.clientIDTwo)http: Server.Protocols contains HTTP3
        ERROR: logging before google.Init: Binary: Built with %s %s for %s/%s
        https://auth.cloud.google/authorize\(GoogleAIFixtureCredentials.secretOne)https://cloudcode-pa.googleapis.comnil media at index %d\(GoogleAIFixtureCredentials.secretTwo)decoding in-band SSE JSON error
        """
    }

    private var binaryData: Data {
        Data(binaryText.utf8)
    }

    @Test
    func everyClientIdIsPairedWithEverySecret() {
        let clients = GoogleAIOAuthClientScanner.candidates(in: binaryData)

        // The layout cannot be read as pairs, so the scanner offers the cross product and the
        // caller finds the one Google accepts. Offering fewer would silently drop the valid pair.
        #expect(clients.count == 4)
        #expect(clients.contains { $0.clientID.hasPrefix("\(GoogleAIFixtureCredentials.clientIDPrefixTwo)") && $0.clientSecret == "\(GoogleAIFixtureCredentials.secretTwo)" })
        #expect(clients.contains { $0.clientID.hasPrefix("\(GoogleAIFixtureCredentials.clientIDPrefixOne)") && $0.clientSecret == "\(GoogleAIFixtureCredentials.secretOne)" })
    }

    @Test
    func aSecretStopsAtTheEndOfTheSecret() {
        // The byte after a secret is whatever constant the pool put next — `https` and `decoding`
        // in the real binary. Running on past the secret yields a credential Google rejects, and
        // every candidate then fails, so the account never refreshes.
        let clients = GoogleAIOAuthClientScanner.candidates(in: binaryData)

        #expect(clients.allSatisfy { $0.clientSecret.count == 35 })
        #expect(!clients.contains { $0.clientSecret.hasSuffix("https") })
        #expect(!clients.contains { $0.clientSecret.hasSuffix("decoding") })
    }

    @Test
    func aClientIdKeepsItsWholePrefixAndNothingBeforeIt() {
        let clients = GoogleAIOAuthClientScanner.candidates(in: binaryData)

        #expect(clients.allSatisfy { $0.clientID.hasSuffix(".apps.googleusercontent.com") })
        // The ids are preceded by `runtime` and `arena` in the pool; neither belongs to the id.
        #expect(
            Set(clients.map(\.clientID)).sorted() == [
                "\(GoogleAIFixtureCredentials.clientIDOne)",
                "\(GoogleAIFixtureCredentials.clientIDTwo)"
            ]
        )
    }

    @Test
    func aBinaryWithoutClientCredentialsYieldsNothing() {
        #expect(GoogleAIOAuthClientScanner.candidates(in: Data("no oauth here".utf8)).isEmpty)
    }

    @Test
    func theClientsAreReadBackOutOfAFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-ai-scanner-\(UUID().uuidString).bin")
        try binaryData.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        #expect(GoogleAIOAuthClientScanner.candidates(at: url).count == 4)
    }

    @Test
    func aMissingFileYieldsNothingRatherThanThrowing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-ai-absent-\(UUID().uuidString).bin")

        #expect(GoogleAIOAuthClientScanner.candidates(at: url).isEmpty)
    }
}
