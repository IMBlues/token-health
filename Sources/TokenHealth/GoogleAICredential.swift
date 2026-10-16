import Foundation

/// The OAuth token Antigravity leaves behind for its own language server, at
/// `~/.gemini/jetski-standalone-oauth-token`.
struct GoogleAICredential: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?

    static func decode(from data: Data) -> GoogleAICredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? [String: Any],
              let accessToken = token["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }

        return GoogleAICredential(
            accessToken: accessToken,
            refreshToken: (token["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiry: (token["expiry"] as? String).flatMap(Self.parseDate)
        )
    }

    /// Whether the access token can still be spent.
    ///
    /// A token with no expiry is taken as fresh — there is nothing to compare against, and
    /// refusing to try would leave the account dark for a field that may simply be absent.
    func isFresh(now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiry else {
            return true
        }
        return expiry.timeIntervalSince(now) > leeway
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// A Google OAuth client, as carried inside Antigravity's own binary.
///
/// The `GOCSPX-` secret is not a real secret: Google ships it verbatim inside the app so that an
/// installed app can refresh tokens without a server. It is read back out of the installed binary
/// instead of being written into this repository, which is public — and reading it back means a
/// rotation on Google's side needs no change here.
struct GoogleAIOAuthClient: Equatable, Sendable {
    var clientID: String
    var clientSecret: String
}

/// Pulls the OAuth clients out of Antigravity's language server binary.
///
/// The two literals are found with `Data.range(of:)` rather than by walking every byte: the binary
/// is 155 MB, and a naive byte loop over it spends about a minute of the refresh cycle finding
/// four short strings. The file is memory-mapped so the scan does not copy it either.
enum GoogleAIOAuthClientScanner {
    /// A Google installed-app secret is a fixed 35 characters. It has to be a width, not a
    /// delimiter: Go pools string constants with nothing between them, so the byte after a secret
    /// is whatever constant the linker put next (`https`, `decoding` in the real binary). Reading
    /// on past the end produces a secret Google rejects, and since every candidate then fails, the
    /// account silently stops refreshing.
    private static let secretLength = 35
    /// Google ids read `<10-15 digits>-<lowercase alphanumerics>.apps.googleusercontent.com`.
    private static let clientIDDigitCount = 10...15

    private static let clientIDSuffix = Data(".apps.googleusercontent.com".utf8)
    private static let secretPrefix = Data("GOCSPX-".utf8)

    /// The candidates inside the file, or an empty list when it is missing or unreadable.
    static func candidates(at url: URL) -> [GoogleAIOAuthClient] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return []
        }
        return candidates(in: data)
    }

    /// Every client id crossed with every secret.
    ///
    /// The binary's string pool keeps the ids together and the secrets together, so nothing in the
    /// layout says which id owns which secret. Returning the cross product and letting Google
    /// reject the wrong pair is the only honest reading; guessing a pairing would drop the valid
    /// one whenever the pool happens to be ordered the other way.
    static func candidates(in data: Data) -> [GoogleAIOAuthClient] {
        let clientIDs = clientIDs(in: data)
        let secrets = secrets(in: data)
        return clientIDs.flatMap { clientID in
            secrets.map { GoogleAIOAuthClient(clientID: clientID, clientSecret: $0) }
        }
    }

    private static func secrets(in data: Data) -> [String] {
        var found: [String] = []
        var search = data.startIndex

        while let match = data.range(of: secretPrefix, in: search..<data.endIndex) {
            let end = data.index(match.lowerBound, offsetBy: secretLength, limitedBy: data.endIndex)
            if let end, data[match.upperBound..<end].allSatisfy(isSecretByte) {
                let secret = String(decoding: data[match.lowerBound..<end], as: UTF8.self)
                if !found.contains(secret) {
                    found.append(secret)
                }
            }
            search = match.upperBound
        }
        return found
    }

    private static func clientIDs(in data: Data) -> [String] {
        var found: [String] = []
        var search = data.startIndex

        while let match = data.range(of: clientIDSuffix, in: search..<data.endIndex) {
            if let id = clientID(endingAt: match, in: data), !found.contains(id) {
                found.append(id)
            }
            search = match.upperBound
        }
        return found
    }

    /// Walks back from the `.apps.googleusercontent.com` suffix to the id's own dash and then over
    /// its digits. Both steps matter: the constant preceding an id in the pool (`runtime`, `arena`)
    /// is in the same alphabet, and truncated anywhere else the result is a client Google refuses.
    private static func clientID(endingAt suffix: Range<Data.Index>, in data: Data) -> String? {
        var cursor = suffix.lowerBound
        var dash: Data.Index?

        while cursor > data.startIndex {
            cursor = data.index(before: cursor)
            if data[cursor] == UInt8(ascii: "-") {
                dash = cursor
                break
            }
            guard isLowercaseOrDigit(data[cursor]) else {
                return nil
            }
        }
        guard let dash else {
            return nil
        }

        var start = dash
        while start > data.startIndex {
            let previous = data.index(before: start)
            guard isDigit(data[previous]) else {
                break
            }
            start = previous
        }

        guard clientIDDigitCount.contains(data.distance(from: start, to: dash)) else {
            return nil
        }
        return String(decoding: data[start..<suffix.upperBound], as: UTF8.self)
    }

    private static func isLowercaseOrDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isSecretByte(_ byte: UInt8) -> Bool {
        isLowercaseOrDigit(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
