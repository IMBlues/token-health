import Foundation

/// 额度指标的判定与排序。菜单卡片与钉住的菜单栏项共用同一份，
/// 保证两处对「哪些算额度窗口、按什么顺序」的理解一致。
enum UsageMetricSelection {
    /// Codex 的模型额度桶 label 形如 `gpt-5 · 5h`，不算账号级指标。
    static func isAccountLevel(_ usage: TokenUsage) -> Bool {
        usage.label == nil || usage.label?.contains(" · ") == false
    }

    static func isTokenTotal(_ usage: TokenUsage) -> Bool {
        (usage.label ?? "").lowercased().contains("total")
    }

    static func isTodayTotal(_ usage: TokenUsage) -> Bool {
        (usage.label ?? "").lowercased().contains("total")
    }

    /// 有比例可画的额度窗口：5h / 周 / 月 / MCP 月 / 视频赠送，外加总额度（`tokenQuota`，
    /// GenericHTTP 一类的 `total_used` / `total_granted`）。
    ///
    /// `tokenQuota` 必须算进来：卡片对它也是画进度条的（`primaryUsages` 让 `.tokenQuota` 通过，
    /// 只要有 ratio 就渲染 ProgressView）。少算它会让同一个窗口在卡片上有比例、在钉住项上却是空槽。
    /// 余额、今日用量、7 日明细则是计数或金额，本来就没有比例。
    static func isQuotaWindow(_ usage: TokenUsage) -> Bool {
        switch usage.window {
        case .fiveHours, .week, .month, .mcpMonth, .videoGift, .tokenQuota:
            true
        case .balance, .todayCost, .todayTokens, .todayRequests,
             .sevenDaysTokens, .sevenDaysTools:
            false
        }
    }

    static func rank(_ usage: TokenUsage) -> Int {
        switch usage.window {
        case .balance:
            0
        case .tokenQuota:
            4
        case .todayCost:
            1
        case .todayTokens:
            2
        case .todayRequests:
            3
        case .fiveHours:
            10
        case .week:
            11
        case .month:
            12
        case .mcpMonth:
            13
        case .videoGift:
            14
        case .sevenDaysTokens:
            isTokenTotal(usage) ? 15 : 20
        case .sevenDaysTools:
            30
        }
    }

    static func sorted(_ usages: [TokenUsage], kind: ProviderKind) -> [TokenUsage] {
        usages.sorted { lhs, rhs in
            let leftRank = rank(lhs)
            let rightRank = rank(rhs)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if kind == .cursor, lhs.window == .month, rhs.window == .month {
                let leftLabelRank = cursorLabelRank(lhs.label)
                let rightLabelRank = cursorLabelRank(rhs.label)
                if leftLabelRank != rightLabelRank {
                    return leftLabelRank < rightLabelRank
                }
            }
            return (lhs.label ?? lhs.window.title) < (rhs.label ?? rhs.window.title)
        }
    }

    static func cursorLabelRank(_ label: String?) -> Int {
        switch label {
        case "Auto + Composer":
            0
        case "API":
            1
        case "Grokbot", "Grokbot (included in Auto)":
            2
        default:
            3
        }
    }

    /// 钉住项要画的全部额度指标，按显示顺序。
    ///
    /// 没有 `limit` 的窗口会被跳过：卡片在这种情况下根本不画进度条，
    /// 钉住项若画一根空槽，会被读成「用了 0%」而不是「不知道」。
    static func pinnedMetrics(from usages: [TokenUsage], kind: ProviderKind) -> [TokenUsage] {
        let quota = usages.filter { usage in
            guard isQuotaWindow(usage), usage.ratio != nil else {
                return false
            }
            return kind == .codex ? isAccountLevel(usage) : true
        }
        return sorted(quota, kind: kind)
    }
}
