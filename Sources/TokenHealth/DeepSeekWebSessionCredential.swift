import Foundation

struct DeepSeekWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "deepseek-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var accountName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty
    }

    var accountLabel: String? {
        guard let accountName, !accountName.isEmpty else {
            return nil
        }
        return accountName
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) account=\(accountStatus)"
    }
}
