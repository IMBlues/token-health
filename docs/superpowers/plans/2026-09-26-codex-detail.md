# Codex 用量详情浮层 实现计划

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 点钉住的 Codex 菜单栏项弹出详情浮层：5 小时 / 周额度百分比、Today / 7 days / 30 days 的 token 汇总、30 天每日 token 趋势、Lifetime / Peak day / Streak / Longest turn。

**Architecture:** 沿用 DeepSeek / OpenCode Go 铺好的通用详情链路（`UsageDetail` → `ProviderUsageSnapshot.detail` → `DetailPopoverView`，视图层零改动）。取数完全复用既有的本地 Codex 登录：**同一个 `codex app-server` 会话里多发一条 `account/usage/read`**（`CodexQuotaRPC` 从三条报文变四条，会话从「等一个响应 id」变「等一组 id」），一次进程往返拿到两份数据。额度是必需项、用量是可选区块：用量那条 RPC 报错或解不出只让详情少画用量区块；完全无应答则是会话超时，整次刷新失败（与今天同路）。

**Tech Stack:** Swift 6 / swift-tools 6.0、SwiftUI（macOS 14+）、swift-testing（`import Testing`、`@Test` / `#expect` / `Issue.record`）、无第三方依赖。

**Spec:** `docs/superpowers/specs/2026-09-26-codex-detail-design.md`

---

## 前置约束

- **分支**：当前在 `feature/opencode-go-detail`（已含 OpenCode Go 详情的 22 个提交，干净）。**不要新建分支**：两个详情一起进 1.0.3。
- **版本号**：`AppSupport/Info.plist` 已经是 `1.0.3`，**本次不动**，也不要出 dmg。
- **跑测试**：一律 `bash scripts/test.sh`；过滤用 `bash scripts/test.sh --filter <SuiteName>`（本机只有 CommandLineTools，裸跑 `swift test` 会因 `no such module 'Testing'` 假失败）。
- **注释语言**：`CodexUsageProvider.swift` 现在**一条注释都没有**，新增注释按同族文件（`OpenCodeGo*.swift`）的英文风格写；`Providers.swift` 是中文注释，改那里的注释也用中文；**新建的源码文件用英文注释，新建的测试文件用中文注释**（`Tests/` 目录的惯例）。计划里的代码块已按此写死。
- **提交**：每个任务一个提交，message 用陈述句（不带 `feat:` 前缀），结尾固定一行：
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- 只用显式路径 `git add`，**不要 `git add -A`**。
- 每个提交都必须能编译、能通过测试。

## 文件结构

**新增**

| 文件 | 职责 |
| --- | --- |
| `Sources/TokenHealth/CodexUsageDetail.swift` | `account/usage/read` 响应 + 额度 usages → `UsageDetail`（纯计算，不抛错） |
| `Tests/TokenHealthTests/CodexUsageDetailTests.swift` | 详情构建的各区块与边界 |

**修改**

| 文件 | 改动 |
| --- | --- |
| `Sources/TokenHealth/CodexUsageProvider.swift` | 新增 `CodexAccountUsageResponse` 三个解码类型；`CodexQuotaRPC` 四条报文；会话等一组 id；`CodexQuotaBundle` + `fetchQuotaBundle()`（删 `fetchRateLimits()`）；缓存换 bundle；`snapshot(config:bundle:fetchedAt:today:)` 接缝 + 详情接线 |
| `Sources/TokenHealth/Providers.swift` | `producesUsageDetail` 加 `.codex` |
| `Tests/TokenHealthTests/CodexUsageProviderTests.swift` | 解码测试；`snapshot` 接缝测试；会话层新旧分支；缓存；allowlist 断言更新 |
| `Tests/TokenHealthTests/CodexTestSupport.swift` | 假 app-server 助手参数化（回应列表 + 短超时），两个助手迁移到 `fetchQuotaBundle()` |
| `Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift` | `.codex` 两种 authMode；例外集合 |
| `README.md` / `README.en.md` | 详情浮层那一段补 Codex |

---

## Chunk 1: 详情构建（纯函数，不碰进程）

### Task 1: `account/usage/read` 的解码类型

**背景**：协议里 `summary` 是 required、bucket 的 `startDate` / `tokens` 也是 required，但我们一律按可缺解码（spec §4.1）——缺一个字段只该少画一段，不该让整份响应作废。数字沿用文件里已有的 `decodeFlexibleInt64IfPresent`（容忍数字写成字符串）。

**Files:**
- Modify: `Sources/TokenHealth/CodexUsageProvider.swift`（加在 `CodexRateLimitsResponse` 那一组类型旁边）
- Test: `Tests/TokenHealthTests/CodexUsageProviderTests.swift`

- [ ] **Step 1: 写失败的测试**

在 `Tests/TokenHealthTests/CodexUsageProviderTests.swift` 的 `CodexUsageProviderTests` 里（`testRateLimitMappingKeepsMainAndNamedQuotaBuckets` 之后任意位置）追加：

```swift
    @Test
    func decodesAccountUsageWithSparseBuckets() throws {
        let json = """
        {
          "summary": {
            "lifetimeTokens": 172532345, "peakDailyTokens": 117865819,
            "longestRunningTurnSec": 2550, "currentStreakDays": 3, "longestStreakDays": 3
          },
          "dailyUsageBuckets": [
            { "startDate": "2026-06-17", "tokens": 283242 },
            { "startDate": "2026-09-23", "tokens": "117865819" }
          ]
        }
        """

        let response = try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data(json.utf8))

        #expect(response.summary?.lifetimeTokens == 172532545 - 200)
        #expect(response.summary?.peakDailyTokens == 117865819)
        #expect(response.summary?.longestRunningTurnSec == 2550)
        #expect(response.summary?.currentStreakDays == 3)
        // 数字写成字符串也收（console 与 RPC 都可能这么给）。
        #expect(response.dailyUsageBuckets?.map(\.tokens) == [283242, 117865819])
        #expect(response.dailyUsageBuckets?.map(\.startDate) == ["2026-06-17", "2026-09-23"])
    }

    @Test
    func accountUsageToleratesMissingAndMalformedFields() throws {
        // 整份响应里什么都不认得的键 → 三个字段全 nil，但解码本身不抛。
        let empty = try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data("{}".utf8))
        #expect(empty.summary == nil)
        #expect(empty.dailyUsageBuckets == nil)

        // 数组里混进一个非对象元素：那一条退化成「日期与 tokens 都缺」，其余照常解出来。
        let mixed = """
        { "dailyUsageBuckets": [ "nonsense", { "startDate": "2026-09-25", "tokens": 5 } ] }
        """
        let response = try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data(mixed.utf8))
        #expect(response.dailyUsageBuckets?.count == 2)
        #expect(response.dailyUsageBuckets?.first?.startDate == nil)
        #expect(response.dailyUsageBuckets?.first?.tokens == nil)
        #expect(response.dailyUsageBuckets?.last?.tokens == 5)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: 编译失败，`cannot find 'CodexAccountUsageResponse' in scope`。

- [ ] **Step 3: 写实现**

在 `Sources/TokenHealth/CodexUsageProvider.swift` 里 `struct CodexRateLimitsResponse` **之前**插入：

```swift
/// The `account/usage/read` result. The protocol marks most of these fields required, but a
/// missing one only costs the matching detail section, so everything decodes leniently.
struct CodexAccountUsageResponse: Decodable, Sendable {
    let summary: CodexAccountUsageSummary?
    let dailyUsageBuckets: [CodexAccountUsageDay]?
}

struct CodexAccountUsageSummary: Decodable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
}

