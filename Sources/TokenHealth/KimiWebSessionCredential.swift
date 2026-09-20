import Foundation

struct KimiWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "kimi-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var trafficID: String?
    var deviceID: String?
    var sessionID: String?
    var planName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
    }

    /// Kimi's credential carries no account identifier (the design maps it to `nil`): a
    /// `planName` is a plan, not an account, so settings shows no "<account>" suffix for Kimi.
    var accountLabel: String? {
        nil
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let trafficStatus = (trafficID ?? "").isEmpty ? "no" : "yes"
        let deviceStatus = (deviceID ?? "").isEmpty ? "no" : "yes"
        let sessionStatus = (sessionID ?? "").isEmpty ? "no" : "yes"
        let planStatus = (planName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) trafficID=\(trafficStatus) deviceID=\(deviceStatus) sessionID=\(sessionStatus) plan=\(planStatus)"
    }
}
