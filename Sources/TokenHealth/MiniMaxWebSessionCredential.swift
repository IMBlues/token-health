import Foundation

struct MiniMaxWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "minimax-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var groupID: String?
    var accountName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
    }

    var accountLabel: String? {
        Self.nonEmpty(accountName)
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let groupStatus = (groupID ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) group=\(groupStatus) account=\(accountStatus)"
    }
}
