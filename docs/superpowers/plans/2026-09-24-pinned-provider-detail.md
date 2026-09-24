# 钉住项用量详情浮层 实现计划

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 点钉住的 DeepSeek 菜单栏项弹出浮层，展示余额、今日/本月合计、本月按天趋势、tokens 构成与按模型拆分，数据全部来自已经抓回来的响应。

**Architecture:** 详情是一个与 Provider 无关的值类型 `UsageDetail`，浮层只认它；DeepSeek 负责填。DeepSeek 响应的形状知识集中到一个 `DeepSeekPayload` 里，解析器与详情构建器共用，避免两份形状走查。可验证的逻辑全部是纯计算（详情构建、柱高归一化），AppKit 只留在最外层的 `NSPopover` 与控制器里。

**Tech Stack:** Swift 6、SwiftPM（macOS 14+）、SwiftUI + AppKit（`NSPopover`）、swift-testing。

**Spec:** `docs/superpowers/specs/2026-09-24-pinned-provider-detail-design.md`

---

## 前置约束

- 跑测试一律 `bash scripts/test.sh [--filter Suite]`（本机无 Xcode，直接 `swift test` 编译不过）。
- 凡是构造 `AppState` 的测试**必须**注入 `InMemorySecretStore` 与桩汇率源：真实钥匙串会弹授权框并无限期卡住，兜底汇率永远是「过期」的。
- 所有 commit message 结尾带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 当前分支 `feature/pinned-provider-detail`（spec 已在上面）。

## 文件结构

**新增源码**

| 文件 | 职责 |
| --- | --- |
| `Sources/TokenHealth/UsageAmountFormatter.swift` | 从 `StatusMenuView.swift` 搬出来的格式化工具；新增 `compactAmount` / `moneyText` |
| `Sources/TokenHealth/UsageDetail.swift` | 通用详情模型（`UsageDetail` 及其子类型） |
| `Sources/TokenHealth/DeepSeekPayload.swift` | DeepSeek 响应形状的走查工具（从解析器里提取） |
| `Sources/TokenHealth/DeepSeekUsageDetail.swift` | bundle → `UsageDetail` |
| `Sources/TokenHealth/DetailSeriesChart.swift` | 柱高归一化的纯计算 |
| `Sources/TokenHealth/DetailPopoverView.swift` | 浮层视图（只读、无交互） |

**修改**

| 文件 | 改动 |
| --- | --- |
| `Sources/TokenHealth/StatusMenuView.swift` | 移出 `UsageAmountFormatter`；`formatAmount` 调用点改名 |
| `Sources/TokenHealth/MenuBarMetrics.swift` | `moneyText` 移出，改调 `UsageAmountFormatter.moneyText` |
| `Sources/TokenHealth/Models.swift` | `ProviderUsageSnapshot.detail` |
| `Sources/TokenHealth/DeepSeekUsageProvider.swift` | 填 detail；解析器改用 `DeepSeekPayload` |
| `Sources/TokenHealth/Providers.swift` | `ProviderFactory.producesUsageDetail(for:)` |
| `Sources/TokenHealth/AppState.swift` | `refresh(configID:)`；非 ready 快照保留旧 detail |
| `Sources/TokenHealth/PinnedStatusItemController.swift` | 支持详情的项弹浮层，否则弹菜单 |
| `README.md` | 用法说明 |

---

## Chunk 1: 纯逻辑

### Task 1: 把格式化工具搬出来并提取共用函数

`UsageAmountFormatter` 现在住在 `StatusMenuView.swift` 里（该文件已 830 行），而详情浮层也要用它。先搬家，再把两个通用函数提出来。

**Files:**
- Create: `Sources/TokenHealth/UsageAmountFormatter.swift`
- Modify: `Sources/TokenHealth/StatusMenuView.swift`（删掉 `enum UsageAmountFormatter` 整块）
- Modify: `Sources/TokenHealth/MenuBarMetrics.swift`（`moneyText` 移出）
- Test: `Tests/TokenHealthTests/UsageAmountFormatterTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/UsageAmountFormatterTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct UsageAmountFormatterTests {
    /// 既有测试只覆盖了 M 与精确值两个分支，K 与 B 没人守。
    @Test
    func abbreviatesLargeCounts() {
        #expect(UsageAmountFormatter.compactAmount(999) == "999")
        #expect(UsageAmountFormatter.compactAmount(1_000) == "1K")
        #expect(UsageAmountFormatter.compactAmount(12_500) == "12.5K")
        #expect(UsageAmountFormatter.compactAmount(1_000_000) == "1M")
        #expect(UsageAmountFormatter.compactAmount(2_140_000) == "2.14M")
        #expect(UsageAmountFormatter.compactAmount(1_000_000_000) == "1B")
        #expect(UsageAmountFormatter.compactAmount(3_500_000_000) == "3.5B")
    }

    @Test
    func groupsAndRoundsMoneyToTwoDecimals() {
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "1284.6")!) == "1,284.60")
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "0.1234")!) == "0.12")
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "0")!) == "0.00")
        #expect(UsageAmountFormatter.moneyText(Decimal(string: "1234567.891")!) == "1,234,567.89")
    }

    /// 搬家不能改变面板的显示。
    @Test
    func amountTextStillReadsTheSame() {
        let usage = TokenUsage(window: .fiveHours, used: 2_140_000, limit: 9_000_000)
        let text = UsageAmountFormatter.amountText(usage, isSensitiveAmount: false, revealsSensitiveAmount: true)
        #expect(text == "2.14M / 9M")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter UsageAmountFormatterTests`
Expected: 编译失败，`value of type 'UsageAmountFormatter' has no member 'compactAmount'`

- [ ] **Step 3: 搬家**

把 `Sources/TokenHealth/StatusMenuView.swift` 里 `enum UsageAmountFormatter { ... }` 整块（约 714-816 行）**逐字**剪切到新文件 `Sources/TokenHealth/UsageAmountFormatter.swift`，前面加 `import Foundation` + `import SwiftUI`（它用到 `Color`）。然后在新文件里做两处改名：

```swift
    /// 紧凑数字：1.2K / 3.4M / 5.6B。面板与详情浮层共用。
    static func compactAmount(_ value: Int) -> String { ... }   // 原 private func formatAmount，函数体逐字不动
```

把 `StatusMenuView.swift` 里三处 `formatAmount(` 改为 `compactAmount(`（都在 `UsageAmountFormatter` 内部，随搬家一起走；`StatusMenuView` 自身没有调用点 —— 改完 grep 确认）。

把 `MenuBarMetrics.moneyText` 整个函数体搬到 `UsageAmountFormatter` 里：

```swift
    /// 金额：两位小数、千位分隔、**不带单位**（单位由调用方按需追加）。
    static func moneyText(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
```

