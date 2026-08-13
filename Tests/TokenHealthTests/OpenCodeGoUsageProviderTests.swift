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
        "amountMicroCents": 10000000,
        "startsAt": "2026-08-01T00:00:00.000Z",
        "endsAt": "2026-09-01T00:00:00.000Z"
      },
      "nextChargeMicroCents": 1000000,
      "recurringChargeMicroCents": 1000000,
      "cancelAtPeriodEnd": false,
      "durableBalanceFallbackEnabled": false,
      "meters": [
        {
          "kind": "five_hour",
          "windowStartsAt": "2026-08-07T07:00:00.000Z",
          "resetsAt": "2026-08-07T12:00:00.000Z",
          "limitMicroCents": 1200000,
          "settledMicroCents": 310000,
          "reservedMicroCents": 9000,
          "remainingMicroCents": 881000
        },
        {
          "kind": "calendar_week",
          "windowStartsAt": "2026-08-03T00:00:00.000Z",
          "resetsAt": "2026-08-10T00:00:00.000Z",
          "limitMicroCents": 3000000,
          "settledMicroCents": 900000,
          "reservedMicroCents": 50000,
          "remainingMicroCents": 2050000
        },
        {
          "kind": "calendar_month",
          "windowStartsAt": "2026-08-01T00:00:00.000Z",
          "resetsAt": "2026-09-01T00:00:00.000Z",
          "limitMicroCents": 6000000,
          "settledMicroCents": 2100000,
          "reservedMicroCents": 120000,
          "remainingMicroCents": 3780000
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
        // used = limit - remaining, in microCents
        #expect(result.usages.map(\.used) == [319_000, 950_000, 2_220_000])
        #expect(result.usages.map(\.limit) == [1_200_000, 3_000_000, 6_000_000])
        // displayValue is dollar-formatted
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
              "limitMicroCents": 1200000,
              "settledMicroCents": 330000
            }
          ]
        }
        """
        let result = try parse(noRemaining)

        #expect(result.usages.count == 1)
        #expect(result.usages[0].window == .fiveHours)
        #expect(result.usages[0].used == 330_000)
        #expect(result.usages[0].limit == 1_200_000)
    }

    @Test
    func skipsUnknownMeterKinds() throws {
        let unknownMeter = """
        {
          "subscriptionStatus": "active",
          "meters": [
            { "kind": "some_other_window", "limitMicroCents": 1000, "remainingMicroCents": 500 },
            { "kind": "five_hour", "resetsAt": "2026-08-07T12:00:00.000Z", "limitMicroCents": 1200000, "remainingMicroCents": 900000 }
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
              { "kind": "five_hour", "resetsAt": "2026-08-07T12:00:00.000Z", "limitMicroCents": 1200000, "remainingMicroCents": 900000 },
              { "kind": "calendar_week", "resetsAt": "2026-08-10T00:00:00.000Z", "limitMicroCents": 3000000, "remainingMicroCents": 2000000 },
              { "kind": "calendar_month", "resetsAt": "2026-09-01T00:00:00.000Z", "limitMicroCents": 6000000, "remainingMicroCents": 4000000 }
            ]
          },
          "session": { "expiresAt": "2026-08-08T00:00:00.000Z", "user": { "id": "u1", "email": "a@b.c" } }
        }
        """
        let result = try parse(envelope)

        #expect(result.usages.count == 3)
        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        #expect(result.usages.map(\.used) == [300_000, 1_000_000, 2_000_000])
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
        #expect(sorted.map(\.used) == [600_000, 4_800_000, 4_800_000])
        #expect(sorted.map(\.limit) == [12_000_000, 30_000_000, 60_000_000])
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
        #expect(result.usages[0].used == 12_000_000)
        #expect(result.usages[0].limit == 12_000_000)
        #expect(result.usages[0].ratio == 1)
    }

    @Test
    func parsesAPIUsageLimitsArray() throws {
        let response = """
        {
          "limits": [
            { "kind": "five_hour", "limitMicroCents": 1200000, "usedMicroCents": 300000, "resetsAt": "2026-08-07T12:00:00.000Z" },
            { "kind": "calendar_week", "limitMicroCents": 3000000, "usedMicroCents": 900000, "resetsAt": "2026-08-10T00:00:00.000Z" },
            { "kind": "calendar_month", "limitMicroCents": 6000000, "usedMicroCents": 2100000, "resetsAt": "2026-09-01T00:00:00.000Z" }
          ]
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))

        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        #expect(result.usages.map(\.used) == [300_000, 900_000, 2_100_000])
        #expect(result.usages.map(\.limit) == [1_200_000, 3_000_000, 6_000_000])
    }

    @Test
    func parsesAPIUsageLimitsDictionary() throws {
        let response = """
        {
          "usage": {
            "five_hour": { "limit": 1200000, "used": 400000, "resetAt": "2026-08-07T12:00:00.000Z" },
            "week": { "limit": 3000000, "used": 800000, "resetAt": "2026-08-10T00:00:00.000Z" },
            "month": { "limit": 6000000, "used": 2000000, "resetAt": "2026-09-01T00:00:00.000Z" }
          }
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))
        let sorted = result.usages.sorted { usageRank($0.window) < usageRank($1.window) }

        #expect(sorted.map(\.window) == [.fiveHours, .week, .month])
        #expect(sorted.map(\.used) == [400_000, 800_000, 2_000_000])
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
              { "kind": "five_hour", "limitMicroCents": 1200000, "remainingMicroCents": 1000000, "resetsAt": "2026-08-07T12:00:00.000Z" }
            ]
          }
        }
        """
        let result = try OpenCodeGoUsageParser().parseAPIResponse(data: Data(response.utf8))

        #expect(result.usages.count == 1)
        #expect(result.usages[0].used == 200_000)
        #expect(result.usages[0].limit == 1_200_000)
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
        #expect(OpenCodeGoUsageParser.dollarsText(1_200_000) == "$1.20")
        #expect(OpenCodeGoUsageParser.dollarsText(12_000_000) == "$12.00")
        #expect(OpenCodeGoUsageParser.dollarsText(50_000) == "$0.05")
        #expect(OpenCodeGoUsageParser.dollarsText(1_000_000) == "$1.00")
    }

    private func parse(_ json: String) throws -> OpenCodeGoUsageParser.ParseResult {
        try OpenCodeGoUsageParser().parseBundle(data: Data(json.utf8))
    }
}
