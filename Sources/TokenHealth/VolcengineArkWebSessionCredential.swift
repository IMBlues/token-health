import Foundation

struct VolcengineArkWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "volcengine-ark-web-session:"

    var cookieHeader: String?
    var csrfToken: String?
    var accountName: String?

    var isEmpty: Bool {
        (cookieHeader ?? "").isEmpty
    }

    var accountLabel: String? {
        Self.nonEmpty(accountName)
    }

    var debugSummary: String {
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let csrfStatus = (csrfToken ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "cookie=\(cookieStatus) csrf=\(csrfStatus) account=\(accountStatus)"
    }
}
