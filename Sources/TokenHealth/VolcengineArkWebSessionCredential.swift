import Foundation

struct VolcengineArkWebSessionCredential: Codable, Equatable, Sendable {
    var cookieHeader: String?
    var csrfToken: String?
    var accountName: String?

    var isEmpty: Bool {
        (cookieHeader ?? "").isEmpty
    }

    var debugSummary: String {
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let csrfStatus = (csrfToken ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "cookie=\(cookieStatus) csrf=\(csrfStatus) account=\(accountStatus)"
    }

    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "volcengine-ark-web-session:\(string)"
    }

    static func decode(from value: String) -> VolcengineArkWebSessionCredential? {
        guard value.hasPrefix("volcengine-ark-web-session:") else {
            return nil
        }
        let json = String(value.dropFirst("volcengine-ark-web-session:".count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(VolcengineArkWebSessionCredential.self, from: data)
    }
}