/// One day's total. Both fields are optional so that a single unusable entry (a bare string in
/// the array, a missing key) cannot fail the whole array — the detail builder skips it instead.
struct CodexAccountUsageDay: Decodable, Sendable {
    let startDate: String?
    let tokens: Int64?

    private enum CodingKeys: String, CodingKey {
        case startDate
        case tokens
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            startDate = nil
            tokens = nil
            return
        }
        startDate = try? container.decodeIfPresent(String.self, forKey: .startDate)
        tokens = container.decodeFlexibleInt64IfPresent(forKey: .tokens)
    }
}
```

> `CodexAccountUsageSummary` 用合成的 `init(from:)`：它的键都是可选的，所以某个字段类型不对只会让它变 nil（`decodeIfPresent` 遇到类型不匹配抛错 → 整个 `summary` 解不出 → 上层把整份响应当不可用），这正是 spec §4.1 要的行为。
> `decodeFlexibleInt64IfPresent` 是文件底部 `private extension KeyedDecodingContainer` 里的方法，同文件可见。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/CodexUsageProvider.swift Tests/TokenHealthTests/CodexUsageProviderTests.swift
git commit -F - <<'MSG'
Decode the Codex account usage response leniently

Every field is optional so a missing or malformed one only costs the
matching detail section instead of the whole response.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```

---

### Task 2: `CodexUsageDetail` 的 headline 与 breakdown

**背景**：headline 必须与菜单栏项同源 —— 直接复用 `UsageMetricSelection.pinnedMetrics(kind: .codex)`（它只放账号级窗口、排除 `gpt-5 · 5h` 这类模型桶）与 `MenuBarMetrics.shortLabel` / `UsageAmountFormatter.exactAmountText`，不自己写窗口列表或百分比格式。

**Files:**
- Create: `Sources/TokenHealth/CodexUsageDetail.swift`
- Create: `Tests/TokenHealthTests/CodexUsageDetailTests.swift`

- [ ] **Step 1: 写失败的测试**

新建 `Tests/TokenHealthTests/CodexUsageDetailTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

@Suite
struct CodexUsageDetailTests {
    /// 2026-09-25T00:00:00Z —— 30 天窗口是 8/27 … 9/25。
    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    /// 与 `CodexRateLimitsMapper` 产出的形状一致：账号级窗口 label 为 nil、unit 是 `%`。
    private func quotaUsages() -> [TokenUsage] {
        [
            TokenUsage(window: .fiveHours, used: 12, limit: 100, resetDate: nil, unit: "%"),
            TokenUsage(window: .week, used: 58, limit: 100, resetDate: nil, unit: "%")
        ]
    }

    private func usageResponse(_ json: String) throws -> CodexAccountUsageResponse {
        try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data(json.utf8))
    }

    private var fullSummary: String {
        """
        "summary": {
          "lifetimeTokens": 172532345, "peakDailyTokens": 117865819,
          "longestRunningTurnSec": 2550, "currentStreakDays": 3, "longestStreakDays": 3
        }
        """
    }

    @Test
    func headlineMirrorsThePinnedMenuBarMetrics() throws {
        let detail = try #require(CodexUsageDetail.make(
            usage: nil,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.headline.map(\.label) == ["5h", "Week"])
        #expect(detail.headline.map(\.value) == ["12%", "58%"])
        // 用量响应缺席时不该凭空造出别的区块。
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.table == nil)
    }

    @Test
    func headlineSkipsModelBucketsAndDuplicateLabels() throws {
        let usages = quotaUsages() + [
            // 模型桶（label 带 " · "）不算账号级指标，不进 headline。
            TokenUsage(window: .fiveHours, label: "gpt-5 · 5h", used: 3, limit: 100, unit: "%"),
            // 两个窗口折出同一个 label：DetailStat.id == label，集合内必须唯一，只留第一条。
            TokenUsage(window: .fiveHours, label: "1h30m", used: 40, limit: 100, unit: "%"),
            TokenUsage(window: .week, label: "1h30m", used: 70, limit: 100, unit: "%")
        ]

        let detail = try #require(CodexUsageDetail.make(usage: nil, usages: usages, today: today))

        #expect(detail.headline.map(\.label) == ["5h", "Week", "1h30m"])
        #expect(detail.headline.map(\.value) == ["12%", "58%", "40%"])
    }

    @Test
    func breakdownCoversTheAccountTotals() throws {
        let response = try usageResponse("{ \(fullSummary) }")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.breakdown.map(\.label) == ["Lifetime", "Peak day", "Streak", "Longest turn"])
        #expect(detail.breakdown.map(\.value) == ["172.53M", "117.87M", "3d", "42m"])
    }

    @Test
    func breakdownFormatsDurationsAndDropsBadNumbers() throws {
        let response = try usageResponse("""
        { "summary": {
            "longestRunningTurnSec": 42, "currentStreakDays": 0, "peakDailyTokens": -5
        } }
        """)

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        // 负数是坏数据，不占位；0 天的连续记录是真的 0，照画。
        #expect(detail.breakdown.map(\.label) == ["Streak", "Longest turn"])
        #expect(detail.breakdown.map(\.value) == ["0d", "42s"])
    }

    @Test
    func everyBlockCanBeAbsent() throws {
        // 用量响应解得出、但一个统计字段都没有，也没有 buckets → 只剩 headline。
        let response = try usageResponse("{}")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.headline.count == 2)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.groups.isEmpty)

        // 额度与用量都填不出来 → nil（浮层退回错误行）。
        #expect(CodexUsageDetail.make(usage: nil, usages: [], today: today) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter CodexUsageDetailTests`
Expected: 编译失败，`cannot find 'CodexUsageDetail' in scope`。

- [ ] **Step 3: 写实现**

新建 `Sources/TokenHealth/CodexUsageDetail.swift`：

```swift
import Foundation

/// Turns one account usage response plus the snapshot's quota usages into the `UsageDetail` the
/// pinned-item popover draws.
///
/// Never throws: a missing response or a missing field only removes the matching section, and a
/// detail with nothing to draw is nil so the popover falls back to its error line.
enum CodexUsageDetail {
    static let dayFormat = "yyyy-MM-dd"
    static let axisDateFormat = "M/d"
    static let rangeDays = 30

    static func make(
        usage: CodexAccountUsageResponse?,
        usages: [TokenUsage],
        today: Date
    ) -> UsageDetail? {
        var detail = UsageDetail()
        detail.headline = headline(from: usages)
        detail.breakdown = breakdown(usage?.summary)

        return detail.isEmpty ? nil : detail
    }

    // MARK: - headline

    /// The same windows the pinned menu-bar item draws bars for, formatted by the same helpers,
    /// so the popover and the tooltip can never disagree.
    private static func headline(from usages: [TokenUsage]) -> [DetailStat] {
        var seen = Set<String>()
        return UsageMetricSelection.pinnedMetrics(from: usages, kind: .codex).compactMap { usage in
            let label = MenuBarMetrics.shortLabel(for: usage)
            // `DetailStat.id` is the label, so two windows folding to the same name would break
            // the popover's `ForEach`. Keep the first.
            guard seen.insert(label).inserted else {
                return nil
            }
            return DetailStat(label: label, value: UsageAmountFormatter.exactAmountText(usage))
        }
    }

    // MARK: - breakdown

    private static func breakdown(_ summary: CodexAccountUsageSummary?) -> [DetailStat] {
        guard let summary else {
            return []
        }

        var stats: [DetailStat] = []
        if let lifetime = nonNegative(summary.lifetimeTokens) {
            stats.append(DetailStat(label: "Lifetime", value: UsageAmountFormatter.compactAmount(lifetime)))
        }
        if let peak = nonNegative(summary.peakDailyTokens) {
            stats.append(DetailStat(label: "Peak day", value: UsageAmountFormatter.compactAmount(peak)))
        }
        if let streak = nonNegative(summary.currentStreakDays) {
            stats.append(DetailStat(label: "Streak", value: "\(streak)d"))
        }
        if let seconds = nonNegative(summary.longestRunningTurnSec) {
            stats.append(DetailStat(label: "Longest turn", value: durationText(seconds: seconds)))
        }
        return stats
    }

    /// A negative count is bad data, not a small number: it drops the row instead of rendering
    /// `-3d`. Zero is real and stays.
    private static func nonNegative(_ value: Int64?) -> Int? {
        guard let value, value >= 0, let converted = Int(exactly: value) else {
            return nil
        }
        return converted
    }

    /// `42s` below a minute, `42m` below an hour, then `1h` / `1h 5m`.
    private static func durationText(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m"
        }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter CodexUsageDetailTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/CodexUsageDetail.swift Tests/TokenHealthTests/CodexUsageDetailTests.swift
git commit -F - <<'MSG'
Build the Codex detail headline and account totals

Headline reuses the pinned menu-bar metrics so the popover and the
tooltip cannot drift apart; the totals row drops bad numbers rather than
rendering them.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```

