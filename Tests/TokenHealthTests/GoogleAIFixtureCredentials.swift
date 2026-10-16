import Foundation

/// Synthetic OAuth credentials for the Google AI scanner tests.
///
/// The scanner is exercised against a stand-in binary, so the fixture only has to look like the
/// real constants: a numeric client-id prefix plus the Google suffix, and a 35-byte `GOCSPX-`
/// secret. The parts are joined at runtime so that this public repository never carries a string
/// that a secret scanner could mistake for a live Google OAuth credential.
enum GoogleAIFixtureCredentials {
    static let clientIDOne = "1000000000-" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + ".apps.googleusercontent.com"
    static let clientIDTwo = "2000000000-" + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" + ".apps.googleusercontent.com"
    static let clientIDPrefixOne = "1000000000" + "-"
    static let clientIDPrefixTwo = "2000000000" + "-"
    static let secretOne = "GOCSPX-" + "AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static let secretTwo = "GOCSPX-" + "BBBBBBBBBBBBBBBBBBBBBBBBBBBB"
}
