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
            .filter { $0.hasPrefix("has") }
            .sorted()
            .map { key -> String in
                let label = String(key.dropFirst(3))
                let value = (object[key] as? Bool) == true ? "yes" : "no"
                return "\(label)=\(value)"
            }
        return "jsAuth \(parts.joined(separator: " "))"
    }
}
