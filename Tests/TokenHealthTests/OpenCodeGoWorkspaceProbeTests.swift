import Foundation
import Testing
@testable import TokenHealth

/// Pins the native workspace-probe policy — the script-side twin of the same selection rules is
/// covered by OpenCodeGoWebSessionScriptTests — so the two sides cannot drift apart.
@Suite
struct OpenCodeGoWorkspaceProbeTests {
    private let withAccess = Data(#"{"access":{"meters":{}}}"#.utf8)
    private let withoutAccess = Data(#"{"subscriptionStatus":"inactive"}"#.utf8)

    @Test
    func stopsAtTheFirstWorkspaceWithAccess() async {
        var probed: [String] = []
        let outcome = await OpenCodeGoWorkspaceProbe.run(
            workspaces: ["w1", "w2", "w3"],
            limit: 5,
            fetch: { id in
                probed.append(id)
                return id == "w1" ? self.withAccess : self.withoutAccess
            },
            hasAccess: OpenCodeGoUsageParser.hasGoAccess
        )

        // The break at the first workspace with access must stop the loop: w2/w3 are never probed.
        #expect(probed == ["w1"])
        #expect(outcome == .init(statusData: withAccess, workspaceID: "w1", sawFailure: false))
    }

    @Test
    func skipsWorkspacesWithoutAccessUntilOneHasIt() async {
        var probed: [String] = []
        let outcome = await OpenCodeGoWorkspaceProbe.run(
            workspaces: ["w1", "w2", "w3"],
            limit: 5,
            fetch: { id in
                probed.append(id)
                return id == "w2" ? self.withAccess : self.withoutAccess
            },
            hasAccess: OpenCodeGoUsageParser.hasGoAccess
        )

        #expect(probed == ["w1", "w2"])
        #expect(outcome == .init(statusData: withAccess, workspaceID: "w2", sawFailure: false))
    }

    @Test
    func keepsTheFirstResponseWhenNoWorkspaceHasAccess() async {
        let outcome = await OpenCodeGoWorkspaceProbe.run(
            workspaces: ["w1", "w2"],
            limit: 5,
            fetch: { _ in self.withoutAccess },
            hasAccess: OpenCodeGoUsageParser.hasGoAccess
        )

        // No failure anywhere: the first response is kept so "not subscribed" survives.
        #expect(outcome == .init(statusData: withoutAccess, workspaceID: "w1", sawFailure: false))
    }

    @Test
    func aFailedProbeIsSkippedAndProbingContinues() async {
        let outcome = await OpenCodeGoWorkspaceProbe.run(
            workspaces: ["w1", "w2"],
            limit: 5,
            fetch: { id in id == "w1" ? nil : self.withoutAccess },
            hasAccess: OpenCodeGoUsageParser.hasGoAccess
        )

        // The failed probe is recorded, not adopted; the second response becomes the fallback.
        #expect(outcome == .init(statusData: withoutAccess, workspaceID: "w2", sawFailure: true))
    }

    @Test
    func allFailedProbesLeaveNoDataAndRecordTheFailure() async {
        let outcome = await OpenCodeGoWorkspaceProbe.run(
            workspaces: ["w1", "w2"],
            limit: 5,
            fetch: { _ in nil },
            hasAccess: OpenCodeGoUsageParser.hasGoAccess
        )

        #expect(outcome.statusData == nil)
        #expect(outcome.workspaceID == nil)
        #expect(outcome.sawFailure)
    }

    @Test
    func probesAtMostTheLimit() async {
        var probed: [String] = []
        let outcome = await OpenCodeGoWorkspaceProbe.run(
            workspaces: ["w1", "w2", "w3", "w4", "w5", "w6", "w7"],
            limit: 3,
            fetch: { id in
                probed.append(id)
                return self.withoutAccess
            },
            hasAccess: OpenCodeGoUsageParser.hasGoAccess
        )

        // Seven workspaces, none with access: the walk must stop at the limit.
        #expect(probed == ["w1", "w2", "w3"])
        #expect(outcome == .init(statusData: withoutAccess, workspaceID: "w1", sawFailure: false))
    }
}
