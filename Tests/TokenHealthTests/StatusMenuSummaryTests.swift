import Foundation
import Testing
@testable import TokenHealth

@Suite
struct StatusMenuSummaryTests {
    @Test
    func ignoresReadySnapshotsForDisabledAndRemovedProviders() {
        let enabled = ServiceConfig(
            displayName: "Cursor",
            providerKind: .cursor,
            authMode: .api
        )
        var disabled = ServiceConfig(
            displayName: "Codex",
            providerKind: .codex,
            authMode: .api
        )
        disabled.isEnabled = false
        let removed = ServiceConfig(
            displayName: "Removed",
            providerKind: .demo,
            authMode: .api
        )

        let snapshots = [
            enabled.id: readySnapshot(for: enabled),
            disabled.id: readySnapshot(for: disabled),
            removed.id: readySnapshot(for: removed)
        ]

        #expect(
            StatusMenuSummary.text(
                configs: [enabled, disabled],
                snapshots: snapshots,
                isRefreshing: false
            ) == "1/1 updated"
        )
    }

    @Test
    func reportsWhenEveryProviderIsDisabled() {
        var config = ServiceConfig(
            displayName: "Cursor",
            providerKind: .cursor,
            authMode: .api
        )
        config.isEnabled = false

        #expect(
            StatusMenuSummary.text(
                configs: [config],
                snapshots: [config.id: readySnapshot(for: config)],
                isRefreshing: false
            ) == "No enabled plans"
        )
    }

    @Test
    func appendsRelativeAgeOfLastRefresh() {
        let config = ServiceConfig(
            displayName: "Cursor",
            providerKind: .cursor,
            authMode: .api
        )
        let now = Date()

        #expect(
            StatusMenuSummary.text(
                configs: [config],
                snapshots: [config.id: readySnapshot(for: config)],
                isRefreshing: false,
                lastRefreshAt: now.addingTimeInterval(-180),
                now: now
            ) == "1/1 updated · 3m ago"
        )
    }

    @Test
    func omitsRelativeAgeWithoutARefreshTimestamp() {
        let config = ServiceConfig(
            displayName: "Cursor",
            providerKind: .cursor,
            authMode: .api
        )

        #expect(
            StatusMenuSummary.text(
                configs: [config],
                snapshots: [config.id: readySnapshot(for: config)],
                isRefreshing: false,
                lastRefreshAt: nil
            ) == "1/1 updated"
        )
    }

    @Test
    func formatsRelativeAgeInMinutesHoursAndDays() {
        let now = Date()

        #expect(StatusMenuSummary.relativeAge(from: now, now: now) == "just now")
        #expect(StatusMenuSummary.relativeAge(from: now.addingTimeInterval(-59), now: now) == "just now")
        #expect(StatusMenuSummary.relativeAge(from: now.addingTimeInterval(5), now: now) == "just now")
        #expect(StatusMenuSummary.relativeAge(from: now.addingTimeInterval(-60), now: now) == "1m ago")
        #expect(StatusMenuSummary.relativeAge(from: now.addingTimeInterval(-59 * 60), now: now) == "59m ago")
        #expect(StatusMenuSummary.relativeAge(from: now.addingTimeInterval(-3 * 3600 - 60), now: now) == "3h ago")
        #expect(StatusMenuSummary.relativeAge(from: now.addingTimeInterval(-2 * 86_400), now: now) == "2d ago")
    }

    private func readySnapshot(for config: ServiceConfig) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: config.id,
            serviceName: config.displayName,
            providerTitle: config.providerKind.title,
            usages: [],
            state: .ready,
            statusMessage: "OK",
            updatedAt: .distantPast
        )
    }
}