`MenuBarMetrics` 里原来的 `moneyText` 删掉，调用点（`deepSeekMetrics` 两处）改为 `UsageAmountFormatter.moneyText(...)`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter UsageAmountFormatterTests`
Expected: `Test run with 3 tests in 1 suite passed`

- [ ] **Step 5: 跑全量测试确认搬家没有回归**

Run: `bash scripts/test.sh`
Expected: 全绿（尤其 `MenuBarMetricsTests` 里那几条金额断言）。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/UsageAmountFormatter.swift Sources/TokenHealth/StatusMenuView.swift \
        Sources/TokenHealth/MenuBarMetrics.swift Tests/TokenHealthTests/UsageAmountFormatterTests.swift
git commit -m "$(cat <<'EOF'
Move the amount formatter out of the menu view

StatusMenuView had grown past 800 lines and the detail popover needs the
same formatting, so the formatter gets its own file plus the two shared
entry points it was missing.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 2: 通用详情模型

**Files:**
- Create: `Sources/TokenHealth/UsageDetail.swift`
- Modify: `Sources/TokenHealth/Models.swift`（`ProviderUsageSnapshot`）

纯值类型，没有独立可断言的逻辑；它的正确性由 Task 4/5 的使用方测试体现。这一步只要求编译通过。

- [ ] **Step 1: 定义模型**

创建 `Sources/TokenHealth/UsageDetail.swift`：

```swift
import Foundation

/// 详情浮层要展示的内容。与 Provider 无关，浮层只认这个类型。
///
/// 不变量：`DetailStat.id` 取 `label`、`DetailTableRow.id` 取 `name`，
/// 因此同一个集合内 label / name 必须唯一 —— 填充方要先聚合去重。
struct UsageDetail: Equatable, Sendable {
    var headline: [DetailStat] = []
    var groups: [DetailGroup] = []
    var series: DetailSeries? = nil
    var breakdown: [DetailStat] = []
    var table: DetailTable? = nil

    /// 什么都没有，浮层就没必要画数据区。
    var isEmpty: Bool {
        headline.isEmpty && groups.isEmpty && breakdown.isEmpty && table == nil
    }
}

struct DetailStat: Equatable, Sendable, Identifiable {
    var label: String
    var value: String

    var id: String { label }
}

struct DetailGroup: Equatable, Sendable, Identifiable {
    var title: String
    var values: [DetailStat]

    var id: String { title }
}

struct DetailSeries: Equatable, Sendable {
    var title: String
    var points: [DetailSeriesPoint]
    var axisStart: String
    var axisEnd: String
}

struct DetailSeriesPoint: Equatable, Sendable, Identifiable {
    var date: Date
    var value: Double

    var id: Date { date }
}

struct DetailTable: Equatable, Sendable {
    var title: String
    var columns: [String]
    var rows: [DetailTableRow]
    var footnote: String?
}

struct DetailTableRow: Equatable, Sendable, Identifiable {
    var name: String
    /// 对应 `columns` 去掉首列后的其余列，即 `cells.count == columns.count - 1`。
    var cells: [String]

    var id: String { name }
}
```

- [ ] **Step 2: 快照带上 detail**

在 `Sources/TokenHealth/Models.swift` 的 `ProviderUsageSnapshot` 里，紧跟 `usages` 加一行（**带默认值**，既有构造点全部不受影响）：

```swift
    var planName: String? = nil
    var usages: [TokenUsage]
    /// Provider 提供的明细；没有就不弹详情浮层。
    var detail: UsageDetail? = nil
    var state: State
```

- [ ] **Step 3: 编译并跑全量测试**

Run: `bash scripts/test.sh`
Expected: 全绿，且**没有任何文件需要改动**（证明默认值保住了所有既有构造点）。

- [ ] **Step 4: 提交**

```bash
git add Sources/TokenHealth/UsageDetail.swift Sources/TokenHealth/Models.swift
git commit -m "$(cat <<'EOF'
Add the provider-agnostic usage detail model

A value type the popover renders and each provider fills, so the view does
not have to know about DeepSeek.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 3: 提取 DeepSeek 响应的形状走查

`DeepSeekUsageParser` 里有一堆私有的形状走查函数（`bizData` / `usageDataObject` / `costCurrencyItems` / `dayData` / `intUsageAmount` / `sumUsageAmounts` / `decimalValue` / `stringValue`）。详情构建器要用同一套 —— 两个端点的形状还是**不对称**的（amount 是对象，cost 是币种数组），抄一份必然会漂。

