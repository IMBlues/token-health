import Foundation

struct ZhipuWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "zhipu-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var organizationID: String?
    var projectID: String?
    var planName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
    }

    /// No account name is available: `planName` names a plan tier, not an account, so two accounts
    /// on the same plan would show the same label.
    var accountLabel: String? {
        nil
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let orgStatus = (organizationID ?? "").isEmpty ? "no" : "yes"
        let projectStatus = (projectID ?? "").isEmpty ? "no" : "yes"
        let planStatus = (planName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) org=\(orgStatus) project=\(projectStatus) plan=\(planStatus)"
    }
}