---

### Task 3: `CodexUsageDetail` 的 groups 与 series

**背景**：buckets 是**稀疏**的（只有有量的日子），30 天窗口要自己补齐、越界与解不出的条目整条忽略、同日多条求和用饱和加法；`dailyUsageBuckets` 为 **nil** 时不画这两段，为空**数组**时照画全 0。

**Files:**
- Modify: `Sources/TokenHealth/CodexUsageDetail.swift`
- Test: `Tests/TokenHealthTests/CodexUsageDetailTests.swift`

- [ ] **Step 1: 写失败的测试**

在 `CodexUsageDetailTests` 里追加：

```swift
    /// 稀疏 buckets：今天两条（求和）、7 天窗口边界 9/19 一条、窗口内更早的 9/18 一条、
    /// 窗口外的 8/26 一条。窗口是 8/27 … 9/25。
    private var sparseBuckets: String {
        """
        "dailyUsageBuckets": [
          { "startDate": "2026-08-26", "tokens": 7000000 },
          { "startDate": "2026-09-18", "tokens": 900000 },
          { "startDate": "2026-09-19", "tokens": 300000 },
          { "startDate": "2026-09-24", "tokens": 500000 },
          { "startDate": "2026-09-25", "tokens": 1200000 },
          { "startDate": "2026-09-25", "tokens": 800000 }
        ]
        """
    }

    @Test
    func groupsSumSparseBucketsIntoTodaySevenAndThirtyDays() throws {
        let response = try usageResponse("{ \(sparseBuckets) }")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        #expect(detail.groups.map(\.title) == ["Today", "7 days", "30 days"])
        // 今天 1.2M + 0.8M；7 天含 9/19 起（300K + 500K + 2M）；30 天再加 9/18 的 900K。
        // 8/26 那 7M 落在窗口外，不进任何一行。
        #expect(detail.groups.map { $0.values.map(\.label) } == [["Tokens"], ["Tokens"], ["Tokens"]])
        #expect(detail.groups.map { $0.values[0].value } == ["2M", "2.8M", "3.7M"])
    }

    @Test
    func seriesCoversThirtyDaysWithGapsFilledByZero() throws {
        let response = try usageResponse("{ \(sparseBuckets) }")

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        let series = try #require(detail.series)
        #expect(series.points.count == 30)
        #expect(series.title == "Tokens · last 30 days")
        #expect(series.emptyText == "No usage in the last 30 days")
        #expect(series.axisStart == "8/27")
        #expect(series.axisEnd == "9/25")
        // 没有 bucket 的日子补 0；窗口外的 8/26 不许漏进第一天。
        #expect(series.points.first?.value == 0)
        #expect(series.points.last?.value == 2_000_000)
        #expect(series.points.map(\.value).reduce(0, +) == 3_700_000)
    }

    @Test
    func emptyBucketsDrawZeroRowsButMissingBucketsDrawNothing() throws {
        let empty = try usageResponse("{ \(fullSummary), \"dailyUsageBuckets\": [] }")
        let emptyDetail = try #require(CodexUsageDetail.make(
            usage: empty,
            usages: quotaUsages(),
            today: today
        ))
        #expect(emptyDetail.groups.map { $0.values[0].value } == ["0", "0", "0"])
        #expect(emptyDetail.series?.points.count == 30)
        #expect(emptyDetail.series?.points.allSatisfy { $0.value == 0 } == true)

        // 键缺席（老后端 / 那次调用失败）→ 两段都不画。
        let missing = try usageResponse("{ \(fullSummary) }")
        let missingDetail = try #require(CodexUsageDetail.make(
            usage: missing,
            usages: quotaUsages(),
            today: today
        ))
        #expect(missingDetail.groups.isEmpty)
        #expect(missingDetail.series == nil)
        #expect(missingDetail.breakdown.count == 4)
    }

    @Test
    func bucketsOutsideTheWindowAndUnusableOnesAreIgnored() throws {
        let response = try usageResponse("""
        { "dailyUsageBuckets": [
            { "startDate": "2026-09-25T00:00:00Z", "tokens": 1000 },
            { "startDate": "not a date", "tokens": 999999 },
            { "startDate": "2026-09-20", "tokens": null },
            "nonsense"
        ] }
        """)

        let detail = try #require(CodexUsageDetail.make(
            usage: response,
            usages: quotaUsages(),
            today: today
        ))

        // 只有第一条可用：日期前缀能解析，tokens 才算数。
        #expect(detail.groups.map { $0.values[0].value } == ["1K", "1K", "1K"])
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter CodexUsageDetailTests`
Expected: 失败 —— `groups` 为空、`series` 为 nil（`#require(detail.series)` 报错）。

- [ ] **Step 3: 写实现**

在 `CodexUsageDetail.swift` 的 `make` 里，把 `detail.breakdown = ...` 那行**之前**插入两段（完整形态见下），并补齐辅助函数：

```swift
        detail.headline = headline(from: usages)

        // `nil` means the usage read failed or an old backend omits it: no window to draw.
        // An empty array means "no usage in these 30 days" and draws zero rows.
        if let buckets = usage?.dailyUsageBuckets {
            let calendar = utcCalendar()
            let dayRange = dayList(today: today, calendar: calendar)
            if !dayRange.isEmpty {
                let byDay = dayTotals(from: buckets, allowed: Set(dayRange), calendar: calendar)
                detail.groups = groups(dayRange: dayRange, byDay: byDay)
                detail.series = series(dayRange: dayRange, byDay: byDay, calendar: calendar)
            }
        }
        detail.breakdown = breakdown(usage?.summary)
```

然后在 `// MARK: - breakdown` 之前插入：

