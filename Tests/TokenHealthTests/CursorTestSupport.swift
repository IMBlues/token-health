import Foundation
@testable import TokenHealth

enum CursorTestSupport {
    static var liveCursorCheckEnabled: Bool {
        ProcessInfo.processInfo.environment["TOKEN_HEALTH_LIVE_CURSOR"] == "1"
    }

    static func decode(_ json: String) throws -> CursorUsageSummary {
        try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
    }

    static func fetchLiveUsage() async throws -> CursorMappedUsage {
        let token = try CursorLocalSessionReader().readAccessToken()
        let response = try await CursorUsageClient().fetchUsage(accessToken: token)
        return try CursorUsageMapper.map(response)
    }
}
