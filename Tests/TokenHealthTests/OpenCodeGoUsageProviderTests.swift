import Foundation
import Testing
@testable import TokenHealth

@Suite
struct OpenCodeGoUsageProviderTests {
    private let sampleGoStatus = """
    {
      "subscriberUserId": "user_123",
      "subscriptionStatus": "active",
      "currentPeriod": {
        "id": "period_1",
        "status": "active",
        "amountMicroCents": 1000000000,
        "startsAt": "2026-08-01T00:00:00.000Z",
        "endsAt": "2026-09-01T00:00:00.000Z"
      },
      "nextChargeMicroCents": 1000000000,
      "recurringChargeMicroCents": 1000000000,
      "cancelAtPeriodEnd": false,
      "durableBalanceFallbackEnabled": false,
      "meters": [
        {
          "kind": "five_hour",
          "windowStartsAt": "2026-08-07T07:00:00.000Z",
          "resetsAt": "2026-08-07T12:00:00.000Z",
          "limitMicroCents": 120000000,
          "settledMicroCents": 31000000,
          "reservedMicroCents": 900000,
          "remainingMicroCents": 88100000
        },
        {
          "kind": "calendar_week",
          "windowStartsAt": "2026-08-03T00:00:00.000Z",
          "resetsAt": "2026-08-10T00:00:00.000Z",
          "limitMicroCents": 300000000,
          "settledMicroCents": 90000000,
          "reservedMicroCents": 5000000,
          "remainingMicroCents": 205000000
        },
        {
          "kind": "calendar_month",
          "windowStartsAt": "2026-08-01T00:00:00.000Z",
          "resetsAt": "2026-09-01T00:00:00.000Z",
          "limitMicroCents": 600000000,
          "settledMicroCents": 210000000,
          "reservedMicroCents": 12000000,
          "remainingMicroCents": 378000000
        }
      ],
      "availableActions": [],
      "unavailableActions": []
    }
    """

    @Test
    func parsesActiveGoStatusIntoThreeMeters() throws {
        let result = try parse(sampleGoStatus)

        #expect(result.subscriptionMessage == nil)
        #expect(result.planName == "Go · $10.00/mo")
        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        // used = limit - remaining, in microcents
        #expect(result.usages.map(\.used) == [31_900_000, 95_000_000, 222_000_000])
        #expect(result.usages.map(\.limit) == [120_000_000, 300_000_000, 600_000_000])
        // displayValue is dollar-formatted and must not change with the scale
        #expect(result.usages.map(\.displayValue) == ["$0.32 / $1.20", "$0.95 / $3.00", "$2.22 / $6.00"])
        // reset dates present
        #expect(result.usages.compactMap(\.resetDate).count == 3)
        #expect(result.usages[0].unit == nil)
    }

    @Test
    func reportsInactiveSubscriptionAsNoUsage() throws {
        let inactive = """
        {
          "subscriptionStatus": "inactive",
          "meters": []
        }
        """
        let result = try parse(inactive)

        #expect(result.usages.isEmpty)
        #expect(result.subscriptionMessage?.contains("not subscribed") == true)
    }

    @Test
    func reportsCanceledSubscription() throws {
        let canceled = """
        {
          "subscriptionStatus": "canceled",
          "meters": []
        }
        """
        let result = try parse(canceled)

        #expect(result.usages.isEmpty)
        #expect(result.subscriptionMessage?.contains("canceled") == true)
    }

    @Test
    func fallsBackToSettledMicroCentsWhenRemainingMissing() throws {
        let noRemaining = """
        {
          "subscriptionStatus": "active",
          "meters": [
            {
              "kind": "five_hour",
              "resetsAt": "2026-08-07T12:00:00.000Z",
              "limitMicroCents": 120000000,
              "settledMicroCents": 33000000
            }
          ]
        }
        """
        let result = try parse(noRemaining)

        #expect(result.usages.count == 1)
        #expect(result.usages[0].window == .fiveHours)
        #expect(result.usages[0].used == 33_000_000)
        #expect(result.usages[0].limit == 120_000_000)
    }