**Files:**
- Create: `Sources/TokenHealth/DeepSeekPayload.swift`
- Modify: `Sources/TokenHealth/DeepSeekUsageProvider.swift`（解析器改调新类型）
- Test: `Tests/TokenHealthTests/DeepSeekPayloadTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/DeepSeekPayloadTests.swift`。这些用例直接钉住两个端点的形状差异：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct DeepSeekPayloadTests {
    @Test
    func walksTheAmountEnvelopeDownToItsDays() {
        let root: [String: Any] = [
            "code": 0,
            "data": ["biz_data": ["days": [["date": "2026-09-24", "data": []]]]]
        ]
        let days = DeepSeekPayload.days(fromAmount: root)
        #expect(days.count == 1)
        #expect(DeepSeekPayload.dateText(days[0]) == "2026-09-24")
    }

    @Test
    func walksTheCostEnvelopePerCurrency() {
        let root: [String: Any] = [
            "data": [
                ["currency": "CNY", "days": [["date": "2026-09-24", "data": []]]],
                ["currency": "USD", "days": [["date": "2026-09-24", "data": []]]]
            ]
        ]
        let items = DeepSeekPayload.costCurrencies(fromCost: root)
        #expect(items.map(\.currency) == ["CNY", "USD"])
        #expect(DeepSeekPayload.dateText(items[0].days[0]) == "2026-09-24")
    }

    @Test
    func readsTypedAmountsAndIgnoresUnknownTypes() {
        let item: [String: Any] = [
            "model": "deepseek-chat",
            "usage": [
                ["type": "REQUEST", "amount": "12"],
                ["type": "RESPONSE_TOKEN", "amount": "340"],
                ["type": "SOMETHING_ELSE", "amount": "999"]
            ]
        ]
        #expect(DeepSeekPayload.intAmount(in: item, type: "REQUEST") == 12)
        #expect(DeepSeekPayload.intAmount(in: item, type: "RESPONSE_TOKEN") == 340)
        #expect(DeepSeekPayload.intAmount(in: item, type: "MISSING") == 0)
    }

    @Test
    func sumsEveryAmountInAnItem() {
        let item: [String: Any] = [
            "usage": [["amount": "0.5"], ["amount": "0.25"], ["amount": "abc"]]
        ]
        #expect(DeepSeekPayload.sumAmounts(in: item) == Decimal(string: "0.75"))
    }

    @Test
    func readsNumbersFromStringsIntsAndDoubles() {
        #expect(DeepSeekPayload.decimal("12.5") == Decimal(string: "12.5"))
        #expect(DeepSeekPayload.decimal(12) == Decimal(12))
        #expect(DeepSeekPayload.decimal(12.5) == Decimal(string: "12.5"))
        #expect(DeepSeekPayload.decimal("1,234.5") == Decimal(string: "1234.5"))
        #expect(DeepSeekPayload.decimal("abc") == nil)
        #expect(DeepSeekPayload.decimal(nil) == nil)
    }

    @Test
    func toleratesMissingLayers() {
        #expect(DeepSeekPayload.days(fromAmount: [:]).isEmpty)
        #expect(DeepSeekPayload.costCurrencies(fromCost: [:]).isEmpty)
        #expect(DeepSeekPayload.items(inDay: [:]).isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter DeepSeekPayloadTests`
Expected: 编译失败，`cannot find 'DeepSeekPayload' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/DeepSeekPayload.swift`，函数体**逐字搬自** `DeepSeekUsageParser` 的对应私有函数（只把 `self.` 去掉、参数名对齐）：

```swift
import Foundation

/// DeepSeek 两个用量端点的响应形状。搬自 `DeepSeekUsageParser` 的私有走查函数 ——
/// 解析器与详情构建器共用一份，避免形状知识出现第二份拷贝。
///
/// 两个端点的形状**不对称**，这里如实反映：
/// - `amount`：`{code, data:{biz_data:{days:[{date, data:[{model, usage:[{type, amount}]}]}]}}}`
/// - `cost`：`{data:[{currency, days:[{date, data:[{model, usage:[{amount}]}]}]}]}`
enum DeepSeekPayload {
    struct CostCurrency {
        var currency: String
        var days: [[String: Any]]
    }

    // MARK: - amount 侧

    /// 走到 `days` 数组。
    static func days(fromAmount root: [String: Any]) -> [[String: Any]] {
        guard let dataObject = usageDataObject(from: root) else { return [] }
        return dataObject["days"] as? [[String: Any]] ?? []
    }

    // MARK: - cost 侧

    /// 走到 `[{currency, days}]`。币种按名字升序，保证浮层里的顺序稳定。
    static func costCurrencies(fromCost root: [String: Any]) -> [CostCurrency] {
        costCurrencyItems(from: root)
            .compactMap { item in
                guard let currency = stringValue(item["currency"]), !currency.isEmpty else {
                    return nil
                }
                return CostCurrency(
                    currency: currency,
                    days: item["days"] as? [[String: Any]] ?? []
                )
            }
            .sorted { $0.currency < $1.currency }
    }

    // MARK: - 共用

    /// 某一天的明细行。
    static func items(inDay day: [String: Any]) -> [[String: Any]] {
        day["data"] as? [[String: Any]] ?? []
    }

    /// 供调用方按日期字符串匹配（前缀比较，与既有 `dayData` 同一口径）。
    static func dateText(_ day: [String: Any]) -> String? {
        stringValue(day["date"])
    }

    static func modelName(in item: [String: Any]) -> String? {
        stringValue(item["model"])
    }

    static func intAmount(in item: [String: Any], type: String) -> Int {
        guard let usage = item["usage"] as? [[String: Any]],
              let amount = usage.first(where: { stringValue($0["type"]) == type })
                  .flatMap({ decimalValue($0["amount"]) }) else {
            return 0
        }
        return max(0, NSDecimalNumber(decimal: amount).intValue)
    }

    static func sumAmounts(in item: [String: Any]) -> Decimal {
        guard let usage = item["usage"] as? [[String: Any]] else {
            return Decimal(0)
        }
        return usage.reduce(Decimal(0)) { partial, entry in
            partial + (decimalValue(entry["amount"]) ?? Decimal(0))
        }
    }

    static func decimal(_ value: Any?) -> Decimal? {
        decimalValue(value)
    }

    // MARK: - 私有（逐字搬自解析器）

    private static func bizData(from root: [String: Any]) -> [String: Any]? { ... }
    private static func usageDataObject(from root: [String: Any]) -> [String: Any]? { ... }
    private static func costCurrencyItems(from root: [String: Any]) -> [[String: Any]] { ... }
    private static func stringValue(_ value: Any?) -> String? { ... }
    private static func decimalValue(_ value: Any?) -> Decimal? { ... }
}
```

（上面 `...` 处逐字照抄 `DeepSeekUsageProvider.swift` 里对应函数的实现，不要改写。）

然后让 `DeepSeekUsageParser` 改调它：删掉它自己的同名私有函数，把内部调用点换成 `DeepSeekPayload.xxx`。`moneyText` 与 `ParserError` 留在解析器里不动。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter DeepSeekPayloadTests`
Expected: `Test run with 6 tests in 1 suite passed`

- [ ] **Step 5: 跑全量测试确认解析器行为没变**

Run: `bash scripts/test.sh`
Expected: 全绿（`DeepSeekAmountTests` 是这一步的回归网）。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/DeepSeekPayload.swift Sources/TokenHealth/DeepSeekUsageProvider.swift \
        Tests/TokenHealthTests/DeepSeekPayloadTests.swift
git commit -m "$(cat <<'EOF'
Extract the DeepSeek response shape walk

The detail builder needs the same walk the parser does, and the two
endpoints have asymmetric shapes that would drift if copied.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 4: 从 bundle 构建详情

**Files:**
- Create: `Sources/TokenHealth/DeepSeekUsageDetail.swift`
- Test: `Tests/TokenHealthTests/DeepSeekUsageDetailTests.swift`

这是本次的核心。规则全部来自 spec §5。

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/DeepSeekUsageDetailTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct DeepSeekUsageDetailTests {
    // 测试用固定「今天」，让补 0 的区间可预期。
    private let period = DeepSeekUsagePeriod(year: 2026, month: 9, day: "2026-09-24")

    private func bundle(amountDays: String, costDays: String?) -> Data {
        let cost = costDays.map { "\"cost\":{\"data\":[{\"currency\":\"CNY\",\"days\":\($0)}]}" } ?? "\"cost\":{}"
        let json = "{\"summary\":{},\"amount\":{\"data\":{\"biz_data\":{\"days\":\(amountDays)}}},\(cost)}"
        return Data(json.utf8)
    }

    /// 一天：model 的四种 type + 费用
    private func day(_ date: String, model: String, requests: Int, output: Int, hit: Int, miss: Int) -> String {
        """
        {"date":"\(date)","data":[{"model":"\(model)","usage":[
          {"type":"REQUEST","amount":"\(requests)"},
          {"type":"RESPONSE_TOKEN","amount":"\(output)"},
          {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"\(hit)"},
          {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"\(miss)"}]}]}
        """
    }

    private func balances(_ pairs: [(String, String)]) -> [TokenUsage] {
        pairs.map { currency, amount in
            TokenUsage(
                window: .balance, label: "Balance \(currency)", used: 0, limit: nil,
                resetDate: nil, unit: currency, displayValue: "\(amount) \(currency)",
                amount: Decimal(string: amount)
            )
        }
    }

    @Test
    func buildsHeadlineFromBalances() throws {
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: bundle(amountDays: "[]", costDays: nil),
                balances: balances([("CNY", "1284.60"), ("USD", "3.00")]),
                today: period
            )
        )

        #expect(detail.headline.map(\.label) == ["CNY", "USD"])
        #expect(detail.headline.map(\.value) == ["1,284.60 CNY", "3.00 USD"])
    }

    @Test
    func sumsTodayAndTheMonthAcrossModels() throws {
        let amount = """
        [\(day("2026-09-23", model: "deepseek-chat", requests: 10, output: 100, hit: 200, miss: 50)),
         \(day("2026-09-24", model: "deepseek-chat", requests: 4, output: 40, hit: 80, miss: 20)),
         \(day("2026-09-24", model: "deepseek-reasoner", requests: 2, output: 60, hit: 10, miss: 30))]
        """
        let cost = """
        [\(day("2026-09-23", model: "deepseek-chat", requests: 0, output: 0, hit: 0, miss: 0)),
         \(day("2026-09-24", model: "deepseek-chat", requests: 0, output: 0, hit: 0, miss: 0))]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: bundle(amountDays: amount, costDays: cost),
                balances: [],
                today: period
            )
        )

        let today = try #require(detail.groups.first { $0.title == "今日" })
        #expect(today.values.map(\.label) == ["Requests", "Tokens", "Cost"], "浮层文案与 App 其余部分一致，用英文")
        #expect(today.values[0].value == "6")
        #expect(today.values[1].value == "240")
    }

    @Test
    func padsMissingDaysWithZero() throws {
        let amount = "[\(day("2026-09-01", model: "m", requests: 1, output: 10, hit: 0, miss: 0))," +
                     " \(day("2026-09-24", model: "m", requests: 1, output: 10, hit: 0, miss: 0))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let series = try #require(detail.series)
        #expect(series.points.count == 24, "当月 1 号到今天，逐日一个点")
        #expect(series.points.first?.value == 10)
        #expect(series.points[1].value == 0, "中间没数据的日期补 0")
        #expect(series.points.last?.value == 10)
        #expect(series.axisStart == "9/1")
        #expect(series.axisEnd == "9/24")
    }

    @Test
    func sumsDuplicateDatesInsteadOfDoubleCounting() throws {
        let amount = "[\(day("2026-09-24", model: "m", requests: 2, output: 10, hit: 0, miss: 0))," +
                     " \(day("2026-09-24", model: "m", requests: 3, output: 5, hit: 0, miss: 0))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let series = try #require(detail.series)
        #expect(series.points.count == 24)
        #expect(series.points.last?.value == 15, "同一天出现两次要相加，且只产出 1 个点")
        let today = try #require(detail.groups.first { $0.title == "今日" })
        #expect(today.values[0].value == "5")
    }

    @Test
    func reportsTheTokenBreakdown() throws {
        let amount = "[\(day("2026-09-10", model: "m", requests: 1, output: 100, hit: 900, miss: 20))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        #expect(detail.breakdown.map(\.label) == ["Output", "Cache hit", "Cache miss"])
        #expect(detail.breakdown.map(\.value) == ["100", "900", "20"])
    }

    @Test
    func buildsAModelTableSortedByTokens() throws {
        let amount = """
        [\(day("2026-09-10", model: "small", requests: 1, output: 10, hit: 0, miss: 0)),
         \(day("2026-09-10", model: "big", requests: 5, output: 5_000, hit: 0, miss: 0))]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let table = try #require(detail.table)
        #expect(table.columns == ["Model", "Requests", "Tokens", "Cost"])
        #expect(table.rows.map(\.name) == ["big", "small"])
        #expect(table.rows[0].cells.count == table.columns.count - 1)
        #expect(table.rows[0].cells == ["5", "5K", "—"], "没有 cost 数据时花费是破折号")
    }

    @Test
    func keepsModelsThatOnlyAppearInTheCostResponse() throws {
        let amount = "[\(day("2026-09-10", model: "chat", requests: 1, output: 100, hit: 0, miss: 0))]"
        let cost = "[\(day("2026-09-10", model: "chat", requests: 0, output: 0, hit: 0, miss: 0))," +
                   " \(day("2026-09-10", model: "legacy", requests: 0, output: 0, hit: 0, miss: 0))]"
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: cost), balances: [], today: period)
        )

        let table = try #require(detail.table)
        #expect(table.rows.count == 2)
        let legacy = try #require(table.rows.first { $0.name == "legacy" })
        #expect(legacy.cells[1] == "0", "只在 cost 里出现的模型仍然成行")
    }

    @Test
    func mergesUnnamedModelsIntoOneRow() throws {
        let amount = """
        [{"date":"2026-09-10","data":[
            {"usage":[{"type":"RESPONSE_TOKEN","amount":"100"}]},
            {"model":"","usage":[{"type":"RESPONSE_TOKEN","amount":"50"}]}]}]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: nil), balances: [], today: period)
        )

        let table = try #require(detail.table)
        #expect(table.rows.map(\.name) == ["Unknown model"])
        #expect(table.rows[0].cells[1] == "150")
    }

    @Test
    func truncatesTheTableToSixRowsWithAFootnote() throws {
        let entries = (1...8).map { index in
            day("2026-09-10", model: "model-\(index)", requests: 1, output: index * 100, hit: 0, miss: 0)
        }
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: bundle(amountDays: "[\(entries.joined(separator: ","))]", costDays: nil),
                balances: [],
                today: period
            )
        )

        let table = try #require(detail.table)
        #expect(table.rows.count == 6)
        #expect(table.footnote == "+2 more models")
        #expect(table.rows.first?.name == "model-8", "按 tokens 降序")
    }

    @Test
    func joinsMultipleCurrenciesWithASeparator() throws {
        let amount = "[\(day("2026-09-24", model: "m", requests: 1, output: 10, hit: 0, miss: 0))]"
        let cost = """
        [{"currency":"USD","days":[{"date":"2026-09-24","data":[{"model":"m","usage":[{"amount":"0.30"}]}]}]},
         {"currency":"CNY","days":[{"date":"2026-09-24","data":[{"model":"m","usage":[{"amount":"41.80"}]}]}]}]
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: amount, costDays: cost), balances: [], today: period)
        )

        let today = try #require(detail.groups.first { $0.title == "今日" })
        #expect(today.values[2].value == "41.80 CNY · 0.30 USD", "币种按名字升序")
    }

    @Test
    func reportsNoDataForAQuietMonth() throws {
        let detail = try #require(
            DeepSeekUsageDetail.make(bundle: bundle(amountDays: "[]", costDays: nil), balances: [], today: period)
        )

        #expect(detail.series?.points.count == 24)
        #expect(detail.series?.points.allSatisfy { $0.value == 0 } == true)
        #expect(detail.table == nil, "没有模型就不画表")
    }

    @Test
    func returnsNilForAMalformedBundle() {
        #expect(DeepSeekUsageDetail.make(bundle: Data("not json".utf8), balances: [], today: period) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter DeepSeekUsageDetailTests`
Expected: 编译失败，`cannot find 'DeepSeekUsageDetail' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/DeepSeekUsageDetail.swift`：

```swift
import Foundation

/// 把一次刷新取回的 bundle 变成浮层要画的 `UsageDetail`。
///
/// 不抛错：解析不出来就返回 nil，让菜单栏项退回小菜单 —— 详情失败不该影响面板上的用量。
enum DeepSeekUsageDetail {
    static func make(bundle: Data, balances: [TokenUsage], today: DeepSeekUsagePeriod) -> UsageDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: bundle) as? [String: Any] else {
            return nil
        }

        let days = aggregateAmountDays(root["amount"] as? [String: Any] ?? [:], today: today)
        let costByDay = aggregateCostDays(root["cost"] as? [String: Any] ?? [:], today: today)
        let merged = merge(days: days, cost: costByDay)

        var detail = UsageDetail()
        detail.headline = headline(from: balances)
        detail.groups = groups(today: today, days: merged)
        detail.series = series(today: today, days: merged)
        detail.breakdown = breakdown(days: merged)
        detail.table = table(days: merged)
        return detail
    }
    ...
}
```

实现要点（全部按 spec §5，逐条对应）：

- `aggregateAmountDays`：`DeepSeekPayload.days(fromAmount:)` → 对每个 day 取 `dateText` 的**前 10 个字符**按 `yyyy-MM-dd`（UTC）解析；解析失败的那天整条跳过；日期落在 [当月 1 号, 今天] 之外也跳过。同一天**求和**。每天累计 requests / outputTokens / cacheHitTokens / cacheMissTokens，并给每个模型单独累计一份（`models[model]`，空名归 `Unknown model`）。
  取前缀而不是整串匹配，是为了容忍 `"2026-09-24T00:00:00Z"` 这类带后缀的写法 —— 既有解析器的 `hasPrefix` 就是这么宽容的，两处口径要对齐。
- `aggregateCostDays`：`DeepSeekPayload.costCurrencies(fromCost:)` → 每天每币种求和，同时按模型累计 `costByCurrency`。
- `merged`：把两份按日期并起来，缺的一边当 0。
- `headline`：`balances` 里每一项 `value = UsageAmountFormatter.moneyText(amount) + " " + unit`，`label = unit`。**不重新解析 summary**。
- `groups`：今日 = merged 里等于今天的那个（没有就是全 0）；本月 = 全部求和。每个 group 三个 `DetailStat`：请求（`compactAmount`）、Tokens（`compactAmount`）、花费（按币种升序 `moneyText + " " + code` 用 ` · ` 连；一个币种都没有就是 `—`）。
- `series`：从当月 1 号到今天逐日取，缺的补 0，`value` 是该日三种 token 之和；`axisStart`/`axisEnd` 用 `M/d`。
- `breakdown`：本月三个 type 的合计，label「输出」「缓存命中」「缓存未命中」。
- `table`：模型并集（amount 侧 + cost 侧），**tokens 与花费都为 0 的模型不成行**（沿用既有解析器丢掉空模型的做法，免得白占 6 行里的位置），按 tokens 降序、同名升序，前 6 行，其余进 `footnote`（`+N more models`）。单元格依次是次数、Tokens、花费。
- 日期工具：一个私有的 `Calendar`（UTC）+ `DateFormatter`（`en_US_POSIX`，`yyyy-MM-dd` / `M/d`）。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter DeepSeekUsageDetailTests`
Expected: `Test run with 12 tests in 1 suite passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/DeepSeekUsageDetail.swift Tests/TokenHealthTests/DeepSeekUsageDetailTests.swift
git commit -m "$(cat <<'EOF'
Build the DeepSeek usage detail from the bundle

Everything here was already being fetched and thrown away: the whole
month's per-day, per-model, per-type data.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 5: 柱高归一化

**Files:**
- Create: `Sources/TokenHealth/DetailSeriesChart.swift`
- Test: `Tests/TokenHealthTests/DetailSeriesChartTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/DetailSeriesChartTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct DetailSeriesChartTests {
    private func points(_ values: [Double]) -> [DetailSeriesPoint] {
        values.enumerated().map { index, value in
            DetailSeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(index) * 86_400), value: value)
        }
    }

    @Test
    func normalizesAgainstTheLargestPoint() {
        let heights = DetailSeriesChart.heights(points: points([0, 50, 100]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights == [0, 20, 40])
    }

    @Test
    func reportsZeroMaximumForAnEmptyOrAllZeroSeries() {
        #expect(DetailSeriesChart.maximum(of: []) == 0)
        #expect(DetailSeriesChart.maximum(of: points([0, 0, 0])) == 0)

        let heights = DetailSeriesChart.heights(points: points([0, 0]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights == [0, 0], "全 0 时不该出现一排最小高度的柱子")
    }

    @Test
    func keepsTinyNonZeroValuesVisible() {
        let heights = DetailSeriesChart.heights(
            points: points([1_000_000, 1]),
            maxHeight: 40,
            minimumVisibleHeight: 1.5
        )
        #expect(heights[0] == 40)
        #expect(heights[1] == 1.5, "非 0 但极小的值托到最小可见高度")
    }

    @Test
    func handlesASinglePoint() {
        let heights = DetailSeriesChart.heights(points: points([7]), maxHeight: 40, minimumVisibleHeight: 1)
        #expect(heights == [40])
    }

    @Test
    func neverExceedsTheGivenHeight() {
        let heights = DetailSeriesChart.heights(
            points: points([3, 1, 2]),
            maxHeight: 40,
            minimumVisibleHeight: 1
        )
        #expect(heights.allSatisfy { $0 <= 40 })
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter DetailSeriesChartTests`
Expected: 编译失败，`cannot find 'DetailSeriesChart' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/DetailSeriesChart.swift`：

```swift
import CoreGraphics

/// 趋势图的纯几何：把一串点归一化成柱高。
/// 与 `MenuBarItemLayout` 同一路数 —— 不碰 AppKit，便于在无窗口进程里验证。
enum DetailSeriesChart {
    /// 归一化基准：所有点的最大值。空序列或全 0 返回 0。
    static func maximum(of points: [DetailSeriesPoint]) -> Double {
        points.map(\.value).filter { $0.isFinite && $0 > 0 }.max() ?? 0
    }

    /// 与 `points` 一一对应的柱高。
    /// 值为 0 的柱高为 0；非 0 但极小的值托到 `minimumVisibleHeight`，避免看不见。
    static func heights(
        points: [DetailSeriesPoint],
        maxHeight: CGFloat,
        minimumVisibleHeight: CGFloat
    ) -> [CGFloat] {
        let peak = maximum(of: points)
        guard peak > 0, maxHeight > 0 else {
            return points.map { _ in 0 }
        }
        return points.map { point in
            guard point.value.isFinite, point.value > 0 else {
                return 0
            }
            let scaled = maxHeight * CGFloat(point.value / peak)
            return min(maxHeight, max(minimumVisibleHeight, scaled))
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter DetailSeriesChartTests`
Expected: `Test run with 5 tests in 1 suite passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/DetailSeriesChart.swift Tests/TokenHealthTests/DetailSeriesChartTests.swift
git commit -m "$(cat <<'EOF'
Normalize detail chart bar heights

Pure geometry, so the one piece of arithmetic the chart does is testable
without a drawing context.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 6: 谁会产出详情

**Files:**
- Modify: `Sources/TokenHealth/Providers.swift`（`ProviderFactory`）
- Test: `Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct ProviderDetailCapabilityTests {
    private func config(_ kind: ProviderKind, auth: AuthMode) -> ServiceConfig {
        ServiceConfig(displayName: kind.title, providerKind: kind, authMode: auth)
    }

    @Test
    func onlyBrowserLoginDeepSeekProducesDetail() {
        #expect(ProviderFactory.producesUsageDetail(for: config(.deepSeek, auth: .browserLogin)))
        #expect(!ProviderFactory.producesUsageDetail(for: config(.deepSeek, auth: .api)),
                "API key 模式走的是公开余额接口，没有平台用量明细")
    }

    @Test
    func everyOtherProviderIsUnsupported() {
        for kind in ProviderKind.allCases where kind != .deepSeek {
            for auth in AuthMode.allCases {
                #expect(
                    !ProviderFactory.producesUsageDetail(for: config(kind, auth: auth)),
                    "\(kind) / \(auth) 不该被当成支持详情"
                )
            }
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter ProviderDetailCapabilityTests`
Expected: 编译失败，`type 'ProviderFactory' has no member 'producesUsageDetail'`

- [ ] **Step 3: 实现**

在 `Sources/TokenHealth/Providers.swift` 的 `ProviderFactory` 里加：

```swift
    /// 这个 config 会不会产出 `UsageDetail` —— 也就是点它的菜单栏项该弹浮层还是弹小菜单。
    ///
    /// 按 **Provider 能力**判断而不是按快照内容判断：首次刷新还没回来时也得能弹出浮层，
    /// 否则会出现「先弹菜单、快照回来后再改行为」的漂移。
    static func producesUsageDetail(for config: ServiceConfig) -> Bool {
        switch config.providerKind {
        case .deepSeek:
            // 登录模式走平台接口，有按天/按模型的明细；API key 模式只有公开余额接口。
            config.authMode == .browserLogin
        default:
            false
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter ProviderDetailCapabilityTests`
Expected: `Test run with 2 tests in 1 suite passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/Providers.swift Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift
git commit -m "$(cat <<'EOF'
Declare which configs produce a usage detail

Keyed on provider capability rather than on the snapshot, so a click
behaves the same before and after the first refresh lands.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 7: 单账号刷新与「上次的好数据」

**Files:**
- Modify: `Sources/TokenHealth/AppState.swift`
- Test: `Tests/TokenHealthTests/AppStateRefreshTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/AppStateRefreshTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

private struct DetailStubFetcher: ExchangeRateFetching {
    func fetchTable() async throws -> ExchangeRateTable { throw StubFailure() }
}

private struct StubFailure: Error {}

@MainActor
struct AppStateRefreshTests {
    private func makeState(defaults: UserDefaults) -> AppState {
        let store = ConfigStore(defaults: defaults, secretStore: InMemorySecretStore())
        return AppState(
            configStore: store,
            usageReporter: UsageReporter(),
            rateStore: ExchangeRateStore(configStore: store, fetcher: DetailStubFetcher())
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "app-state-refresh-tests-\(UUID().uuidString)")!
    }

    private func readySnapshot(_ id: UUID, detail: UsageDetail?) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: id,
            serviceName: "DeepSeek",
            providerTitle: "DeepSeek",
            usages: [TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "1.00 CNY")],
            detail: detail,
            state: .ready,
            statusMessage: "ok",
            updatedAt: Date()
        )
    }

    private let sampleDetail = UsageDetail(
        headline: [DetailStat(label: "CNY", value: "1.00 CNY")],
        groups: [DetailGroup(title: "今日", values: [DetailStat(label: "请求", value: "3")])]
    )

    @Test
    func refreshingOneAccountLeavesTheOthersAlone() async {
        let state = makeState(defaults: makeDefaults())
        let pinned = state.addConfig(providerKind: .kimiCode)
        let other = state.addConfig(providerKind: .kimiCode)
        state.snapshots[pinned] = readySnapshot(pinned, detail: nil).with(serviceName: "Pinned")
        state.snapshots[other] = readySnapshot(other, detail: nil).with(serviceName: "Other")

        await state.refresh(configID: pinned)

        #expect(state.snapshots[other]?.serviceName == "Other", "别的账号的快照不该被动过")
    }

    @Test
    func refusesWhileAWholeRefreshIsRunning() async {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.snapshots[id] = readySnapshot(id, detail: sampleDetail)
        state.isRefreshing = true

        await state.refresh(configID: id)

        #expect(state.snapshots[id]?.detail != nil, "整体刷新进行中时单账号刷新直接返回")
    }

    @Test
    func refusesForADisabledAccount() async {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.configs[0].isEnabled = false
        state.snapshots[id] = readySnapshot(id, detail: sampleDetail)

        await state.refresh(configID: id)

        #expect(state.snapshots[id]?.detail != nil)
    }

    @Test
    func keepsTheLastGoodDetailWhenARefreshFails() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        let old = readySnapshot(id, detail: sampleDetail)
        state.snapshots[id] = old
        let previousUpdatedAt = old.updatedAt

        // 失败时 provider 返回的是 unavailable 快照，detail 为空。
        state.snapshots[id] = ProviderUsageSnapshot.unavailable(
            config: state.configs[0],
            message: "HTTP 503"
        )

        #expect(state.snapshots[id]?.state == .unavailable)
        #expect(state.snapshots[id]?.detail == sampleDetail, "失败要保留上次的数字，否则浮层会被清空、菜单栏项还会被打回旧菜单")
        #expect(state.snapshots[id]?.statusMessage == "HTTP 503", "错误信息仍然要能显示出来")
        #expect(state.snapshots[id]?.updatedAt == previousUpdatedAt, "保留旧时间戳，别谎报数据是刚刚取的")
    }

    @Test
    func aReadySnapshotReplacesTheDetailOutright() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.snapshots[id] = readySnapshot(id, detail: sampleDetail)

        state.snapshots[id] = readySnapshot(id, detail: nil)

        #expect(state.snapshots[id]?.detail == nil, "成功取数时该以新结果为准，不做合并")
    }

    @Test
    func theFirstFailureHasNothingToKeep() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)

        state.snapshots[id] = ProviderUsageSnapshot.unavailable(config: state.configs[0], message: "HTTP 503")

        #expect(state.snapshots[id]?.detail == nil)
    }
}

private extension ProviderUsageSnapshot {
    func with(serviceName: String) -> ProviderUsageSnapshot {
        var copy = self
        copy.serviceName = serviceName
        return copy
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter AppStateRefreshTests`
Expected: 编译失败，`value of type 'AppState' has no member 'refresh'`

- [ ] **Step 3: 实现**

在 `Sources/TokenHealth/AppState.swift` 里：

`performRefresh` 的循环改成走一个共用方法：

```swift
    private func storeSnapshot(_ snapshot: ProviderUsageSnapshot, for id: UUID) {
        // 取数失败时 Provider 给的是 unavailable 快照，detail 为空。直接覆盖会把上次的数字抹掉，
        // 浮层被清空、菜单栏项还会被打回旧菜单 —— 所以非 ready 时把旧 detail 留下来。
        var incoming = snapshot
        if incoming.state != .ready, incoming.detail == nil, let previous = snapshots[id] {
            incoming.detail = previous.detail
            // updatedAt 在这个 App 里表示「这些数字是什么时候取到的」。用失败那刻的时间会让
            // 浮层表头显示「刚刚」，而数字其实是十分钟前的。
            if previous.detail != nil {
                incoming.updatedAt = previous.updatedAt
            }
        }
        snapshots[id] = incoming
    }
```

`performRefresh` 的循环体里 `snapshots[config.id] = await provider.fetchUsage(...)` 改为 `storeSnapshot(await provider.fetchUsage(...), for: config.id)`。

新增单账号刷新：

```swift
    /// 只重取一个账号，供详情浮层用。与整体刷新共用 `isRefreshing` 互斥。
    ///
    /// 刻意**不**更新 `lastRefreshAt`、也不重排定时器：面板表头那句「N/M updated · Xm ago」
    /// 讲的是整体刷新的新鲜度，只刷了一个账号却显示「刚刚刷新」是在撒谎。
    func refresh(configID: UUID) async {
        guard !isRefreshing,
              let config = configs.first(where: { $0.id == configID }),
              config.isEnabled else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let secrets = config.providerKind.usesLocalLogin
            ? ProviderSecrets.empty
            : configStore.loadSecrets(for: config.id)
        let provider = providerFactory.provider(for: config)
        storeSnapshot(await provider.fetchUsage(config: config, secrets: secrets), for: config.id)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter AppStateRefreshTests`
Expected: `Test run with 6 tests in 1 suite passed`

- [ ] **Step 5: 跑全量测试**

Run: `bash scripts/test.sh`
Expected: 全绿。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/AppState.swift Tests/TokenHealthTests/AppStateRefreshTests.swift
git commit -m "$(cat <<'EOF'
Refresh a single account and keep the last good detail

A failed fetch used to overwrite the snapshot wholesale, which would have
blanked the detail popover and flipped the menu bar item back to a menu.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: 视图与接线

### Task 8: 浮层视图

**Files:**
- Create: `Sources/TokenHealth/DetailPopoverView.swift`
- Test: `Tests/TokenHealthTests/DetailPopoverRenderTests.swift`

- [ ] **Step 1: 实现视图**

创建 `Sources/TokenHealth/DetailPopoverView.swift`。要点：只读、无交互、空区块整个不渲染、宽度固定 320。

```swift
import SwiftUI

/// 钉住项的详情浮层。只展示，不可交互 —— 筛选、日期范围、下钻都留给厂商的控制台。
struct DetailPopoverView: View {
    let serviceName: String
    let detail: UsageDetail?
    let statusMessage: String?
    let updatedAt: Date?
    let onRefresh: () -> Void
    let onUnpin: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let detail, !detail.isEmpty {
                content(detail)
            } else {
                Text(statusMessage ?? "Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
    }
    ...
}
```

`content(_:)` 依次渲染 headline / groups / series / breakdown / table，每个空数组或 nil 就跳过。趋势图用 `GeometryReader` 拿到宽度后，把 `DetailSeriesChart.heights` 的结果画成一排 `Rectangle`（柱子间 1pt 间隔，底部对齐）。

- [ ] **Step 2: 写渲染冒烟测试**

创建 `Tests/TokenHealthTests/DetailPopoverRenderTests.swift`，与既有的 `StatusMenuPanelRenderTests` 同一路数：

```swift
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TokenHealth

@MainActor
struct DetailPopoverRenderTests {
    @Test
    func rendersAFullDetail() throws {
        let image = try render(fullDetail)
        #expect(image.height > 200)
        #expect(image.width == 640, "320pt @2x")
    }

    @Test
    func rendersAnEmptyDetailWithoutCrashing() throws {
        let image = try render(UsageDetail())
        #expect(image.height > 0)
    }

    private var fullDetail: UsageDetail { ... }   // 覆盖五个区块都非空的构造

    private func render(_ detail: UsageDetail?) throws -> (width: Int, height: Int) {
        let renderer = ImageRenderer(
            content: DetailPopoverView(
                serviceName: "DeepSeek",
                detail: detail,
                statusMessage: nil,
                updatedAt: Date(),
                onRefresh: {}, onUnpin: {}, onOpenSettings: {}, onQuit: {}
            )
        )
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return (image.width, image.height)
    }
}
```

- [ ] **Step 3: 跑测试确认通过**

Run: `bash scripts/test.sh --filter DetailPopoverRenderTests`
Expected: `Test run with 2 tests in 1 suite passed`

- [ ] **Step 4: 目视确认**

临时把渲染结果写成 PNG 看一眼版式（做法与之前渲染菜单栏项一致：`renderer.cgImage` → `NSBitmapImageRep` → 写文件），确认五个区块的层次、趋势图、底部按钮。**看完删掉临时用例**。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/DetailPopoverView.swift Tests/TokenHealthTests/DetailPopoverRenderTests.swift
git commit -m "$(cat <<'EOF'
Render the usage detail popover

Read-only by design: filters and date ranges belong to the vendor console,
not to a menu bar glance.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 9: 让 DeepSeek 产出详情

**Files:**
- Modify: `Sources/TokenHealth/DeepSeekUsageProvider.swift`
- Test: `Tests/TokenHealthTests/DeepSeekDetailWiringTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/DeepSeekDetailWiringTests.swift`：用合成的 bundle 走一遍 `DeepSeekUsageProvider` 的公开入口 —— 这需要注入会话凭据，参考既有 `DeepSeekAmountTests` 里构造 `DeepSeekWebSessionCredential` 的方式；断言产出的快照 `state == .ready`、`usages` 非空、`detail != nil`、且 `detail.headline` 与 snapshot 里的 balance 对得上。

同时断言：**公开余额模式（API key）产出的快照 `detail == nil`**。

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter DeepSeekDetailWiringTests`
Expected: 断言失败，`detail` 为 nil

- [ ] **Step 3: 实现**

在 `DeepSeekUsageProvider.fetchPlatformUsage` 里，解析出 usages 之后、构造快照之前插入：

```swift
            let usages = try DeepSeekUsageParser().parsePlatformBundle(data: bundleData, today: period.day)
            let detail = DeepSeekUsageDetail.make(
                bundle: bundleData,
                balances: usages.filter { $0.window == .balance },
                today: period
            )
            return ProviderUsageSnapshot(
                ...
                usages: usages,
                detail: detail,
                ...
            )
```

公开余额那条路径（`fetchPublicBalance`）不动，`detail` 保持 nil。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter DeepSeekDetailWiringTests`
Expected: 通过

- [ ] **Step 5: 跑全量测试 + 构建**

Run: `bash scripts/test.sh && bash scripts/build-app.sh`
Expected: 全绿；构建成功。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/DeepSeekUsageProvider.swift Tests/TokenHealthTests/DeepSeekDetailWiringTests.swift
git commit -m "$(cat <<'EOF'
Feed the DeepSeek detail into its snapshot

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 10: 控制器弹出浮层

**Files:**
- Modify: `Sources/TokenHealth/PinnedStatusItemController.swift`

- [ ] **Step 1: 实现**

在 `PinnedStatusItemController` 里：

- 新增 `private var popovers: [UUID: NSPopover] = [:]` 与 `private var detailHosts: [UUID: NSHostingController<DetailPopoverView>] = [:]`。
- `statusItem(for:)` 创建项时**一次性**设 `created.button?.identifier = NSUserInterfaceItemIdentifier(id.uuidString)`。
- `updateStatusItem(for:)` 末尾按能力分支：

```swift
        if ProviderFactory.producesUsageDetail(for: config) {
            // menu 非空时按钮点击根本不会触发 action，所以两个方向都必须显式赋值。
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(showDetail(_:))
        } else {
            item.button?.target = nil
            item.button?.action = nil
            item.menu = makeMenu(for: config)
        }
        refreshOpenPopover(for: config)
```

- `showDetail(_ sender: NSStatusBarButton)`：从 `sender.identifier` 取回 UUID → 关闭已有的同 id 浮层 → 建 `DetailPopoverView`（回调分别指向 `appState.refresh(configID:)`、`appState.setPinned(id, false)`、打开设置、退出）→ `NSHostingController` → `NSPopover(behavior: .transient)` → `show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)`。若快照为空或 `updatedAt` 超过 5 分钟，`Task { await appState.refresh(configID: id) }`。
- `refreshOpenPopover(for:)`：浮层开着时把 `hostingController.rootView` 换成用最新数据构造的视图，实现「就地更新、不关闭」。
- `removeStatusItem(for:)` / `removeAllStatusItems()` / `stop()` 里一并 `popovers[id]?.close()` 并清理两个字典。

注意 `NSPopover` 的 `behavior = .transient` 要能响应外部点击关闭，需要 `NSApp.activate(ignoringOtherApps: true)`。

- [ ] **Step 2: 编译并冒烟**

Run: `bash scripts/build-app.sh && open ".build/app/Token Health.app"`
Expected: 构建成功、应用起来不崩。手工点一下非 DeepSeek 的钉住项确认还是小菜单。

- [ ] **Step 3: 提交**

```bash
git add Sources/TokenHealth/PinnedStatusItemController.swift
git commit -m "$(cat <<'EOF'
Open a detail popover from a pinned menu bar item

Items whose provider produces a detail swap their menu for a transient
popover; everything else keeps the menu it had.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 11: 文档与验收

**Files:**
- Modify: `README.md`
- Modify: `AppSupport/Info.plist`（版本）

- [ ] **Step 1: 版本号**

Run: `grep -n "CFBundleShortVersionString" -A 1 AppSupport/Info.plist`
Expected: 打印 `0.10.0`。升到 `0.11.0`，`CFBundleVersion` 从 20 升到 21。

- [ ] **Step 2: README**

在「钉住账号」一节末尾追加：

```markdown
点钉住的 DeepSeek 项会弹出详情浮层：余额、今日与本月合计、本月按天趋势、tokens 构成（输出 / 缓存命中 / 未命中），
以及本月按模型的次数、tokens 与花费。数据全部来自刷新时已经取回的那次响应，不额外发请求。

它只做展示 —— 没有筛选、没有日期范围、不能下钻。要看更细的分析请回厂商的控制台。
详情里的数字若超过 5 分钟会在打开时自动刷新一次，右上角也可以手动刷新；取数失败时保留上一次的数字并标出错误。
```

- [ ] **Step 3: 全量验收**

Run: `bash scripts/test.sh && bash scripts/build-app.sh`
Expected: 全绿；构建成功。

- [ ] **Step 4: 逐条走 spec §13 的手工验收**

对着 spec `docs/superpowers/specs/2026-09-24-pinned-provider-detail-design.md` 第 13 节的 8 条逐条确认，特别是：

- 浮层数字与厂商控制台的当月数据对得上（当月 1 号至今，UTC）。
- 断网刷新后浮层保留旧数字、显示红色错误行，菜单栏项**不**变回旧菜单。
- 非 DeepSeek 的钉住项仍然是原来的小菜单。

- [ ] **Step 5: 提交**

```bash
git add README.md AppSupport/Info.plist
git commit -m "$(cat <<'EOF'
Bump to 0.11.0 and document the detail popover

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## 已知风险

| 风险 | 应对 |
| --- | --- |
| `NSPopover` 在 accessory app 里 `.transient` 不响应外部点击 | Task 10 Step 1 已注明要先 `NSApp.activate`；验收第 4 条专门确认 |
| 真实的 DeepSeek 响应里 `days` 可能超出当月 | 解析只取日期落在当月的那些天；超出部分忽略（现有解析器也是按 `today` 前缀匹配） |
| 金额格式搬家后与面板显示不一致 | Task 1 Step 5 跑全量测试兜底；`MenuBarMetricsTests` 里已有金额断言 |
| 浮层高度在模型多时超屏 | 视图上限 520 并滚动；模型表本身已截断到 6 行 |
| 时区：用户不在 UTC 时「今日」与本地日期不一致 | 与厂商接口、与既有 `DeepSeekUsagePeriod.currentUTC()` 同一口径，不自行换算 |
