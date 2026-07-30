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
