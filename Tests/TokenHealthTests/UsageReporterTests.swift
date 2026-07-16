import Testing
@testable import TokenHealth

@Suite("Usage reporting hook")
struct UsageReporterTests {
    @Test
    func buildsAccountQuotaPayload() throws {
        let payload = UsageReporterTestSupport.accountQuotaPayload()

        #expect(payload.clientID == "test-client")
        #expect(payload.accounts.count == 1)
        let account = try #require(payload.accounts.first)
        #expect(account.provider == "kimi-code")
        #expect(account.accountRef == "sha256:be7499a5a1b2838b6222c0ec3469276c995489e1e465faf46b206a7aa29c819a")
        #expect(account.displayName == "Kimi Code · Allegretto")
        #expect(account.plan == "Allegretto")
        #expect(account.status == "ok")
        #expect(account.windows == [
            UsageReportWindow(name: "5h", usedPercent: 18, resetsAt: "1970-01-01T00:00:00Z"),
            UsageReportWindow(name: "week", usedPercent: 97, resetsAt: "1970-01-01T01:00:00Z")
        ])
    }

    @Test
    func keepsOneWindowPerSelectedProvider() throws {
        let payload = UsageReporterTestSupport.deduplicatedPayload()

        #expect(payload.accounts.count == 1)
        let account = try #require(payload.accounts.first)
        #expect(account.plan == "unknown")
        #expect(account.windows == [UsageReportWindow(name: "5h", usedPercent: 20, resetsAt: nil)])
    }

    @Test
    func refusesToBuildAnAccountForDisabledProvider() {
        #expect(UsageReporterTestSupport.disabledProviderPayload().accounts.isEmpty)
    }

    @Test
    func createsAuthenticatedIdempotentPostRequest() throws {
        let summary = try UsageReporterTestSupport.requestSummary()

        #expect(summary.method == "POST")
        #expect(summary.authorization == "Bearer secret-token")
        #expect(summary.idempotencyKey == "local-1234567")
        #expect(summary.contentType == "application/json")
        #expect(summary.bodyMatches)
        #expect(summary.bodyUsesSnakeCase)
    }

    @Test
    func persistsHookConfiguration() throws {
        #expect(try UsageReporterTestSupport.persistsHookConfiguration())
    }

    @Test
    func migratesConfigurationWithoutCertificatePin() throws {
        #expect(try UsageReporterTestSupport.decodesLegacyHookConfiguration())
    }

    @Test
    func normalizesCertificateFingerprint() {
        #expect(UsageReporterTestSupport.normalizesCertificateFingerprint())
    }

    @Test
    func rejectsMalformedCertificateFingerprint() {
        #expect(UsageReporterTestSupport.rejectsMalformedCertificateFingerprint())
    }

    @Test(.enabled(if: UsageReporterTestSupport.livePinnedEndpointConfigured))
    func reachesConfiguredPinnedEndpoint() async throws {
        let statusCode = try await UsageReporterTestSupport.livePinnedEndpointStatus()
        #expect((200..<600).contains(statusCode))
    }
}