    @Test
    func skipsUnknownMeterKinds() throws {
        let unknownMeter = """
        {
          "subscriptionStatus": "active",
          "meters": [
            { "kind": "some_other_window", "limitMicroCents": 100000, "remainingMicroCents": 50000 },
            { "kind": "five_hour", "resetsAt": "2026-08-07T12:00:00.000Z", "limitMicroCents": 120000000, "remainingMicroCents": 90000000 }
          ]
        }
        """
        let result = try parse(unknownMeter)

        #expect(result.usages.count == 1)
        #expect(result.usages[0].window == .fiveHours)
    }

    @Test
    func unwrapsWebViewEnvelopeFromGoStatus() throws {
        // The WebView fallback returns {ok, status, ..., goStatus: {...}} instead of
        // the raw GoStatus object; the parser must normalize both shapes.
        let envelope = """
        {
          "ok": true,
          "status": 200,
          "text": "",
          "hasSession": true,
          "goStatus": {
            "subscriptionStatus": "active",
            "meters": [
              { "kind": "five_hour", "resetsAt": "2026-08-07T12:00:00.000Z", "limitMicroCents": 120000000, "remainingMicroCents": 90000000 },
              { "kind": "calendar_week", "resetsAt": "2026-08-10T00:00:00.000Z", "limitMicroCents": 300000000, "remainingMicroCents": 200000000 },
              { "kind": "calendar_month", "resetsAt": "2026-09-01T00:00:00.000Z", "limitMicroCents": 600000000, "remainingMicroCents": 400000000 }
            ]
          },
          "session": { "expiresAt": "2026-08-08T00:00:00.000Z", "user": { "id": "u1", "email": "a@b.c" } }
        }
        """
        let result = try parse(envelope)

        #expect(result.usages.count == 3)
        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        #expect(result.usages.map(\.used) == [30_000_000, 100_000_000, 200_000_000])
    }

    @Test
    func envelopeWithNullGoStatusFallsBackToRawRoot() throws {
        // A non-JSON status body yields goStatus: null; the parser must not crash
        // and should treat it like a non-active subscription instead.
        let envelope = """
        {
          "ok": true,
          "status": 200,
          "text": "",
          "hasSession": true,
          "goStatus": null,
          "session": null
        }
        """
        let result = try parse(envelope)

        #expect(result.usages.isEmpty)
        #expect(result.subscriptionMessage?.contains("not subscribed") == true)
    }

    @Test
    func parsesAccessMetersShape() throws {
        // The live console shape (2026-09): access.meters.fiveHour/week/month.
        let response = """
        {
          "access": {
            "startsAt": "2026-09-01T00:00:00.000Z",
            "endsAt": "2026-10-01T00:00:00.000Z",
            "meters": {
              "fiveHour": { "limitMicroCents": 1200000000, "usedMicroCents": 32000000, "resetsAt": "2026-09-25T12:00:00.000Z" },
              "week": { "limitMicroCents": 3000000000, "usedMicroCents": 95000000, "resetsAt": "2026-09-28T00:00:00.000Z" },
              "month": { "limitMicroCents": 6000000000, "usedMicroCents": 222000000 }
            }
          },
          "cancelAtPeriodEnd": false,
          "renewalPending": false
        }
        """
        let result = try parse(response)

        #expect(result.subscriptionMessage == nil)
        #expect(result.planName == "Go")
        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        #expect(result.usages.map(\.used) == [32_000_000, 95_000_000, 222_000_000])
        #expect(result.usages.map(\.limit) == [1_200_000_000, 3_000_000_000, 6_000_000_000])
        #expect(result.usages.map(\.displayValue) == ["$0.32 / $12.00", "$0.95 / $30.00", "$2.22 / $60.00"])
        // The month window has no resetsAt of its own; it falls back to access.endsAt.
        #expect(result.usages[2].resetDate == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        #expect(result.usages[0].resetDate == ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z"))
    }

    @Test
    func accessShapeWithoutUsableMetersReportsNotSubscribed() throws {
        let response = """
        { "access": { "endsAt": "2026-10-01T00:00:00.000Z", "meters": {} } }
        """
        let result = try parse(response)

        #expect(result.usages.isEmpty)
        #expect(result.subscriptionMessage?.contains("not subscribed") == true)
    }

