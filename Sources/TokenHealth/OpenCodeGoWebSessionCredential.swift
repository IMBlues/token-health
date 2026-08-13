import Foundation

struct OpenCodeGoWebSessionCredential: Codable, Equatable, Sendable {
    var cookieHeader: String?
    var accountName: String?

    var isEmpty: Bool {
        (cookieHeader ?? "").isEmpty
    }

    var debugSummary: String {
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "cookie=\(cookieStatus) account=\(accountStatus)"
    }

    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "opencode-go-web-session:\(string)"
    }

    static func decode(from value: String) -> OpenCodeGoWebSessionCredential? {
        guard value.hasPrefix("opencode-go-web-session:") else {
            return nil
        }
        let json = String(value.dropFirst("opencode-go-web-session:".count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(OpenCodeGoWebSessionCredential.self, from: data)
    }
}
