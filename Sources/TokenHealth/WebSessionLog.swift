import Foundation

enum WebSessionLog {
    nonisolated static func debugLog(_ message: String, providerTitle: String) {
        guard ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1" else {
            return
        }
        print("[TokenHealth][\(providerTitle)] \(message)")
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
