import Foundation

enum WebSessionLog {
    nonisolated static func debugLog(_ message: String, providerTitle: String) {
        guard ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1" else {
            return
        }
        print("[TokenHealth][\(providerTitle)] \(message)")
    }

    /// Always printed, unlike `debugLog`: a failed profile removal means a deleted account's
    /// cookies and localStorage stay on disk, which should be visible without a debug flag.
    nonisolated static func error(_ message: String, providerTitle: String) {
        print("[TokenHealth][\(providerTitle)] ERROR \(message)")
    }

    /// Joins the envelope's `hasXxx` booleans into a one-line summary, for diagnosing
    /// unauthenticated fetches.
    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let parts = object.keys
            .sorted()
            .compactMap { key -> String? in
                guard key.hasPrefix("has"), let flag = object[key] as? Bool else {
                    return nil
                }
                return "\(key.dropFirst(3))=\(flag ? "yes" : "no")"
            }
        return "jsAuth \(parts.joined(separator: " "))"
    }
}
