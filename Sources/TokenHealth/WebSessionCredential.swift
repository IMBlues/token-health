import Foundation

/// Shared encoding contract for the credentials that web-login providers store in the Keychain.
/// Provider structs do not share a field set (some have no access token, some no account name),
/// so the protocol fixes only the storage prefix and the codec, not the fields.
///
/// Call the codec on a concrete type (`DeepSeekWebSessionCredential.decode(from:)`). It lives in an
/// extension, so it does not take part in dynamic dispatch: through an `any WebSessionCredential`
/// existential you would silently get the default implementation instead of the conformer's.
protocol WebSessionCredential: Codable, Equatable, Sendable {
    static var storagePrefix: String { get }
    var isEmpty: Bool { get }
    var debugSummary: String { get }
    /// Account identifier shown in settings and error copy; nil when the provider has none.
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

    /// Maps an optional string to nil when it is nil or empty, so conformers can write
    /// `var accountLabel: String? { Self.nonEmpty(accountName) }` instead of repeating the guard.
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}
