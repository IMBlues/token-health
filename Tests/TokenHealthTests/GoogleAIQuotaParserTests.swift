import Foundation
import Testing
@testable import TokenHealth

/// The parser's fixtures are trimmed copies of what `cloudcode-pa.googleapis.com` actually
/// returned for a logged-in Antigravity account, so the field names and shapes here are the
/// server's, not invented ones.
struct GoogleAIQuotaParserTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    private var summary: Data {
        data(#"""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "description": "Models within this group: Gemini Flash, Gemini Pro",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "resetTime": "2026-10-23T07:03:07Z",
                  "remainingFraction": 0.42
                },
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-10-16T12:03:07Z",
                  "remainingFraction": 1
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "resetTime": "2026-10-23T07:03:07Z",
                  "remainingFraction": 0.985
                },
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-10-16T12:03:07Z",
                  "remainingFraction": 1
                }
              ]
            }
          ],
          "description": "Within each group, models share a weekly limit and a 5-hour limit."
        }
        """#)
    }

    @Test
    func aSummaryBecomesOneUsagePerGroupAndWindow() throws {
        let usages = try GoogleAIQuotaParser.summary(from: summary).usages

        #expect(usages.map(\.window) == [.week, .fiveHours, .week, .fiveHours])
        #expect(
            usages.map(\.label) == [
                "Gemini Week", "Gemini 5h", "Claude & GPT Week", "Claude & GPT 5h"
            ]
        )
    }

    @Test
    func aUsageSpendsTheFractionTheBucketReports() throws {
        let usages = try GoogleAIQuotaParser.summary(from: summary).usages
        let geminiWeek = try #require(usages.first)

        // The endpoint only ever reports what is *left*, so the bar has to be built from its
        // complement: 42% left is 58% spent.
        #expect(geminiWeek.used == 58)
        #expect(geminiWeek.limit == 100)
        #expect(geminiWeek.unit == "%")
        #expect(geminiWeek.ratio == 0.58)
    }

    @Test
    func aUsageCarriesTheResetInstant() throws {
        let usages = try GoogleAIQuotaParser.summary(from: summary).usages
        let geminiWeek = try #require(usages.first)

        #expect(geminiWeek.resetDate == ISO8601DateFormatter().date(from: "2026-10-23T07:03:07Z"))
    }

    @Test
    func aFractionOutsideZeroToOneIsClamped() throws {
        let json = data(#"""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"window":"weekly","remainingFraction":1.5},
          {"window":"5h","remainingFraction":-0.25}
        ]}]}
        """#)

        let usages = try GoogleAIQuotaParser.summary(from: json).usages

        #expect(usages.map(\.used) == [0, 100])
    }

    @Test
    func aBucketWithoutAFractionIsSkipped() throws {
        let json = data(#"""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"window":"weekly"},
          {"window":"5h","remainingFraction":1}
        ]}]}
        """#)

        let usages = try GoogleAIQuotaParser.summary(from: json).usages

        #expect(usages.map(\.window) == [.fiveHours])
    }

    @Test
    func anUnknownWindowIsSkippedRatherThanGuessed() throws {
        let json = data(#"""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"window":"monthly","remainingFraction":1},
          {"window":"5h","remainingFraction":0.5,"resetTime":"2026-10-16T12:03:07Z"}
        ]}]}
        """#)

        let usages = try GoogleAIQuotaParser.summary(from: json).usages

        #expect(usages.map(\.window) == [.fiveHours])
        #expect(usages.map(\.used) == [50])
    }

    @Test
    func aGroupTheParserHasNeverSeenKeepsItsOwnName() throws {
        let json = data(#"""
        {"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":1}]},
                   {"displayName":"Gemma models","buckets":[{"window":"5h","remainingFraction":1}]}]}
        """#)

        let usages = try GoogleAIQuotaParser.summary(from: json).usages

        #expect(usages.map(\.label) == ["Gemini 5h", "Gemma models 5h"])
    }

    @Test
    func aMalformedSummaryThrowsInsteadOfReturningNothing() {
        #expect(throws: (any Error).self) {
            try GoogleAIQuotaParser.summary(from: data("not json"))
        }
    }

    @Test
    func anEmptySummaryIsNotAnError() throws {
        let usages = try GoogleAIQuotaParser.summary(from: data(#"{"groups":[]}"#)).usages

        #expect(usages.isEmpty)
    }

    // MARK: - models

    private var availableModels: Data {
        data(#"""
        {
          "models": {
            "gemini-3.6-flash-high": {
              "displayName": "Gemini 3.6 Flash (High)",
              "quotaInfo": { "remainingFraction": 0.9997, "resetTime": "2026-10-16T12:16:27Z" }
            },
            "claude-opus-5-5-high": {
              "displayName": "Claude Opus 5.5 (High)",
              "quotaInfo": { "remainingFraction": 0.31, "resetTime": "2026-10-16T12:16:27Z" }
            },
            "chat_20706": {
              "quotaInfo": { "remainingFraction": 1 }
            }
          },
          "agentModelSorts": [
            { "displayName": "Recommended", "groups": [
              { "modelIds": ["gemini-3.6-flash-high", "claude-opus-5-5-high"] }
            ] }
          ]
        }
        """#)
    }

    @Test
    func modelsComeBackLeastRemainingFirst() throws {
        let models = GoogleAIQuotaParser.models(from: availableModels)

        #expect(models.map(\.displayName) == ["Claude Opus 5.5 (High)", "Gemini 3.6 Flash (High)"])
        #expect(models.map(\.remainingFraction) == [0.31, 0.9997])
    }

    @Test
    func aModelWithoutADisplayNameIsNotUserFacing() throws {
        // `chat_20706` is Antigravity's own internal chat model: it has quota but no name, and
        // listing it would put an opaque id in the popover's table.
        let models = GoogleAIQuotaParser.models(from: availableModels)

        #expect(!models.contains { $0.id == "chat_20706" })
    }

    @Test
    func aModelOutsideTheRecommendedListStillAppears() throws {
        let json = data(#"""
        {"models":{
          "some-other-model":{"displayName":"Some Other Model","quotaInfo":{"remainingFraction":0.5}}
        }}
        """#)

        let models = GoogleAIQuotaParser.models(from: json)

        #expect(models.map(\.displayName) == ["Some Other Model"])
    }

    @Test
    func equalFractionsFallBackToTheRecommendedOrder() throws {
        let json = data(#"""
        {"models":{
          "second":{"displayName":"Second","quotaInfo":{"remainingFraction":1}},
          "first":{"displayName":"First","quotaInfo":{"remainingFraction":1}}
        },
        "agentModelSorts":[{"groups":[{"modelIds":["first","second"]}]}]}
        """#)

        let models = GoogleAIQuotaParser.models(from: json)

        #expect(models.map(\.displayName) == ["First", "Second"])
    }

    @Test
    func aMalformedModelCatalogueIsNotAnError() throws {
        #expect(GoogleAIQuotaParser.models(from: data("not json")).isEmpty)
    }

    @Test
    func aModelWithoutQuotaInfoIsSkipped() throws {
        let json = data(#"""
        {"models":{
          "no-quota":{"displayName":"No Quota"},
          "with-quota":{"displayName":"With Quota","quotaInfo":{"remainingFraction":0.5}}
        }}
        """#)

        let models = GoogleAIQuotaParser.models(from: json)

        #expect(models.map(\.displayName) == ["With Quota"])
    }
}