```swift
    // MARK: - groups and series

    private static func groups(dayRange: [Date], byDay: [Date: Int]) -> [DetailGroup] {
        guard let today = dayRange.last else {
            return []
        }

        var last7 = 0
        var last30 = 0
        for (index, date) in dayRange.enumerated() {
            let tokens = byDay[date] ?? 0
            last30 = saturatingAdd(last30, tokens)
            if index >= dayRange.count - 7 {
                last7 = saturatingAdd(last7, tokens)
            }
        }

        return [
            DetailGroup(title: "Today", values: values(byDay[today] ?? 0)),
            DetailGroup(title: "7 days", values: values(last7)),
            DetailGroup(title: "30 days", values: values(last30))
        ]
    }

    private static func values(_ tokens: Int) -> [DetailStat] {
        [DetailStat(label: "Tokens", value: UsageAmountFormatter.compactAmount(tokens))]
    }

    private static func series(dayRange: [Date], byDay: [Date: Int], calendar: Calendar) -> DetailSeries {
        let points = dayRange.map { date in
            DetailSeriesPoint(date: date, value: Double(byDay[date] ?? 0))
        }
        let formatter = axisDateFormatter(calendar: calendar)
        return DetailSeries(
            title: "Tokens · last 30 days",
            points: points,
            axisStart: dayRange.first.map { formatter.string(from: $0) } ?? "",
            axisEnd: dayRange.last.map { formatter.string(from: $0) } ?? "",
            emptyText: "No usage in the last 30 days"
        )
    }

    // MARK: - aggregation and dates

    private static func dayTotals(
        from buckets: [CodexAccountUsageDay],
        allowed: Set<Date>,
        calendar: Calendar
    ) -> [Date: Int] {
        var byDay: [Date: Int] = [:]
        for bucket in buckets {
            // A bucket missing its date or its tokens is dropped, not counted as zero: zero means
            // "no usage that day", a missing field means "unknown".
            guard let tokens = bucket.tokens,
                  let date = date(fromDay: bucket.startDate, calendar: calendar),
                  allowed.contains(date) else {
                continue
            }
            byDay[date] = saturatingAdd(byDay[date] ?? 0, Int(clamping: tokens))
        }
        return byDay
    }

    /// A malformed or hostile bucket must degrade, never trap — the builder promises not to crash
    /// on data it did not produce.
    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs > 0 ? Int.max : Int.min) : sum
    }

    /// `[today - 29, today]`, one entry per UTC day.
    private static func dayList(today: Date, calendar: Calendar) -> [Date] {
        let last = calendar.startOfDay(for: today)
        guard let first = calendar.date(byAdding: .day, value: -(rangeDays - 1), to: last) else {
            return []
        }

        var days: [Date] = []
        var cursor = first
        while cursor <= last {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return days
    }

    /// Parses the first 10 characters, so `"2026-09-25T00:00:00Z"` works too.
    private static func date(fromDay value: String?, calendar: Calendar) -> Date? {
        guard let value, value.count >= 10 else {
            return nil
        }
        return dateFormatter(calendar: calendar).date(from: String(value.prefix(10)))
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private static func dateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dayFormat
        return formatter
    }

    private static func axisDateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = axisDateFormat
        return formatter
    }
```

最后把文件头的 `static let dayFormat` / `axisDateFormat` / `rangeDays` 保留在 `make` 上方即可（它们已经在 Task 2 写好）。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter CodexUsageDetailTests`
Expected: PASS（同时 `bash scripts/test.sh` 全绿）。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/CodexUsageDetail.swift Tests/TokenHealthTests/CodexUsageDetailTests.swift
git commit -F - <<'MSG'
Fill the Codex detail windows from the sparse daily buckets

The buckets only carry the days that had usage, so the 30-day window is
rebuilt here: gaps become zero, rows outside it are dropped, and an
absent bucket list draws nothing while an empty one draws zeros.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```

---

## Chunk 2: 取数层（一次会话、两条请求）

### Task 4: `CodexQuotaRPC` 变成四条报文

**Files:**
- Modify: `Sources/TokenHealth/CodexUsageProvider.swift:161-188`（`enum CodexQuotaRPC`）
- Test: `Tests/TokenHealthTests/CodexUsageProviderTests.swift:110-145`（allowlist 测试）

- [ ] **Step 1: 先改 allowlist 测试（会失败）**

把 `testQuotaRPCUsesOnlyTheReadOnlyAllowlist` 里这三处改掉（其余逐字不动）：

```swift
        #expect(summary.methods == [
            "initialize",
            "initialized",
            "account/rateLimits/read",
            "account/usage/read"
        ])
```

```swift
        #expect(summary.keySets.count == 4)
        #expect(summary.keySets[0] == ["id", "method", "params"])
        #expect(summary.keySets[1] == ["method"])
        #expect(summary.keySets[2] == ["id", "method"])
        #expect(summary.keySets[3] == ["id", "method"])
```

```swift
        // `account/usage/read` 与 `account/rateLimits/read` 同属只读账号方法，是本次有意放行的
        // 唯一一项；其余禁用项逐字保留 —— 少一条也照样全绿，所以下面再钉一次条数。
        let forbiddenMethods = [
            "account/read",
            "account/login",
            "account/logout",
            "account/rateLimitResetCredit/consume",
            "account/sendAddCreditsNudgeEmail",
            "capabilities",
            "experimentalApi",
            "thread/",
            "fs/",
            "config/",
            "plugin/"
        ]
        #expect(forbiddenMethods.count == 11)
        for forbiddenMethod in forbiddenMethods {
            #expect(!summary.wireText.contains(forbiddenMethod))
        }
```

> **注意**：这 11 项是从原列表里**只删 `account/usage/read`** 得来的，`capabilities` 与 `experimentalApi` 必须留着 —— 漏掉它们测试照样全绿，但那条安全断言就被悄悄削弱了。`count == 11` 就是防这个的。

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: FAIL —— `summary.methods` 只有三条、`keySets.count == 3`。

- [ ] **Step 3: 写实现**

把 `enum CodexQuotaRPC` 整体替换为：

```swift
enum CodexQuotaRPC {
    static let quotaResponseID = 1
    static let usageResponseID = 2
    /// Both replies are expected in the same session; `CodexAppServerSession` waits for all of them.
    static let responseIDs: Set<Int> = [quotaResponseID, usageResponseID]
    static let outboundMethods = [
        "initialize",
        "initialized",
        "account/rateLimits/read",
        "account/usage/read"
    ]

    static func requestData(version: String) throws -> Data {
        let messages: [[String: Any]] = [
            [
                "method": outboundMethods[0],
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "token_health",
                        "version": version
                    ]
                ]
            ],
            ["method": outboundMethods[1]],
            ["method": outboundMethods[2], "id": quotaResponseID],
            // No params: the method takes none (the request schema requires only `id` and `method`).
            ["method": outboundMethods[3], "id": usageResponseID]
        ]

        var data = Data()
        for message in messages {
            data.append(try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }
}
```

同一步里把唯一还在用旧名字的地方一起改：`CodexAppServerClient.fetchRateLimits` 里有两处 `CodexQuotaRPC.responseID`（`responseID:` 实参，以及解码后 `response.id == …` 那道 guard），都改成 `CodexQuotaRPC.quotaResponseID`。会话方法自己的 `responseID:` 形参名**本步不动** —— 它到 Task 5 才变成 `responseIDs:`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: PASS。此刻会话仍然只等 id=1，多出来的 id=2 报文被会话忽略 —— 行为与改动前逐字相同。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/CodexUsageProvider.swift Tests/TokenHealthTests/CodexUsageProviderTests.swift
git commit -F - <<'MSG'
Ask the Codex app-server for account usage too

Same read-only session, one more request: the allowlist keeps every
forbidden method except the account usage read, which is the read-only
sibling of the quota read.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```

---

### Task 5: 会话等一组 id

**背景**：`CodexAppServerSession` 从「等一个 `responseID`」改成「等一组 `responseIDs`」，返回 `[Int: Data]`。锁、超时 work item、kill 兜底、行缓冲与体积上限**逐字不动**。

**Files:**
- Modify: `Sources/TokenHealth/CodexUsageProvider.swift:281-448`（`CodexAppServerSession`）

- [ ] **Step 1: 改测试助手（让既有测试先跑起来）**

`CodexTestSupport.fetchFromFakeAppServer()` 这次先只改调用姿势，不换返回类型：

```swift
        return try await CodexAppServerClient(testExecutableURL: executable, timeout: 3)
            .fetchRateLimits()
