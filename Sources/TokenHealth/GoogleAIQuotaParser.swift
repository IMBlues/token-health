import Foundation

/// What `v1internal:retrieveUserQuotaSummary` reports: the model groups Google meters, and for
/// each one the 5-hour and weekly pools the group's models draw from.
///
/// Every bucket reports what is **left**, never what was spent — [`usages`] is what turns that
/// around into the bars this app draws.
struct GoogleAIQuotaSummary: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        var title: String
        var buckets: [Bucket]
    }

    struct Bucket: Equatable, Sendable {
        var window: UsageWindow
        var remainingFraction: Double
        var resetDate: Date?
    }

    var groups: [Group]

    /// One `TokenUsage` per bucket, labelled `<group> <window>`: two groups share the same two
    /// windows, so the window alone would not tell them apart on a card or in a tooltip.
    var usages: [TokenUsage] {
        groups.flatMap { group in
            let name = Self.shortTitle(group.title)
            return group.buckets.map { bucket in
                // The endpoint reports the complement of what the bar should show. Clamping
                // matters: a fraction outside 0...1 would otherwise draw a bar past full or
                // backwards.
                let remaining = min(max(bucket.remainingFraction, 0), 1)
                return TokenUsage(
                    window: bucket.window,
                    label: "\(name) \(Self.windowLabel(bucket.window))",
                    used: Int(((1 - remaining) * 100).rounded()),
                    limit: 100,
                    resetDate: bucket.resetDate,
                    unit: "%"
                )
            }
        }
    }

    /// Google's group names are sentences ("Claude and GPT models"); a card column and a menu-bar
    /// tooltip need something that fits. Anything unrecognised keeps the server's own wording
    /// rather than being folded into a name that would be a lie.
    static func shortTitle(_ title: String) -> String {
        switch title {
        case geminiGroupServerTitle:
            geminiGroupTitle
        case thirdPartyGroupServerTitle:
            thirdPartyGroupTitle
        default:
            title
        }
    }

    /// The server's own wording, and the short forms this app shows.
    private static let geminiGroupServerTitle = "Gemini Models"
    private static let thirdPartyGroupServerTitle = "Claude and GPT models"
    static let geminiGroupTitle = "Gemini"
    static let thirdPartyGroupTitle = "Claude & GPT"

    private static func windowLabel(_ window: UsageWindow) -> String {
        switch window {
        case .fiveHours: "5h"
        case .week: "Week"
        default: window.title
        }
    }
}

/// One entry of `v1internal:fetchAvailableModels`'s catalogue: the model as Antigravity names it,
/// plus the quota that endpoint folds in.
struct GoogleAIModelQuota: Equatable, Sendable {
    var id: String
    var displayName: String
    var remainingFraction: Double
    var resetDate: Date?
}

enum GoogleAIQuotaParser {
    /// Parses the quota summary. Throws on a payload that is not JSON at all — the caller turns
    /// that into an "unavailable" snapshot — but a structurally valid payload with nothing usable
    /// in it yields no usages, which is a different thing and not an error.
    static func summary(from data: Data) throws -> GoogleAIQuotaSummary {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAIQuotaError.invalidShape
        }
        guard let rawGroups = root["groups"] as? [[String: Any]] else {
            return GoogleAIQuotaSummary(groups: [])
        }

        let groups = rawGroups.map { raw -> GoogleAIQuotaSummary.Group in
            let buckets = (raw["buckets"] as? [[String: Any]] ?? []).compactMap(bucket(from:))
            return GoogleAIQuotaSummary.Group(
                title: raw["displayName"] as? String ?? "",
                buckets: buckets
            )
        }

        return GoogleAIQuotaSummary(groups: groups)
    }

    /// The catalogue, least quota left first: the popover's table is about what is about to run
    /// out, not about what Antigravity recommends. Models the catalogue does not describe — no
    /// display name, or no quota — are left out rather than shown as an opaque id.
    /// Never throws: the catalogue only feeds the popover's table, so a payload that cannot be
    /// read costs that table and nothing else.
    static func models(from data: Data) -> [GoogleAIModelQuota] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["models"] as? [String: Any] else {
            return []
        }

        let recommendedOrder = recommendedModelOrder(in: root)
        let models = rawModels.compactMap { id, value -> GoogleAIModelQuota? in
            guard let entry = value as? [String: Any],
                  let displayName = entry["displayName"] as? String,
                  !displayName.isEmpty,
                  let quota = entry["quotaInfo"] as? [String: Any],
                  let fraction = doubleValue(quota["remainingFraction"]) else {
                return nil
            }
            return GoogleAIModelQuota(
                id: id,
                displayName: displayName,
                remainingFraction: min(max(fraction, 0), 1),
                resetDate: (quota["resetTime"] as? String).flatMap(parseDate)
            )
        }

        return models.sorted { lhs, rhs in
            if lhs.remainingFraction != rhs.remainingFraction {
                return lhs.remainingFraction < rhs.remainingFraction
            }
            let left = recommendedOrder[lhs.id] ?? Int.max
            let right = recommendedOrder[rhs.id] ?? Int.max
            if left != right {
                return left < right
            }
            return lhs.displayName < rhs.displayName
        }
    }

    /// Flattens `agentModelSorts[].groups[].modelIds` into `id -> index`, so ties in remaining
    /// quota come back in the order Antigravity itself lists the models.
    private static func recommendedModelOrder(in root: [String: Any]) -> [String: Int] {
        guard let sorts = root["agentModelSorts"] as? [[String: Any]] else {
            return [:]
        }

        var order: [String: Int] = [:]
        for sort in sorts {
            for group in sort["groups"] as? [[String: Any]] ?? [] {
                for id in group["modelIds"] as? [String] ?? [] where order[id] == nil {
                    order[id] = order.count
                }
            }
        }
        return order
    }

    private static func bucket(from raw: [String: Any]) -> GoogleAIQuotaSummary.Bucket? {
        guard let window = window(from: raw["window"] as? String),
              let fraction = doubleValue(raw["remainingFraction"]) else {
            return nil
        }
        return GoogleAIQuotaSummary.Bucket(
            window: window,
            remainingFraction: fraction,
            resetDate: (raw["resetTime"] as? String).flatMap(parseDate)
        )
    }

    /// Google's two rolling pools, by the names the summary uses for them. An unrecognised window
    /// is dropped: guessing which one a new name means would put the wrong number behind a bar.
    private static func window(from raw: String?) -> UsageWindow? {
        switch raw {
        case "5h": .fiveHours
        case "weekly": .week
        default: nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    enum GoogleAIQuotaError: LocalizedError {
        case invalidShape

        var errorDescription: String? {
            switch self {
            case .invalidShape: "Google AI returned a payload this app cannot read"
            }
        }
    }
}
