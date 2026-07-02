import Foundation

struct KimiWebSessionCredential: Codable, Equatable, Sendable {
    var accessToken: String?
    var cookieHeader: String?
    var trafficID: String?
    var deviceID: String?
    var sessionID: String?
    var planName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
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

    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "kimi-web-session:\(string)"
    }

    static func decode(from value: String) -> KimiWebSessionCredential? {
        guard value.hasPrefix("kimi-web-session:") else {
            return nil
        }
        let json = String(value.dropFirst("kimi-web-session:".count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(KimiWebSessionCredential.self, from: data)
    }
}
