import Foundation

struct MiniMaxWebSessionCredential: Codable, Equatable, Sendable {
    var accessToken: String?
    var cookieHeader: String?
    var groupID: String?
    var accountName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let groupStatus = (groupID ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) group=\(groupStatus) account=\(accountStatus)"
    }

    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "minimax-web-session:\(string)"
    }

    static func decode(from value: String) -> MiniMaxWebSessionCredential? {
        guard value.hasPrefix("minimax-web-session:") else {
            return nil
        }
        let json = String(value.dropFirst("minimax-web-session:".count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(MiniMaxWebSessionCredential.self, from: data)
    }
}
