import Foundation

/// What this app tells the Cloud Code backend it is.
///
/// The backend reads a version off the `User-Agent` and narrows its answer for a client it does
/// not recognise. `antigravity` on its own is answered as an old client: `fetchAvailableModels`
/// and `retrieveUserQuota` both came back with 29 models where `antigravity/2.23.1` came back with
/// 35 — Gemini 3.7 and 3.8 Flash were missing — and on the daily host a whole quota group
/// disappeared. Sending the installed version is not cosmetic; it is the difference between the
/// account's real catalogue and a trimmed one.
///
/// The name still has to be Antigravity. A `User-Agent` without it is answered as an unsupported
/// client: `loadCodeAssist` returns an `UNSUPPORTED_CLIENT` tier, withholds the project, and every
/// quota call after it is a 403.
enum GoogleAIClientIdentity {
    static func userAgent(version: String?) -> String {
        guard let version, !version.isEmpty else {
            return "antigravity"
        }
        return "antigravity/\(version)"
    }

    /// The version of the app the language server ships inside. `nil` when the binary is not in an
    /// `.app` bundle — a test fixture, or a build someone unzipped — and the caller falls back to
    /// the bare name.
    static func installedVersion(executableAt url: URL) -> String? {
        var directory = url.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if directory.pathExtension == "app" {
                return version(inInfoPlistAt: directory.appendingPathComponent("Contents/Info.plist"))
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func version(inInfoPlistAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let fields = plist as? [String: Any],
              let version = fields["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return nil
        }
        return version
    }
}