```

保持不变 —— 它是第 6 步才迁移的对象。**本任务没有新测试**：会话层的两个分支（两条都回 / 只回一条）在第 6 步一起覆盖，因为那一步才有能观察 `[Int: Data]` 的公开入口。

- [ ] **Step 2: 写实现**

在 `CodexAppServerSession` 里做这五处替换：

```swift
    private let requestData: Data
    private let responseIDs: Set<Int>
    private let timeout: TimeInterval
    private let lock = NSLock()

    private var continuation: CheckedContinuation<[Int: Data], Error>?
    private var responses: [Int: Data] = [:]
```

```swift
    private init(
        executableURL: URL,
        arguments: [String],
        requestData: Data,
        responseIDs: Set<Int>,
        timeout: TimeInterval,
        continuation: CheckedContinuation<[Int: Data], Error>
    ) {
        self.requestData = requestData
        self.responseIDs = responseIDs
        self.timeout = timeout
        self.continuation = continuation
```

```swift
    static func run(
        executableURL: URL,
        arguments: [String],
        requestData: Data,
        responseIDs: Set<Int>,
        timeout: TimeInterval
    ) async throws -> [Int: Data] {
        try await withCheckedThrowingContinuation { continuation in
            let session = CodexAppServerSession(
                executableURL: executableURL,
                arguments: arguments,
                requestData: requestData,
                responseIDs: responseIDs,
                timeout: timeout,
                continuation: continuation
            )
            session.start()
        }
    }
```

`handleOutput` 里挑响应那一段换成：

```swift
        for line in lines where !line.isEmpty {
            guard let envelope = try? JSONDecoder().decode(CodexRPCIDEnvelope.self, from: line),
                  let id = envelope.id, responseIDs.contains(id) else {
                continue
            }
            let collected: [Int: Data]? = lock.withLock {
                guard !isFinished else {
                    return nil
                }
                responses[id] = line
                // Only once every requested id has answered. A request that never answers is a
                // session timeout, not a partial result — see the spec's error table.
                return responses.count == responseIDs.count ? responses : nil
            }
            if let collected {
                complete(.success(collected))
                return
            }
        }
```

`complete` 的签名与内部类型：

```swift
    private func complete(_ result: Result<[Int: Data], Error>) {
        let pending: (CheckedContinuation<[Int: Data], Error>, DispatchWorkItem?)? = lock.withLock {
```

`fetchRateLimits` 里对应的调用改成：

```swift
        let responses = try await CodexAppServerSession.run(
            executableURL: executableURL,
            arguments: Self.arguments,
            requestData: requestData,
            responseIDs: [CodexQuotaRPC.quotaResponseID],
            timeout: timeout
        )
        guard let responseData = responses[CodexQuotaRPC.quotaResponseID] else {
            throw CodexAppServerError.invalidResponse
        }
```

> 注意：`fetchRateLimits` 这一趟**只**请求 id=1（`responseIDs: [.quotaResponseID]`），所以它不会因为 id=2 缺席而超时；`requestData` 多写出去的那条报文被服务端回应后被会话丢弃。第 6 步它整个被 `fetchQuotaBundle`取代。

- [ ] **Step 3: 跑测试确认通过**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: PASS —— `testAppServerClientIgnoresNotificationsAndReadsExpectedResponse` 走假脚本仍然拿到 id=1 的额度。

- [ ] **Step 4: 提交**

```bash
git add Sources/TokenHealth/CodexUsageProvider.swift
git commit -F - <<'MSG'
Let the Codex session wait for a set of response ids

The session now collects replies until every requested id has answered;
the timeout, process teardown and size guards are untouched.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```

---

### Task 6: `CodexQuotaBundle` 与 `fetchQuotaBundle()`

**背景**：额度必需、用量可选。id=2 **报错或解不出** → `accountUsage = nil`，不抛错；id=1 缺席 / 报错 / 解不出 → 抛错；id=2 **完全无应答** → 会话超时（与今天超时同路）。

**Files:**
- Modify: `Sources/TokenHealth/CodexUsageProvider.swift:89-159`（`CodexAppServerClient`）、`:450-456`（RPC 响应包装类型）
- Modify: `Tests/TokenHealthTests/CodexTestSupport.swift:66-93`
- Test: `Tests/TokenHealthTests/CodexUsageProviderTests.swift`

- [ ] **Step 1: 写失败的测试**

先把 `CodexTestSupport` 的假服务助手参数化 —— 用**回应列表**驱动，并在回应后挂在 stdin 上直到客户端关闭（这样「永不回应 id=2」才有稳定的表现）：

```swift
    static let fakeQuotaReply = #"{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":21,"windowDurationMins":300,"resetsAt":1783665814},"secondary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1784252614},"planType":"plus"}}}"#

    static let fakeUsageReply = #"{"id":2,"result":{"summary":{"lifetimeTokens":172532345,"peakDailyTokens":117865819,"longestRunningTurnSec":2550,"currentStreakDays":3},"dailyUsageBuckets":[{"startDate":"2026-09-23","tokens":117865819}]}}"#

    /// 起一个假 `codex`：读完四条请求报文后按 `replies` 逐行回，然后挂在 stdin 上不退出
    /// （客户端完成后会关 stdin / 杀进程）。
    static func fetchFromFakeAppServer(
        replies: [String] = [fakeQuotaReply, fakeUsageReply],
        timeout: TimeInterval = 3
    ) async throws -> CodexQuotaBundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex")
        let printed = replies.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        IFS= read -r _
        IFS= read -r _
        IFS= read -r _
        IFS= read -r _
        printf '%s\\n' '{"method":"remoteControl/status/changed","params":{}}'
        \(printed)
        while IFS= read -r _; do :; done
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        return try await CodexAppServerClient(testExecutableURL: executable, timeout: timeout)
            .fetchQuotaBundle()
    }
```

同时把 `fetchLiveCodexQuota()` 换成：

```swift
    static func fetchLiveCodexQuota() async throws -> CodexQuotaBundle {
        try await CodexAppServerClient().fetchQuotaBundle()
    }
```

既有测试 `testAppServerClientIgnoresNotificationsAndReadsExpectedResponse` 的断言改成读 bundle 的额度那一半，并补一条用量的断言：

```swift
    @Test
    func testAppServerClientIgnoresNotificationsAndReadsExpectedResponse() async throws {
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer()
        #expect(bundle.rateLimits.rateLimits?.limitId == "codex")
        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.rateLimits.rateLimits?.secondary?.usedPercent == 8)
        #expect(bundle.rateLimits.rateLimits?.planType == "plus")
        #expect(bundle.accountUsage?.summary?.currentStreakDays == 3)
    }

    @Test
    func testLiveCodexQuotaWhenExplicitlyEnabled() async throws {
        guard CodexTestSupport.liveCodexCheckEnabled else {
            return
        }
        let bundle = try await CodexTestSupport.fetchLiveCodexQuota()
        #expect(bundle.rateLimits.rateLimits?.primary != nil || bundle.rateLimits.rateLimits?.secondary != nil)
    }
```

再追加四条覆盖降级与失败分界：

```swift
    @Test
    func rejectedUsageReadOnlyDropsTheUsageHalf() async throws {
        // 老版本 Codex 不认识这个方法，会回 -32601。
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            CodexTestSupport.fakeQuotaReply,
            #"{"id":2,"error":{"code":-32601,"message":"Method not found"}}"#
        ])

        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.accountUsage == nil)
    }

    @Test
    func unreadableUsageResultOnlyDropsTheUsageHalf() async throws {
        let bundle = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
            CodexTestSupport.fakeQuotaReply,
            #"{"id":2,"result":{"summary":"not an object"}}"#
        ])

        #expect(bundle.rateLimits.rateLimits?.primary?.usedPercent == 21)
        #expect(bundle.accountUsage == nil)
    }

    @Test
    func unreadableQuotaResultFailsTheFetch() async throws {
        do {
            _ = try await CodexTestSupport.fetchFromFakeAppServer(replies: [
                #"{"id":1,"result":{"rateLimits":"not an object"}}"#,
                CodexTestSupport.fakeUsageReply
            ])
            Issue.record("expected an invalidResponse error")
        } catch let error as CodexAppServerError {
            guard case .invalidResponse = error else {
                Issue.record("expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func anUnansweredUsageReadTimesTheSessionOut() async throws {
        // 只回 id=1：会话等不齐就只能在超时上结束，整次取数失败 —— 与「有应答但报错」不是一回事。
        do {
            _ = try await CodexTestSupport.fetchFromFakeAppServer(
                replies: [CodexTestSupport.fakeQuotaReply],
                timeout: 2
            )
            Issue.record("expected a timeout error")
        } catch let error as CodexAppServerError {
            guard case .timeout = error else {
                Issue.record("expected .timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: 编译失败 —— `cannot find 'fetchQuotaBundle' in scope`、`CodexQuotaBundle` 不存在。同时 `CodexTestSupport` 里旧脚本（读三条、只回 id=1）会让新会话超时，既有测试也会红。

- [ ] **Step 3: 写实现**

在 `CodexUsageProvider.swift` 里，`struct CodexAppServerClient` 之前插入：

```swift
/// One app-server round trip's payloads. The quota read is required; the account usage read is a
/// nice-to-have whose absence only costs the detail's usage sections.
struct CodexQuotaBundle: Sendable {
    var rateLimits: CodexRateLimitsResponse
    var accountUsage: CodexAccountUsageResponse?
}
```

把 `CodexAppServerClient.fetchRateLimits()` 整体替换为：

```swift
    func fetchQuotaBundle() async throws -> CodexQuotaBundle {
        guard let executableURL = testExecutableURL ?? CodexExecutableResolver.resolve() else {
            throw CodexAppServerError.executableNotFound
        }

        let requestData: Data
        do {
            requestData = try CodexQuotaRPC.requestData(version: Self.appVersion)
        } catch {
            throw CodexAppServerError.invalidResponse
        }

        let responses = try await CodexAppServerSession.run(
            executableURL: executableURL,
            arguments: Self.arguments,
            requestData: requestData,
            responseIDs: CodexQuotaRPC.responseIDs,
            timeout: timeout
        )

        guard let quotaData = responses[CodexQuotaRPC.quotaResponseID] else {
            throw CodexAppServerError.invalidResponse
        }
        return CodexQuotaBundle(
            rateLimits: try Self.rateLimits(from: quotaData),
            accountUsage: Self.accountUsage(from: responses[CodexQuotaRPC.usageResponseID])
        )
    }

    /// A missing, rejected or unreadable quota result fails the whole refresh: every number the
    /// menu bar shows comes from it.
    private static func rateLimits(from data: Data) throws -> CodexRateLimitsResponse {
        let response: CodexRPCResult<CodexRateLimitsResponse>
        do {
            response = try JSONDecoder().decode(CodexRPCResult.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse
        }

        if response.error != nil {
            throw CodexAppServerError.requestRejected
        }
        guard response.id == CodexQuotaRPC.quotaResponseID, let result = response.result else {
            throw CodexAppServerError.invalidResponse
        }
        return result
    }

    /// An answered-but-bad usage read (an older Codex rejects the method with `-32601`) only
    /// drops the usage sections; a missing answer never reaches here — that is a session timeout.
    private static func accountUsage(from data: Data?) -> CodexAccountUsageResponse? {
        guard let data,
              let response = try? JSONDecoder().decode(CodexRPCResult<CodexAccountUsageResponse>.self, from: data),
              response.error == nil,
              response.id == CodexQuotaRPC.usageResponseID,
              let result = response.result else {
            return nil
        }
        return result
    }
```

把 `private struct CodexRPCQuotaResponse` 换成泛型版本（`CodexRPCErrorPayload` 保持在它下面）：

```swift
private struct CodexRPCResult<Value: Decodable>: Decodable {
    let id: Int
    let result: Value?
    let error: CodexRPCErrorPayload?
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: PASS（8 条 Codex 相关测试：解码×2、映射×2、会话×1、降级×4）。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/CodexUsageProvider.swift Tests/TokenHealthTests/CodexTestSupport.swift Tests/TokenHealthTests/CodexUsageProviderTests.swift
git commit -F - <<'MSG'
Fetch the Codex quota and account usage in one session

A rejected or unreadable usage read only drops the usage half, while an
unanswered one is a session timeout; fetchRateLimits has no callers left.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```

---

### Task 7: 快照接缝与缓存

**背景**：把「bundle → 快照（含 detail）」抽成内部纯函数 —— 测试就能拿合成 bundle 与固定 `today` 直接测这一层，不必起进程、也不踩 UTC 午夜；缓存同时从「额度」换成「bundle」。键、`maxAge: 60`、`minimumRequestInterval: 60`、失败缓存与节流语义全部不变，一次刷新仍然只起一个 Codex 进程。

**Files:**
- Modify: `Sources/TokenHealth/CodexUsageProvider.swift`（`CodexUsageProvider` 的取值段、`:653-702` 的 `CodexRateLimitsCache` 一族）
- Test: `Tests/TokenHealthTests/CodexUsageProviderTests.swift`

- [ ] **Step 1: 写失败的测试**

先在 `CodexUsageProviderTests` 里追加接缝层的辅助与三条断言：

```swift
    private func bundle(usageJSON: String?) throws -> CodexQuotaBundle {
        let quota = try CodexTestSupport.decodeRateLimits(#"""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1790337941},
        "secondary":{"usedPercent":58,"windowDurationMins":10080,"resetsAt":1790754811},"planType":"plus"}}
        """#)
        let usage = try usageJSON.map {
            try JSONDecoder().decode(CodexAccountUsageResponse.self, from: Data($0.utf8))
        }
        return CodexQuotaBundle(rateLimits: quota, accountUsage: usage)
    }

    private var fetchDay: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    private func codexConfig() -> ServiceConfig {
        ServiceConfig(displayName: "Codex", providerKind: .codex, authMode: .api)
    }

    @Test
    func theSnapshotSeamCarriesTheDetail() throws {
        let snapshot = CodexUsageProvider().snapshot(
            config: codexConfig(),
            bundle: try bundle(usageJSON: #"""
            {"summary":{"lifetimeTokens":172532345,"peakDailyTokens":117865819,
            "longestRunningTurnSec":2550,"currentStreakDays":3},
            "dailyUsageBuckets":[{"startDate":"2026-09-25","tokens":2000000}]}
            """#),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
            today: fetchDay
        )

        #expect(snapshot.state == .ready)
        #expect(snapshot.planName == "Plus")
        #expect(snapshot.usages.map(\.window) == [.fiveHours, .week])

        let detail = try #require(snapshot.detail)
        #expect(detail.headline.map(\.value) == ["12%", "58%"])
        #expect(detail.groups.map { $0.values[0].value } == ["2M", "2M", "2M"])
        #expect(detail.series?.points.count == 30)
        #expect(detail.breakdown.map(\.label) == ["Lifetime", "Peak day", "Streak", "Longest turn"])
    }

    @Test
    func aMissingUsageHalfStillYieldsAReadySnapshotWithAQuotaOnlyDetail() throws {
        let snapshot = CodexUsageProvider().snapshot(
            config: codexConfig(),
            bundle: try bundle(usageJSON: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
            today: fetchDay
        )

        #expect(snapshot.state == .ready)
        let detail = try #require(snapshot.detail)
        #expect(detail.headline.map(\.label) == ["5h", "Week"])
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
    }

    @Test
    func aBundleWithoutQuotaWindowsIsUnavailableAndCarriesNoDetail() throws {
        let empty = try CodexTestSupport.decodeRateLimits(#"{"rateLimitsByLimitId":{}}"#)
        let snapshot = CodexUsageProvider().snapshot(
            config: codexConfig(),
            bundle: CodexQuotaBundle(
                rateLimits: empty,
                accountUsage: try JSONDecoder().decode(
                    CodexAccountUsageResponse.self,
                    from: Data(#"{"summary":{"lifetimeTokens":1}}"#.utf8)
                )
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
            today: fetchDay
        )

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.detail == nil)
    }
```

再追加缓存那条（它同时证明「缓存命中的是整只 bundle、且没有重起进程」）：

```swift
    @Test
    func aSecondFetchWithinTheMinuteReusesTheCachedBundleWithoutSpawning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        IFS= read -r _
        IFS= read -r _
        IFS= read -r _
        IFS= read -r _
        printf '%s\\n' '\(CodexTestSupport.fakeQuotaReply)'
        printf '%s\\n' '\(CodexTestSupport.fakeUsageReply)'
        while IFS= read -r _; do :; done
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = CodexAppServerClient(testExecutableURL: executable)
        let provider = CodexUsageProvider(client: client)
        let config = ServiceConfig(displayName: "Codex", providerKind: .codex, authMode: .api)

        let first = await provider.fetchUsage(config: config, secrets: .empty)
        #expect(first.state == .ready)
        #expect(first.detail?.headline.isEmpty == false)

        // 把可执行文件删掉：再取一次还能拿到同一份数字，说明走的是缓存、没有起进程。
        try FileManager.default.removeItem(at: executable)
        let second = await provider.fetchUsage(config: config, secrets: .empty)
        #expect(second.state == .ready)
        #expect(second.detail == first.detail)
        #expect(second.updatedAt == first.updatedAt)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter CodexUsageProviderTests`
Expected: 编译失败 —— `snapshot(config:bundle:fetchedAt:today:)` 不存在，且 `fetchUsage` 还按 `CodexRateLimitsResponse` 存缓存。

- [ ] **Step 3: 写实现**

把文件底部那一族类型整体替换：

```swift
private struct CodexQuotaCacheEntry: Sendable {
    let fetchedAt: Date
    let value: CodexQuotaBundle
}

private struct CodexQuotaFailureEntry: Sendable {
    let failedAt: Date
    let error: CodexAppServerError
}

private enum CodexQuotaLookup: Sendable {
    case cached(CodexQuotaCacheEntry)
    case failed(CodexAppServerError)
    case fetch
    case throttled
}

private actor CodexQuotaCache {
    private var entries: [String: CodexQuotaCacheEntry] = [:]
    private var failures: [String: CodexQuotaFailureEntry] = [:]
    private var lastRequestDates: [String: Date] = [:]

    func lookup(key: String, maxAge: TimeInterval, minimumRequestInterval: TimeInterval) -> CodexQuotaLookup {
        let now = Date()
        if let entry = entries[key], now.timeIntervalSince(entry.fetchedAt) < maxAge {
            return .cached(entry)
        }
        if let failure = failures[key], now.timeIntervalSince(failure.failedAt) < minimumRequestInterval {
            return .failed(failure.error)
        }
        if let lastRequestDate = lastRequestDates[key], now.timeIntervalSince(lastRequestDate) < minimumRequestInterval {
            return .throttled
        }
        lastRequestDates[key] = now
        return .fetch
    }

    func store(_ value: CodexQuotaBundle, key: String, fetchedAt: Date) {
        entries[key] = CodexQuotaCacheEntry(fetchedAt: fetchedAt, value: value)
        failures[key] = nil
    }

    func storeFailure(_ error: CodexAppServerError, key: String, failedAt: Date) {
        failures[key] = CodexQuotaFailureEntry(failedAt: failedAt, error: error)
    }

    func clearRequest(key: String) {
        lastRequestDates[key] = nil
    }
}
```

并把 `CodexUsageProvider` 的取值段改成：

```swift
    private static let cache = CodexQuotaCache()

    func fetchUsage(config: ServiceConfig, secrets _: ProviderSecrets) async -> ProviderUsageSnapshot {
        do {
            let bundle: CodexQuotaBundle
            let fetchedAt: Date
            let cacheKey = client.cacheKey
            switch await Self.cache.lookup(key: cacheKey, maxAge: 60, minimumRequestInterval: 60) {
            case let .cached(cached):
                bundle = cached.value
                fetchedAt = cached.fetchedAt
            case let .failed(error):
                throw error
            case .fetch:
                do {
                    bundle = try await client.fetchQuotaBundle()
                    fetchedAt = Date()
                    await Self.cache.store(bundle, key: cacheKey, fetchedAt: fetchedAt)
                } catch let error as CodexAppServerError {
                    await Self.cache.storeFailure(error, key: cacheKey, failedAt: Date())
                    throw error
                } catch {
                    await Self.cache.clearRequest(key: cacheKey)
                    throw error
                }
            case .throttled:
                throw CodexAppServerError.refreshThrottled
            }

            return snapshot(config: config, bundle: bundle, fetchedAt: fetchedAt, today: Date())
        } catch let error as CodexAppServerError {
            let state: ProviderUsageSnapshot.State = switch error {
            case .executableNotFound, .requestRejected:
                .needsConfiguration
            case .invalidResponse, .launchFailed, .processExited, .refreshThrottled, .responseTooLarge, .timeout:
                .unavailable
            }
            return failureSnapshot(config: config, state: state, message: error.localizedDescription)
        } catch {
            return failureSnapshot(config: config, state: .unavailable, message: "Codex quota is unavailable")
        }
    }
```

> 原来那个私有 `snapshot(config:state:message:)` 改名 `failureSnapshot(config:state:message:)`，只被上面两个 catch 用；成功路径改走下面的接缝。

同一步里加上接缝（放在 `failureSnapshot` 旁边）：

```swift
    /// Internal rather than private: tests hand it a synthetic bundle and a fixed `today` instead
    /// of spawning a Codex process, and never race UTC midnight.
    func snapshot(
        config: ServiceConfig,
        bundle: CodexQuotaBundle,
        fetchedAt: Date,
        today: Date
    ) -> ProviderUsageSnapshot {
        let mapped = CodexRateLimitsMapper.map(bundle.rateLimits)
        guard !mapped.usages.isEmpty else {
            return ProviderUsageSnapshot.unavailable(config: config, message: "Codex did not return any quota windows")
        }

        return ProviderUsageSnapshot(
            id: config.id,
            serviceName: config.displayName,
            providerTitle: config.providerKind.title,
            planName: mapped.planName,
            usages: mapped.usages,
            detail: CodexUsageDetail.make(usage: bundle.accountUsage, usages: mapped.usages, today: today),
            state: .ready,
            statusMessage: mapped.statusMessage,
            updatedAt: fetchedAt
        )
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh`
Expected: 全绿（本任务新增 4 条：接缝 3 条 + 缓存 1 条）。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/CodexUsageProvider.swift Tests/TokenHealthTests/CodexUsageProviderTests.swift
git commit -F - <<'MSG'
Wire the account usage into the Codex snapshot and cache it whole

The bundle-to-snapshot step is a pure function with an injected today, so
tests cover the detail without spawning Codex; the cache keeps its key,
freshness and throttle policy but now stores the usage half too.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```


---

## Chunk 3: 接线、文案与验收

### Task 8: 详情门槛

**背景**：`.codex` 是**唯一不看 authMode 的分支** —— Codex 走 `usesLocalLogin`，`AppState.saveConfigs()` 会把它的 `authMode` 强制写成 `.api`，照 DeepSeek / OpenCode Go 那条 `authMode == .browserLogin` 写就永远不会为真。

**Files:**
- Modify: `Sources/TokenHealth/Providers.swift:18-25`
- Test: `Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift`

- [ ] **Step 1: 写失败的测试**

在 `ProviderDetailCapabilityTests` 里追加，并改掉 `everyOtherProviderIsUnsupported` 的例外集合：

```swift
    @Test
    func codexProducesDetailInEitherMode() {
        // Codex 没有登录 / API 之分：`usesLocalLogin` 把它的 authMode 固定成 `.api`，
        // 所以这个分支不能看 authMode（与 DeepSeek / Go 那条规则不同）。
        #expect(ProviderFactory.producesUsageDetail(for: config(.codex, auth: .api)))
        #expect(ProviderFactory.producesUsageDetail(for: config(.codex, auth: .browserLogin)))
    }

    @Test
    func everyOtherProviderIsUnsupported() {
        for kind in ProviderKind.allCases where kind != .deepSeek && kind != .openCodeGo && kind != .codex {
            for auth in AuthMode.allCases {
                #expect(
                    !ProviderFactory.producesUsageDetail(for: config(kind, auth: auth)),
                    "\(kind) / \(auth) 不该被当成支持详情"
                )
            }
        }
    }
```

（把原来那个 `everyOtherProviderIsUnsupported` 整体替换成上面这版。）

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter ProviderDetailCapabilityTests`
Expected: FAIL —— `.codex` 两种模式都返回 false。

- [ ] **Step 3: 写实现**

把 `ProviderFactory.producesUsageDetail` 换成：

```swift
    static func producesUsageDetail(for config: ServiceConfig) -> Bool {
        switch config.providerKind {
        case .deepSeek, .openCodeGo:
            config.authMode == .browserLogin
        case .codex:
            // Codex 没有登录 / API 之分：`usesLocalLogin` 让 `AppState.saveConfigs()` 把 authMode
            // 固定成 `.api`，所以这一支**不能**看 authMode —— 照上面那条写就永远不会为真。
            // Cursor 同为本地登录，本次不给它详情。
            true
        default:
            false
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh`
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/Providers.swift Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift
git commit -F - <<'MSG'
Give pinned Codex items the detail popover

Codex has no login/API split — its auth mode is pinned to API by the
local-login path — so the gate must not read it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
MSG
```

---

### Task 9: README 两版

**Files:**
- Modify: `README.md:107-109` 之后
- Modify: `README.en.md:104` 之后

- [ ] **Step 1: 中文版**

在 `README.md` 的 `数据全部来自刷新时已经取回的那次响应，不额外发请求。` 这一段**之后**插入：

```markdown
钉住的 Codex 项也是同一套浮层：5 小时与周额度（与菜单栏同一份口径）、`Today` / `7 days` / `30 days` 的
token 汇总、最近 30 天的每日 token 趋势，以及 `Lifetime` / `Peak day` / `Streak` / `Longest turn`。
数据来自本地 Codex 登录的那次 `app-server` 会话（同一次往返里多问一条账号用量），不需要重新登录，
也不读 `~/.codex/auth.json`。
```

- [ ] **Step 2: 英文版**

在 `README.en.md` 的 `Numbers in the detail view older than 5 minutes refresh once automatically...` 这一段**之前**插入对应的一段：

```markdown
A pinned Codex item opens the same kind of popover: the 5-hour and weekly quota (the same numbers the
menu bar draws), token totals for `Today` / `7 days` / `30 days`, a by-day token trend for the last 30
days, and `Lifetime` / `Peak day` / `Streak` / `Longest turn`. It all comes from the local Codex login's
`app-server` session — one extra question on the same round trip, no re-login and no reading of
`~/.codex/auth.json`.
```

- [ ] **Step 3: 提交**

```bash
git add README.md README.en.md
git commit -F - <<'MSG'
Document the Codex detail popover

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

### Task 10: 构建、安装与实机验收

**Files:** 无代码改动（只跑脚本与手动验收）

- [ ] **Step 1: 全量测试**

Run: `bash scripts/test.sh`
Expected: 全绿，无 warning 相关的编译失败。

- [ ] **Step 2: 构建并安装**

```bash
bash scripts/build-app.sh
rm -rf "/Applications/Token Health.app"
cp -R ".build/app/Token Health.app" "/Applications/Token Health.app"
plutil -extract CFBundleShortVersionString raw "/Applications/Token Health.app/Contents/Info.plist"
```
Expected: 打印 `1.0.3`（本次不推版本号）。

- [ ] **Step 3: 重启应用**

```bash
pkill -x TokenHealth; sleep 1; open "/Applications/Token Health.app"; sleep 3; pgrep -x TokenHealth
```
Expected: 输出进程号。

- [ ] **Step 4: 手动验收（需要人看，逐条记录结果）**

1. 点菜单栏上钉住的 **Codex** 项 → 浮层出现：`5h` / `Week` 两行百分比、`Today` / `7 days` / `30 days` 三行 tokens、30 根柱子的趋势图、`Lifetime` / `Peak day` / `Streak` / `Longest turn` 四项。
2. headline 的百分比与**菜单栏项的悬停 tooltip** 逐字一致。
3. 30 天合计与 Codex 自己的用量界面对得上：TUI 里 `/usage`（Token activity）读的就是同一条 `account/usage/read`。**不要拿 `/status` 对**（那是当前 session 的 token，不是账号历史）。
4. 回归：钉住的 DeepSeek / OpenCode Go 浮层内容不变；钉住的 **Cursor** 仍然是 Unpin / Settings / Quit 小菜单（本次没给它详情）。
5. 断网或让 Codex 退出登录后刷新 → 浮层保留上次数字 + 红色错误行，不退回小菜单。

- [ ] **Step 5: 记录验收结果**

把第 4 步的观察写进提交信息或直接在对话里回报；若某项不通过，回到对应任务修，不要跳过。

---

## 已知风险

1. **会话多等一条响应**：一次刷新仍然只起一个 Codex 进程（实测单次往返 1.2–5.5 秒），但新增了「id=2 永不回应 → 整次超时失败」这一种可能。JSON-RPC 要求对每个带 id 的请求都应答（未知方法回 `-32601`），本机 0.144.4 与 ChatGPT.app 内置的 0.155.0-alpha 都实测应答。真要遇到静默丢请求的版本，再加「必需 id 到齐后宽限 N 秒」的兜底。
2. **`account/usage/read` 是实验性协议**：它出现在 `--experimental` 的 schema 里，未来可能改名。改名后的表现是 `-32601` → 详情退化成只有 headline，不会影响额度。
3. **bucket 稀疏且可能被后端截断**：30 天外的 bucket 会被忽略；若后端只回最近 N 条，最老几天会静默缺失，表现为「30 天合计偏小」，无告警。
4. **`Longest turn` 是趣味指标**，不是用量决策依据。
5. **测试里的 `today` 注入只在纯函数层**：provider 层用真实 `Date()`，所以 provider 级测试只断言区块存在与字符串，不断言具体日期窗口。
