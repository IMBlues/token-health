import Foundation

struct DeepSeekWebSessionCredential: Codable, Equatable, Sendable {
    var accessToken: String?
    var cookieHeader: String?
    var accountName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) account=\(accountStatus)"
    }

    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "deepseek-web-session:\(string)"
    }

    static func decode(from value: String) -> DeepSeekWebSessionCredential? {
        guard value.hasPrefix("deepseek-web-session:") else {
            return nil
        }
        let json = String(value.dropFirst("deepseek-web-session:".count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(DeepSeekWebSessionCredential.self, from: data)
    }
}