    @Test
    func missingAccessFailsOverToTheLegacyShape() throws {
        // No access object: the key is absent or null. The legacy shape still parses.
        let response = """
        {
          "subscriptionStatus": "active",
          "meters": [
            { "kind": "five_hour", "resetsAt": "2026-08-07T12:00:00.000Z", "limitMicroCents": 120000000, "remainingMicroCents": 90000000 }
          ]
        }
        """
        let result = try parse(response)

        #expect(result.usages.count == 1)
        #expect(result.usages[0].window == .fiveHours)
        #expect(result.usages[0].used == 30_000_000)
    }

    @Test
    func accessMetersShapeInsideTheWebViewEnvelope() throws {
        // The WebView script wraps the response in {ok, status, ..., goStatus: {...}}.
        let envelope = """
        {
          "ok": true, "status": 200, "text": "", "hasSession": true,
          "goStatus": {
            "access": { "meters": {
              "fiveHour": { "limitMicroCents": 1200000000, "usedMicroCents": 32000000, "resetsAt": "2026-09-25T12:00:00.000Z" }
            } }
          }
        }
        """
        let result = try parse(envelope)

        #expect(result.usages.map(\.displayValue) == ["$0.32 / $12.00"])
    }

    @Test
    func requiresSessionBeforeFetching() async {
        let config = ServiceConfig(
            displayName: "My Go",
            providerKind: .openCodeGo,
            authMode: .api
        )
        let snapshot = await OpenCodeGoUsageProvider().fetchUsage(
            config: config,
            secrets: .empty
        )

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.statusMessage == "Enter your OpenCode Go API key")
    }

    @Test
    func browserLoginWithoutSessionAsksToLogin() async {
        let config = ServiceConfig(
            displayName: "My Go",
            providerKind: .openCodeGo,
            authMode: .browserLogin
        )
        let snapshot = await OpenCodeGoUsageProvider().fetchUsage(
            config: config,
            secrets: .empty
        )

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.statusMessage == "Login with OpenCode Go")
    }

    @Test
    func parsesRealAPIUsageShape() throws {
        let response = """
        {
          "usage": {
            "rolling": { "status": "ok", "percent": 5, "resetsAt": "2026-08-13T08:57:02.675Z" },
            "weekly": { "status": "ok", "percent": 16, "resetsAt": "2026-08-17T00:00:00.675Z" },
            "monthly": { "status": "ok", "percent": 8, "resetsAt": "2026-09-07T11:52:27.675Z" }
          }
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))
        let sorted = result.usages.sorted { usageRank($0.window) < usageRank($1.window) }

        #expect(sorted.map(\.window) == [.fiveHours, .week, .month])
        // percent × published limits: 5%×$12, 16%×$30, 8%×$60 (microCents)
        #expect(sorted.map(\.used) == [60_000_000, 480_000_000, 480_000_000])
        #expect(sorted.map(\.limit) == [1_200_000_000, 3_000_000_000, 6_000_000_000])
        #expect(sorted.map(\.displayValue) == ["$0.60 / $12.00", "$4.80 / $30.00", "$4.80 / $60.00"])
        #expect(sorted.compactMap(\.resetDate).count == 3)
    }

    @Test
    func apiUsageOverLimitClampsToLimit() throws {
        let response = """
        {
          "usage": {
            "rolling": { "status": "ok", "percent": 120, "resetsAt": "2026-08-13T08:57:02.675Z" }
          }
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))

        #expect(result.usages.count == 1)
        #expect(result.usages[0].used == 1_200_000_000)
        #expect(result.usages[0].limit == 1_200_000_000)
        #expect(result.usages[0].ratio == 1)
    }

    @Test
    func parsesAPIUsageLimitsArray() throws {
        let response = """
        {
          "limits": [
            { "kind": "five_hour", "limitMicroCents": 120000000, "usedMicroCents": 30000000, "resetsAt": "2026-08-07T12:00:00.000Z" },
            { "kind": "calendar_week", "limitMicroCents": 300000000, "usedMicroCents": 90000000, "resetsAt": "2026-08-10T00:00:00.000Z" },
            { "kind": "calendar_month", "limitMicroCents": 600000000, "usedMicroCents": 210000000, "resetsAt": "2026-09-01T00:00:00.000Z" }
          ]
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))

        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        #expect(result.usages.map(\.used) == [30_000_000, 90_000_000, 210_000_000])
        #expect(result.usages.map(\.limit) == [120_000_000, 300_000_000, 600_000_000])
    }

    @Test
    func parsesAPIUsageLimitsDictionary() throws {
        let response = """
        {
          "usage": {
            "five_hour": { "limit": 120000000, "used": 40000000, "resetAt": "2026-08-07T12:00:00.000Z" },
            "week": { "limit": 300000000, "used": 80000000, "resetAt": "2026-08-10T00:00:00.000Z" },
            "month": { "limit": 600000000, "used": 200000000, "resetAt": "2026-09-01T00:00:00.000Z" }
          }
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))
        let sorted = result.usages.sorted { usageRank($0.window) < usageRank($1.window) }

        #expect(sorted.map(\.window) == [.fiveHours, .week, .month])
        #expect(sorted.map(\.used) == [40_000_000, 80_000_000, 200_000_000])
    }

    private func usageRank(_ window: UsageWindow) -> Int {
        switch window {
        case .fiveHours: 0
        case .week: 1
        case .month: 2
        default: 9
        }
    }

    @Test
    func parsesAPIUsageDataEnvelope() throws {
        let response = """
        {
          "data": {
            "limits": [
              { "kind": "five_hour", "limitMicroCents": 120000000, "remainingMicroCents": 100000000, "resetsAt": "2026-08-07T12:00:00.000Z" }
            ]
          }
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))

        #expect(result.usages.count == 1)
        #expect(result.usages[0].used == 20_000_000)
        #expect(result.usages[0].limit == 120_000_000)
    }

    @Test
    func apiUsageUnknownShapeSurfacesRawBody() {
        let response = #"{ "hello": "world" }"#
        #expect(throws: OpenCodeGoUsageParser.ParserError.self) {
            _ = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))
        }
    }

    @Test
    func credentialRoundTripsThroughEncodedForm() throws {
        var credential = OpenCodeGoWebSessionCredential()
        credential.cookieHeader = "session=abc123; foo=bar"
        credential.accountName = "user@example.com"

        let encoded = credential.encodedForStorage()
        #expect(encoded.hasPrefix("opencode-go-web-session:"))

        let decoded = OpenCodeGoWebSessionCredential.decode(from: encoded)
        #expect(decoded == credential)
    }

    @Test
    func credentialRejectsForeignPrefix() {
        #expect(OpenCodeGoWebSessionCredential.decode(from: "minimax-web-session:{}") == nil)
        #expect(OpenCodeGoWebSessionCredential.decode(from: "garbage") == nil)
    }

    @Test
    func credentialsAreEmptyWithoutCookie() {
        let credential = OpenCodeGoWebSessionCredential()
        #expect(credential.isEmpty)

        var filled = OpenCodeGoWebSessionCredential()
        filled.cookieHeader = "session=x"
        #expect(!filled.isEmpty)
    }

    @Test
    func formatsDollarsFromMicroCents() {
        // microcents: 1 USD = 1e8. The console's own price constants use this scale
        // (Go plan recurringMicroCents = 1000000000n is $10/mo).
        #expect(OpenCodeGoUsageParser.dollarsText(120_000_000) == "$1.20")
        #expect(OpenCodeGoUsageParser.dollarsText(1_200_000_000) == "$12.00")
        #expect(OpenCodeGoUsageParser.dollarsText(5_000_000) == "$0.05")
        #expect(OpenCodeGoUsageParser.dollarsText(100_000_000) == "$1.00")
    }

    private func parse(_ json: String) throws -> OpenCodeGoUsageParser.ParseResult {
        try OpenCodeGoUsageParser().parseBundle(data: Data(json.utf8))
    }
}
