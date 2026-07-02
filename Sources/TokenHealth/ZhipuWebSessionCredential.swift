import Foundation

struct ZhipuWebSessionCredential: Codable, Equatable, Sendable {
    var accessToken: String?
    var cookieHeader: String?
    var organizationID: String?
    var projectID: String?
    var planName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let orgStatus = (organizationID ?? "").isEmpty ? "no" : "yes"
        let projectStatus = (projectID ?? "").isEmpty ? "no" : "yes"
        let planStatus = (planName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) org=\(orgStatus) project=\(projectStatus) plan=\(planStatus)"
    }

    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "zhipu-web-session:\(string)"
    }

    static func decode(from value: String) -> ZhipuWebSessionCredential? {
        guard value.hasPrefix("zhipu-web-session:") else {
            return nil
        }
        let json = String(value.dropFirst("zhipu-web-session:".count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ZhipuWebSessionCredential.self, from: data)
    }
}
