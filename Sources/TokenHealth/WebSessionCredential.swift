import Foundation

/// 网页登录类 Provider 存在 Keychain 里的凭据共用的编解码约定。
/// 各 Provider 的字段并不一致（有的没有 accessToken，有的没有账号名），
/// 协议只约定存储前缀与编解码，不要求统一字段。
protocol WebSessionCredential: Codable, Equatable, Sendable {
    static var storagePrefix: String { get }
    var isEmpty: Bool { get }
    var debugSummary: String { get }
    /// 设置页与错误文案展示的账号标识；没有该信息的 Provider 返回 nil
    var accountLabel: String? { get }
}

extension WebSessionCredential {
    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "\(Self.storagePrefix)\(string)"
    }

    static func decode(from value: String) -> Self? {
        guard value.hasPrefix(storagePrefix) else {
            return nil
        }
        let json = String(value.dropFirst(storagePrefix.count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
