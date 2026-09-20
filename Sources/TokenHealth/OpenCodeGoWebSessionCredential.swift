import Foundation

struct OpenCodeGoWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "opencode-go-web-session:"

    var cookieHeader: String?
    var accountName: String?

    var isEmpty: Bool {
        (cookieHeader ?? "").isEmpty
    }

    var accountLabel: String? {
        Self.nonEmpty(accountName)
    }

    var debugSummary: String {
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "cookie=\(cookieStatus) account=\(accountStatus)"
    }
}
