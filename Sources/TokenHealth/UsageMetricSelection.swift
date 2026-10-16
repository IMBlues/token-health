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
            // Cursor 的三条池按业务上的主次排（Auto → API → Grok Bot），**压过** window 的
            // 通用次序：Grok Bot 是周池、另外两条是月池，光按 window 排会把周池顶到最前面。
            if kind == .cursor {
                let leftLabelRank = cursorLabelRank(lhs.label)
                let rightLabelRank = cursorLabelRank(rhs.label)
                if leftLabelRank != rightLabelRank {
                    return leftLabelRank < rightLabelRank
                }
            }
            // Google AI 的四条额度横跨两个模型组，同理**压过** window：两个组的 5h 会先凑到一起，
            // 把每个组的两条拆散。
            if kind == .googleAI {
                let leftGroupRank = googleAIGroupRank(lhs.label)
                let rightGroupRank = googleAIGroupRank(rhs.label)
                if leftGroupRank != rightGroupRank {
                    return leftGroupRank < rightGroupRank
                }
            }
            let leftRank = rank(lhs)
            let rightRank = rank(rhs)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return (lhs.label ?? lhs.window.title) < (rhs.label ?? rhs.window.title)
        }
    }

    /// Gemini 组排在 Claude & GPT 组前面，认不出来的组（比如部分账号才有的 Argon 池）排最后，
    /// 而不是被当成 Gemini。整名比较，见 `GoogleAIQuotaSummary.groupTitle(inLabel:)`。
    static func googleAIGroupRank(_ label: String?) -> Int {
        guard let label else {
            return 1
        }
        return switch GoogleAIQuotaSummary.groupTitle(inLabel: label) {
        case GoogleAIQuotaSummary.geminiGroupTitle: 0
        case GoogleAIQuotaSummary.thirdPartyGroupTitle: 1
        default: 2
        }
    }

    static func cursorLabelRank(_ label: String?) -> Int {
        switch label {
        case "Auto + Composer":
            0
        case "API":
            1
        case "Grok Bot", "Grokbot":
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

    /// 菜单栏上的条数上限。
    static let menuBarMetricLimit = 3

    /// 菜单栏那根条子要画的指标。
    ///
    /// 默认就是 `pinnedMetrics` —— 每个额度一根。Google AI 是唯一的例外，见下。
    static func menuBarMetrics(from usages: [TokenUsage], kind: ProviderKind) -> [TokenUsage] {
        kind == .googleAI ? googleAIMenuBarMetrics(from: usages) : pinnedMetrics(from: usages, kind: kind)
    }

    /// Google AI 的额度横跨好几个模型组（Gemini、Claude & GPT，外加一部分账号才有的 Argon 池），
    /// 全画上就是五六根长度和颜色都差不多、读不出谁是谁的条子。菜单栏只留每组的 5 小时那根，
    /// 加上 Argon（有的话）正好压在 `menuBarMetricLimit` 以内；周额度和逐模型明细交给卡片和详情浮层。
    static func googleAIMenuBarMetrics(from usages: [TokenUsage]) -> [TokenUsage] {
        let quota = pinnedMetrics(from: usages, kind: .googleAI)
        let fiveHours = quota.filter { $0.window == .fiveHours }
        let argon = quota.filter(isArgonPool)

        var seen = Set<String>()
        return Array(
            (fiveHours + argon)
                .filter { seen.insert($0.id).inserted }
                .prefix(menuBarMetricLimit)
        )
    }

    /// Antigravity 给一部分账号额外开的池（界面上叫 `Gemini 4 Argon`）。它没有固定的组名，
    /// 认 label 里的关键词：认不出来就是没有这个池，那第三根条子自然不出现。
    static func isArgonPool(_ usage: TokenUsage) -> Bool {
        (usage.label ?? "").localizedCaseInsensitiveContains("argon")
    }
}
