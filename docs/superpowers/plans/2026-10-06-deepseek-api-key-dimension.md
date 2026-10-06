# DeepSeek 详情浮层·按 API key 维度 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 DeepSeek 详情浮层里，`By model · this month` 表下面再加一张同构的 `By API key · this month` 表。

**Architecture:** 新增两个 DeepSeek 私有端点（`by_api_key/amount`、`by_api_key/cost`），在刷新时与现有三个端点并发取回、并进同一个 bundle；详情构建器仍是纯函数（只吃 bundle）。为放得下第二张表，把共享的 `UsageDetail.table: DetailTable?` 改成 `tables: [DetailTable]`。

**Tech Stack:** Swift 6 / SwiftUI / swift-testing；本机无 Xcode，测试走 `bash scripts/test.sh`。

**Spec:** `docs/superpowers/specs/2026-10-06-deepseek-api-key-dimension-design.md`

## Global Constraints

- 全部文案是英文，与浮层其余部分一致（`By API key · this month`、`API key`、`Requests`、`Tokens`、`Cost`、`+N more API keys`、`Unknown key`）。中点 `·` 前后各一个空格。
- 表口径是**本月至今日 UTC**，与 `By model` 表完全一致；`tz` 固定 `0`。
- 所有窗口一律走 `UsageDetailSupport.utcCalendar()`，绝不用 `.current`。
- 新端点**尽力而为**：任何失败都只让这张表不出现，不影响其余区块、菜单栏数字与卡片。
- 代码注释用中文，风格与既有文件一致（解释「为什么」，不解释「做了什么」）。
- 跑测试：`bash scripts/test.sh`。直接 `swift test` 会报 `no such module 'Testing'`。
- 实现完成后版本号从 `1.0.6` 升到 `1.0.7`（`AppSupport/Info.plist:16`）。

## Review Focus

这些是 spec 隐含、但任何单个任务的测试都不容易自然覆盖到的输入，最可能咬到真实使用者：

1. **同一把 key 在 amount 侧是对象、在 cost 侧是裸字符串** —— 两侧必须推断出同一个身份，否则一把 key 被拆成两行（一行有 token 没花费、一行有花费没 token）。
2. **`api_key` 是 `null`、空对象或第三种类型** —— 应当归到 `Unknown key` 一行，不该崩、也不该把用量整条丢掉。
3. **窗口边界日的 bucket** —— `start` 当天与「明日零点之前」的最后一个 bucket 必须收进来，越界的必须丢掉。
4. **两把 key 展示名相同** —— `DetailTableRow.id` 取 `name`，重名会让 `ForEach` 出错，必须改名。
5. **两张表都满 6 行 + 脚注** —— 320pt 宽的浮层要能光栅化，不崩。

---

### Task 1: `UsageDetail.table` 改成 `tables: [DetailTable]`

**Files:**
- Modify: `Sources/TokenHealth/UsageDetail.swift:7-18`
- Modify: `Sources/TokenHealth/DetailPopoverView.swift:154-190`
- Modify: `Sources/TokenHealth/CodexUsageDetail.swift:32`
- Modify: `Sources/TokenHealth/CursorUsageDetail.swift:103`
- Modify: `Sources/TokenHealth/OpenCodeGoUsageDetail.swift:54`
- Modify: `Sources/TokenHealth/DeepSeekUsageDetail.swift:57`
- Test: `Tests/TokenHealthTests/DetailPopoverRenderTests.swift`
- Test: `Tests/TokenHealthTests/DeepSeekUsageDetailTests.swift`、`CodexUsageDetailTests.swift`、`CursorUsageDetailTests.swift`、`OpenCodeGoUsageDetailTests.swift`、`DeepSeekDetailWiringTests.swift`、`CodexUsageProviderTests.swift`、`CursorUsageProviderTests.swift`、`OpenCodeGoDetailWiringTests.swift`

**Interfaces:**
- Consumes: 无（本任务是最底层）
- Produces: `UsageDetail.tables: [DetailTable]`（默认 `[]`）。后续所有任务构造详情时用 `detail.tables = [...]`，断言用 `detail.tables.first` / `detail.tables.isEmpty`。

- [ ] **Step 1: 先把测试改成数组口径（会编译失败）**

`Tests/TokenHealthTests/DetailPopoverRenderTests.swift` 里 `fullDetail` 的 `table:` 参数改成 `tables: [...]`：

```swift
            table: DetailTable(
                title: "By model · this month",
                columns: ["Model", "Requests", "Tokens", "Cost"],
                rows: [
                    DetailTableRow(name: "deepseek-chat", cells: ["980", "14.2M", "31.20 CNY"]),
                    DetailTableRow(name: "deepseek-reasoner", cells: ["224", "4.0M", "10.60 CNY"])
                ],
                footnote: "+2 more models"
            )
```

改成：

```swift
            tables: [
                DetailTable(
                    title: "By model · this month",
                    columns: ["Model", "Requests", "Tokens", "Cost"],
                    rows: [
                        DetailTableRow(name: "deepseek-chat", cells: ["980", "14.2M", "31.20 CNY"]),
                        DetailTableRow(name: "deepseek-reasoner", cells: ["224", "4.0M", "10.60 CNY"])
                    ],
                    footnote: "+2 more models"
                )
            ]
```

同一文件末尾加一个新用例（`rendersTheLoadingState` 之前任意位置）：

```swift
    /// 两张表都要画出来，顺序就是数组顺序；第二张在下面，浮层更高。
    @Test
    func rendersBothTablesInOrder() throws {
        let model = DetailTable(
            title: "By model · this month",
            columns: ["Model", "Tokens"],
            rows: [DetailTableRow(name: "deepseek-chat", cells: ["14.2M"])],
            footnote: nil
        )
        let key = DetailTable(
            title: "By API key · this month",
            columns: ["API key", "Tokens"],
            rows: [
                DetailTableRow(name: "prod", cells: ["9.0M"]),
                DetailTableRow(name: "staging", cells: ["5.2M"])
            ],
            footnote: "+3 more API keys"
        )

        let one = try render(UsageDetail(tables: [model]))
        let both = try render(UsageDetail(tables: [model, key]))

        #expect(both.height > one.height)
    }
```

其余七处测试文件里所有 `.table` 引用机械改口径：

- `try #require(detail.table)` → `try #require(detail.tables.first)`
- `detail.table == nil` → `detail.tables.isEmpty`
- `detail.table?.rows` → `detail.tables.first?.rows`
- `snapshot.detail?.table` → `snapshot.detail?.tables.first`

涉及的行：`DeepSeekUsageDetailTests.swift:197,215,232,246,264,297`、
`CodexUsageDetailTests.swift:51,378,399,413,431,454,455`、`CursorUsageDetailTests.swift:81,147,253,254,364,387,405,445,500`、
`OpenCodeGoUsageDetailTests.swift:119,139,156,168,197`、`DeepSeekDetailWiringTests.swift:89`、
`CodexUsageProviderTests.swift:598`、`CursorUsageProviderTests.swift:272,301`、`OpenCodeGoDetailWiringTests.swift:114`。
（`ExchangeRateStoreTests.swift` 里的 `store.table` 是汇率表，与本任务无关，不要碰。）

- [ ] **Step 2: 跑测试，确认是编译失败**

Run: `bash scripts/test.sh`
Expected: 编译错误，形如 `value of type 'UsageDetail' has no member 'tables'`

- [ ] **Step 3: 改 `UsageDetail`**

`Sources/TokenHealth/UsageDetail.swift` 里字段与 `isEmpty`：

```swift
    var headline: [DetailStat] = []
    var groups: [DetailGroup] = []
    var series: DetailSeries? = nil
    var breakdown: [DetailStat] = []
    var table: DetailTable? = nil

    /// 一个区块都没有时，浮层没必要画数据区。
    var isEmpty: Bool {
        headline.isEmpty && groups.isEmpty && breakdown.isEmpty && table == nil
    }
```

改成：

```swift
    var headline: [DetailStat] = []
    var groups: [DetailGroup] = []
    var series: DetailSeries? = nil
    var breakdown: [DetailStat] = []
    /// 可以有多个表格区块，渲染顺序就是数组顺序（DeepSeek 是 By model 在前、By API key 在后）。
    var tables: [DetailTable] = []

    /// 一个区块都没有时，浮层没必要画数据区。
    var isEmpty: Bool {
        headline.isEmpty && groups.isEmpty && breakdown.isEmpty && tables.isEmpty
    }
```

- [ ] **Step 4: 改 `DetailPopoverView` 的表格渲染**

`Sources/TokenHealth/DetailPopoverView.swift:154-190` 那一整段 `if let table = detail.table { … }` 替换成：

```swift
        ForEach(detail.tables) { table in
            tableSection(table)
        }
```

并在 `sections(_:)` 方法之后、`quotaBar(_:)` 之前加：

```swift
    /// 一张表格区块。抽出来是因为浮层现在可以有多张（DeepSeek 的 By model 与 By API key）。
    @ViewBuilder
    private func tableSection(_ table: DetailTable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(table.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // 用 Grid 而不是手拼 HStack：同一列在所有行里会按最宽的那个单元格对齐。
            // 用固定的 minWidth 各撑各的，表头与数值就会错开。
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text(table.columns.first ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(table.columns.dropFirst().enumerated()), id: \.offset) { _, column in
                        Text(column)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(table.rows) { row in
                    GridRow {
                        Text(row.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let footnote = table.footnote {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
```

`DetailTable` 需要能当 `ForEach` 的 id 来源。它是 `Equatable, Sendable`，没有 `Identifiable`。`ForEach(detail.tables)` 要求元素是 `Identifiable`。在 `DetailTable` 上加：

```swift
struct DetailTable: Equatable, Sendable, Identifiable {
    var title: String
    var columns: [String]
    var rows: [DetailTableRow]
    var footnote: String?

    /// 一张表在一个浮层里不会重名（`By model` / `By API key`），标题足以当身份。
    var id: String { title }
}
```

- [ ] **Step 5: 改四个 provider 的构造点**

- `CodexUsageDetail.swift:32`：`detail.table = resetCardTable(resetCredits)` → `detail.tables = [resetCardTable(resetCredits)].compactMap { $0 }`
- `CursorUsageDetail.swift:103`：`detail.table = table(window: window, byDay: byDay)` → `detail.tables = [table(window: window, byDay: byDay)].compactMap { $0 }`
- `OpenCodeGoUsageDetail.swift:54`：`detail.table = table(items)` → `detail.tables = [table(items)].compactMap { $0 }`
- `DeepSeekUsageDetail.swift:57`：`detail.table = table(byModel)` → `detail.tables = [table(byModel)].compactMap { $0 }`

（`[Optional].compactMap { $0 }` 是为了让「没有表」仍然得到空数组，而不是 `[nil]`。）

- [ ] **Step 6: 跑测试，确认全绿**

Run: `bash scripts/test.sh`
Expected: `Test run with N tests passed`

- [ ] **Step 7: Commit**

```bash
git add Sources/TokenHealth/UsageDetail.swift Sources/TokenHealth/DetailPopoverView.swift \
  Sources/TokenHealth/CodexUsageDetail.swift Sources/TokenHealth/CursorUsageDetail.swift \
  Sources/TokenHealth/OpenCodeGoUsageDetail.swift Sources/TokenHealth/DeepSeekUsageDetail.swift \
  Tests/TokenHealthTests/
git commit -m "Let the detail popover carry more than one table"
```

---

### Task 2: `UsageDetailSupport.monthToDateWindow`

**Files:**
- Modify: `Sources/TokenHealth/UsageDetailSupport.swift`（在 `monthToDateDayList` 之后加）
- Test: `Tests/TokenHealthTests/UsageDetailSupportTests.swift`（新建）

**Interfaces:**
- Consumes: 无
- Produces: `UsageDetailSupport.monthToDateWindow(now: Date, calendar: Calendar) -> (start: Int, end: Int)?` —— 本月 1 日 00:00 起、明日 00:00 止的 unix 秒。Task 3 与 Task 6 都调它。

- [ ] **Step 1: 写失败的测试**

新建 `Tests/TokenHealthTests/UsageDetailSupportTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct UsageDetailSupportTests {
    private let calendar = UsageDetailSupport.utcCalendar()

    private func instant(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: text))
    }

    private func date(_ text: String) throws -> Date {
        try #require(UsageDetailSupport.dateFormatter(calendar: calendar).date(from: text))
    }

    @Test
    func windowStartsOnTheFirstOfTheMonthAndEndsTomorrow() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-09-24T13:45:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-09-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2026-09-25").timeIntervalSince1970), "上界排他，覆盖到今天整天")
    }

    @Test
    func windowOnTheFirstSpansOneDay() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-09-01T00:00:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-09-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2026-09-02").timeIntervalSince1970))
    }

    @Test
    func windowCrossesTheYearBoundary() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-12-31T23:59:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-12-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2027-01-01").timeIntervalSince1970))
    }

    @Test
    func windowAtAMonthEndRollsIntoTheNextMonth() throws {
        let window = try #require(
            UsageDetailSupport.monthToDateWindow(now: try instant("2026-01-31T12:00:00Z"), calendar: calendar)
        )

        #expect(window.start == Int(try date("2026-01-01").timeIntervalSince1970))
        #expect(window.end == Int(try date("2026-02-01").timeIntervalSince1970))
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `bash scripts/test.sh --filter UsageDetailSupportTests`
Expected: 编译错误 `type 'UsageDetailSupport' has no member 'monthToDateWindow'`

- [ ] **Step 3: 实现**

在 `Sources/TokenHealth/UsageDetailSupport.swift` 的 `monthToDateDayList` 之后加：

```swift
    /// `[本月 1 日 00:00, 明日 00:00)` 的 unix 秒窗口，上界排他（覆盖到今天整天）。
    ///
    /// 给 by_api_key 那两个只认 `start`/`end`/`tz` 的端点用。`end` 取明日而不是今天，
    /// 是因为接口把 `end` 当排他上界 —— 传今天零点会把今天一整天切掉。
    /// 算不出日期时返回 nil，调用方据此放弃这次可选请求。
    static func monthToDateWindow(now: Date, calendar: Calendar) -> (start: Int, end: Int)? {
        let today = calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.year, .month], from: today)
        guard let first = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return nil
        }
        return (start: Int(first.timeIntervalSince1970), end: Int(tomorrow.timeIntervalSince1970))
    }
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `bash scripts/test.sh --filter UsageDetailSupportTests`
Expected: 4 个用例全过

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenHealth/UsageDetailSupport.swift Tests/TokenHealthTests/UsageDetailSupportTests.swift
git commit -m "Add the month-to-date window the by-key endpoint needs"
```

---

### Task 3: `WebSessionFetchContext` 补 `start` / `end`

**Files:**
- Modify: `Sources/TokenHealth/WebSessionDescriptor.swift:3-6`、`:142-154`
- Modify: `Sources/TokenHealth/DeepSeekUsageProvider.swift:43`
- Test: `Tests/TokenHealthTests/WebSessionDescriptorTests.swift:79-92`
- Test: `Tests/TokenHealthTests/OpenCodeGoWebSessionScriptTests.swift:90`
- Test: `Tests/TokenHealthTests/OpenCodeGoWebSessionDescriptorTests.swift:71`

**Interfaces:**
- Consumes: `UsageDetailSupport.monthToDateWindow(now:calendar:)`（Task 2）
- Produces: `WebSessionFetchContext(year:month:start:end:)` —— `start` / `end` 是 unix 秒。Task 7 的脚本读它们。

- [ ] **Step 1: 写失败的测试**

`Tests/TokenHealthTests/WebSessionDescriptorTests.swift` 里已有的 `buildsTheCurrentUTCMonth` 扩成也断言窗口（保留原有两条断言，追加）：

```swift
    @Test
    func buildsTheCurrentUTCMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date()
        let context = WebSessionFetchContext.currentUTC(now: now)

        #expect(context.year == calendar.component(.year, from: now))
        #expect(context.month == calendar.component(.month, from: now))

        let window = UsageDetailSupport.monthToDateWindow(now: now, calendar: calendar)
        #expect(context.start == window?.start)
        #expect(context.end == window?.end)
    }
```

同一个文件里的 `usageScriptMentionsRequestedMonth` 补上两个新参数：

```swift
    @Test
    func usageScriptMentionsRequestedMonth() {
        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9, start: 0, end: 0))
        #expect(script.contains("month=9&year=2026"))
    }
```

另外两处测试构造同样补 `start: 0, end: 0`：`OpenCodeGoWebSessionScriptTests.swift:90`、`OpenCodeGoWebSessionDescriptorTests.swift:71`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `bash scripts/test.sh --filter WebSessionDescriptorTests`
Expected: 编译错误 `extra arguments at positions #3, #4 in call`

- [ ] **Step 3: 实现**

`Sources/TokenHealth/WebSessionDescriptor.swift:3-6`：

```swift
struct WebSessionFetchContext {
    let year: Int
    let month: Int
    /// by_api_key 那类需要显式窗口的脚本用，unix 秒。其余 provider 的脚本不读它们。
    let start: Int
    let end: Int
}
```

同文件 `currentUTC`（`:142-154`）：

```swift
extension WebSessionFetchContext {
    /// The current year and month in UTC. Providers whose scripts take no period still have to pass
    /// something to `fetchUsage(context:)`; this keeps the value meaningful if a script ever starts
    /// interpolating one.
    ///
    /// `start` / `end` 顺带算出本月窗口：只有 DeepSeek 的脚本读它们，其余 provider 拿到的是一个
    /// 语义自洽的值而不是占位的 0。算不出时留 0 —— 那条调用方本来就是可选请求，失败了不影响刷新。
    static func currentUTC(now: Date = Date()) -> WebSessionFetchContext {
        let calendar = UsageDetailSupport.utcCalendar()
        let window = UsageDetailSupport.monthToDateWindow(now: now, calendar: calendar)
        return WebSessionFetchContext(
            year: calendar.component(.year, from: now),
            month: calendar.component(.month, from: now),
            start: window?.start ?? 0,
            end: window?.end ?? 0
        )
    }
}
```

`Sources/TokenHealth/DeepSeekUsageProvider.swift`：`fetchPlatformUsage` 顶上取**一次** `now`，
`period` 与 context 都由它算 —— 两处各自 `Date()` 会在 UTC 午夜前后落到不同的日子。

```swift
        let now = Date()
        let period = DeepSeekUsagePeriod.currentUTC(now: now)
```

`:43` 那一处构造改成：

```swift
                bundleData = try await controller.fetchUsage(
                    context: WebSessionFetchContext(
                        year: period.year,
                        month: period.month,
                        start: Self.window(now: now)?.start ?? 0,
                        end: Self.window(now: now)?.end ?? 0
                    )
                )
```

并给 `DeepSeekUsageProvider` 加一个私有静态 helper（放在 `fetchPlatformData` 附近）：

```swift
    /// 本月至今日的 unix 秒窗口。算不出时返回 nil，两个可选请求就跳过。
    private static func window(now: Date) -> (start: Int, end: Int)? {
        UsageDetailSupport.monthToDateWindow(now: now, calendar: UsageDetailSupport.utcCalendar())
    }
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `bash scripts/test.sh`
Expected: 全绿

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenHealth/WebSessionDescriptor.swift Sources/TokenHealth/DeepSeekUsageProvider.swift Tests/TokenHealthTests/
git commit -m "Carry the usage window on the web-session fetch context"
```

---

### Task 4: `DeepSeekPayload` 增补 by_api_key 的形状走查

**Files:**
- Modify: `Sources/TokenHealth/DeepSeekPayload.swift`
- Test: `Tests/TokenHealthTests/DeepSeekPayloadTests.swift`

**Interfaces:**
- Consumes: 无
- Produces（Task 5 逐个使用）：
  - `DeepSeekPayload.APIKeyIdentity` —— `name: String?`、`trackingID: String?`、`keyID: String`、`displayName: String`
  - `DeepSeekPayload.APIKeyAmountSeries` —— `apiKey: APIKeyIdentity?`、`model: String?`、`buckets: [[String: Any]]`
  - `DeepSeekPayload.APIKeyCostSeries` —— 同上形状
  - `DeepSeekPayload.APIKeyCostCurrency` —— `currency: String`、`series: [APIKeyCostSeries]`
  - `static func apiKeyAmountSeries(fromAmount: [String: Any]) -> [APIKeyAmountSeries]`
  - `static func apiKeyCostCurrencies(fromCost: [String: Any]) -> [APIKeyCostCurrency]`
  - `static func apiKeyIdentity(from: Any?) -> APIKeyIdentity?`
  - `static func intAmount(inUsageDict: [String: Any]?, type: String) -> Int`
  - `static func costAmount(inBucket: [String: Any]) -> Decimal`
  - `static func time(inBucket: [String: Any]) -> Int?`

- [ ] **Step 1: 写失败的测试**

在 `Tests/TokenHealthTests/DeepSeekPayloadTests.swift` 的 `struct` 里追加：

```swift
    @Test
    func walksTheByKeyAmountEnvelopeDownToItsBuckets() {
        let root: [String: Any] = [
            "code": 0,
            "data": ["biz_data": ["series": [[
                "api_key": ["name": "prod", "tracking_id": "sk-abc"],
                "model": "deepseek-chat",
                "buckets": [["time": 1_759_276_800, "usage": ["REQUEST": "128"]]]
            ]]]]
        ]

        let series = DeepSeekPayload.apiKeyAmountSeries(fromAmount: root)
        #expect(series.count == 1)
        #expect(series[0].apiKey?.keyID == "sk-abc")
        #expect(series[0].apiKey?.displayName == "prod")
        #expect(series[0].model == "deepseek-chat")
        #expect(series[0].buckets.count == 1)
    }

    /// cost 侧的 api_key 是裸字符串 —— 与 amount 侧的对象形态必须落到同一个身份上。
    @Test
    func aBareStringAPIKeyIdentifiesItself() {
        let root: [String: Any] = [
            "data": ["biz_data": ["data": [[
                "currency": "CNY",
                "series": [[
                    "api_key": "sk-abc",
                    "model": "deepseek-chat",
                    "buckets": [["time": 1_759_276_800, "cost": "1.2843"]]
                ]]
            ]]]]
        ]

        let currencies = DeepSeekPayload.apiKeyCostCurrencies(fromCost: root)
        #expect(currencies.map(\.currency) == ["CNY"])
        #expect(currencies[0].series[0].apiKey?.keyID == "sk-abc", "裸字符串用自己当 tracking id")
        #expect(currencies[0].series[0].apiKey?.displayName == "sk-abc")
    }

    @Test
    func identityFallsBackInOrderOfConfidence() {
        #expect(DeepSeekPayload.apiKeyIdentity(from: ["name": "prod"])?.keyID == "prod")
        #expect(DeepSeekPayload.apiKeyIdentity(from: ["tracking_id": "sk-x"])?.displayName == "sk-x")
        #expect(DeepSeekPayload.apiKeyIdentity(from: [:]) == nil)
        #expect(DeepSeekPayload.apiKeyIdentity(from: NSNull()) == nil)
        #expect(DeepSeekPayload.apiKeyIdentity(from: 42) == nil)
        #expect(DeepSeekPayload.apiKeyIdentity(from: "  ") == nil)
    }

    @Test
    func readsUsageFromTheBucketDictionary() {
        let usage: [String: Any] = [
            "REQUEST": "128",
            "RESPONSE_TOKEN": 40_211,
            "PROMPT_CACHE_HIT_TOKEN": NSNull(),
            "PROMPT_CACHE_MISS_TOKEN": "-7"
        ]

        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "REQUEST") == 128)
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "RESPONSE_TOKEN") == 40_211)
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "PROMPT_CACHE_HIT_TOKEN") == 0, "null 当 0")
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "PROMPT_CACHE_MISS_TOKEN") == 0, "负数夹到 0")
        #expect(DeepSeekPayload.intAmount(inUsageDict: usage, type: "ABSENT") == 0)
        #expect(DeepSeekPayload.intAmount(inUsageDict: nil, type: "REQUEST") == 0)
    }

    @Test
    func readsBucketTimeAndCost() {
        #expect(DeepSeekPayload.time(inBucket: ["time": 1_759_276_800]) == 1_759_276_800)
        #expect(DeepSeekPayload.time(inBucket: ["time": "1759276800"]) == 1_759_276_800)
        #expect(DeepSeekPayload.time(inBucket: [:]) == nil)
        #expect(DeepSeekPayload.costAmount(inBucket: ["cost": "1.2843"]) == Decimal(string: "1.2843"))
        #expect(DeepSeekPayload.costAmount(inBucket: ["cost": NSNull()]) == 0)
        #expect(DeepSeekPayload.costAmount(inBucket: ["cost": "-5"]) == 0)
    }

    @Test
    func missingShapesYieldEmptyRatherThanCrashing() {
        #expect(DeepSeekPayload.apiKeyAmountSeries(fromAmount: [:]).isEmpty)
        #expect(DeepSeekPayload.apiKeyAmountSeries(fromAmount: ["data": ["biz_data": [:]]]).isEmpty)
        #expect(DeepSeekPayload.apiKeyCostCurrencies(fromCost: [:]).isEmpty)
        #expect(DeepSeekPayload.apiKeyCostCurrencies(fromCost: ["data": ["biz_data": ["data": []]]]).isEmpty)
    }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `bash scripts/test.sh --filter DeepSeekPayloadTests`
Expected: 编译错误 `type 'DeepSeekPayload' has no member 'apiKeyAmountSeries'`

- [ ] **Step 3: 实现**

在 `Sources/TokenHealth/DeepSeekPayload.swift` 的 `enum` 内、"MARK: - 共用" 之前插入：

```swift
    // MARK: - by_api_key 侧

    /// 一把 API key 的身份。`name` 是用户给 key 起的名字，`trackingID` 是密钥前缀。
    ///
    /// 两个 id 的分工是硬约束：**聚合用 `keyID`，展示用 `displayName`**。
    /// amount 侧给的是对象、cost 侧给的是裸字符串，两边必须推出同一个 `keyID`，
    /// 否则同一把 key 会在表里裂成两行。
    struct APIKeyIdentity: Equatable {
        var name: String?
        var trackingID: String?

        var keyID: String {
            if let trackingID, !trackingID.isEmpty {
                return trackingID
            }
            if let name, !name.isEmpty {
                return name
            }
            return "unknown"
        }

        var displayName: String {
            if let name, !name.isEmpty {
                return name
            }
            if let trackingID, !trackingID.isEmpty {
                return trackingID
            }
            return "Unknown key"
        }
    }

    struct APIKeyAmountSeries {
        var apiKey: APIKeyIdentity?
        var model: String?
        var buckets: [[String: Any]]
    }

    struct APIKeyCostSeries {
        var apiKey: APIKeyIdentity?
        var model: String?
        var buckets: [[String: Any]]
    }

    struct APIKeyCostCurrency {
        var currency: String
        var series: [APIKeyCostSeries]
    }

    /// 走到 `data.biz_data.series`。
    static func apiKeyAmountSeries(fromAmount root: [String: Any]) -> [APIKeyAmountSeries] {
        guard let bizData = bizData(from: root),
              let series = bizData["series"] as? [[String: Any]] else {
            return []
        }
        return series.map { item in
            APIKeyAmountSeries(
                apiKey: apiKeyIdentity(from: item["api_key"]),
                model: stringValue(item["model"]),
                buckets: item["buckets"] as? [[String: Any]] ?? []
            )
        }
    }

    /// 走到 `data.biz_data.data`（币种层，里层才是 `series`）。
    static func apiKeyCostCurrencies(fromCost root: [String: Any]) -> [APIKeyCostCurrency] {
        guard let bizData = bizData(from: root),
              let currencies = bizData["data"] as? [[String: Any]] else {
            return []
        }
        return currencies.map { item in
            APIKeyCostCurrency(
                currency: stringValue(item["currency"]) ?? "CNY",
                series: (item["series"] as? [[String: Any]] ?? []).map { entry in
                    APIKeyCostSeries(
                        apiKey: apiKeyIdentity(from: entry["api_key"]),
                        model: stringValue(entry["model"]),
                        buckets: entry["buckets"] as? [[String: Any]] ?? []
                    )
                }
            )
        }
    }

    /// `api_key` 的两种形态：对象 `{name, tracking_id}`，或裸字符串（cost 侧就是这样）。
    static func apiKeyIdentity(from value: Any?) -> APIKeyIdentity? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : APIKeyIdentity(name: nil, trackingID: trimmed)
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        let identity = APIKeyIdentity(
            name: stringValue(object["name"]),
            trackingID: stringValue(object["tracking_id"])
        )
        return (identity.name == nil && identity.trackingID == nil) ? nil : identity
    }

    /// bucket 的 `usage` 是**字典**形态 `{TYPE: 值}`，与数组形态的 `intAmount(in:type:)` 各走一条。
    static func intAmount(inUsageDict usage: [String: Any]?, type: String) -> Int {
        guard let amount = decimalValue(usage?[type]) else {
            return 0
        }
        return max(0, NSDecimalNumber(decimal: amount).intValue)
    }

    /// cost bucket 的金额。负数（坏数据）夹到 0。
    static func costAmount(inBucket bucket: [String: Any]) -> Decimal {
        max(0, decimalValue(bucket["cost"]) ?? Decimal(0))
    }

    /// bucket 的时间戳（unix 秒）。缺或解不出返回 nil —— 调用方据此丢弃这个 bucket，
    /// 而不是当成 0（1970 年那天）收进来。
    static func time(inBucket bucket: [String: Any]) -> Int? {
        guard let amount = decimalValue(bucket["time"]) else {
            return nil
        }
        return NSDecimalNumber(decimal: amount).intValue
    }
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `bash scripts/test.sh --filter DeepSeekPayloadTests`
Expected: 全过

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenHealth/DeepSeekPayload.swift Tests/TokenHealthTests/DeepSeekPayloadTests.swift
git commit -m "Read the by-api-key usage envelope"
```

---

### Task 5: `DeepSeekUsageDetail` 的 byKey 聚合与 key 表

**Files:**
- Modify: `Sources/TokenHealth/DeepSeekUsageDetail.swift`
- Test: `Tests/TokenHealthTests/DeepSeekUsageDetailTests.swift`

**Interfaces:**
- Consumes: `UsageDetail.tables`（Task 1）、`DeepSeekPayload.apiKey*`（Task 4）
- Produces: `DeepSeekUsageDetail.make(bundle:balances:today:)` 在 bundle 带 `byKeyAmount` / `byKeyCost` 时产出第二张表。签名不变。

- [ ] **Step 1: 写失败的测试**

`Tests/TokenHealthTests/DeepSeekUsageDetailTests.swift` 里，先扩 bundle helper 让它能带两个新键（保留现有签名不变，另加一个）：

```swift
    /// 带 by_api_key 两份响应的 bundle。两个参数传 nil 时写成 JSON null，与真实响应失败时的形状一致。
    private func keyBundle(
        byKeyAmount: String?,
        byKeyCost: String?,
        amountDays: String = "[]"
    ) -> Data {
        let keyAmountJSON = byKeyAmount ?? "null"
        let keyCostJSON = byKeyCost ?? "null"
        let json = """
        {"summary":{},"amount":{"data":{"biz_data":{"days":\(amountDays)}}},
         "byKeyAmount":\(keyAmountJSON),"byKeyCost":\(keyCostJSON)}
        """
        return Data(json.utf8)
    }

    private let calendar = UsageDetailSupport.utcCalendar()

    /// bucket 的 `time` 是 UTC 日零点的 unix 秒。**别在测试里硬编码时间戳** ——
    /// 年份写错会让 bucket 落到月外，用例就悄悄变成在测「越界丢弃」了。
    private func midnight(_ day: String) -> Int {
        let date = UsageDetailSupport.dateFormatter(calendar: calendar).date(from: day)
        return Int((date ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)
    }

    /// amount 侧的一条 series：一把 key、一个模型、若干 bucket。
    private func keySeries(
        _ name: String,
        tracking: String,
        model: String,
        buckets: [(time: Int, requests: Int, output: Int, hit: Int, miss: Int)]
    ) -> String {
        let entries = buckets.map { bucket in
            """
            {"time":\(bucket.time),"usage":{"REQUEST":"\(bucket.requests)","RESPONSE_TOKEN":"\(bucket.output)",
             "PROMPT_CACHE_HIT_TOKEN":"\(bucket.hit)","PROMPT_CACHE_MISS_TOKEN":"\(bucket.miss)"}}
            """
        }
        return """
        {"api_key":{"name":"\(name)","tracking_id":"\(tracking)"},"model":"\(model)","buckets":[\(entries.joined(separator: ","))]}
        """
    }
```

再加用例：

```swift
    @Test
    func buildsAnAPIKeyTableBelowTheModelTable() throws {
        let amount = """
        {"data":{"biz_data":{"series":[
          \(keySeries("prod", tracking: "sk-prod", model: "deepseek-chat",
                      buckets: [(midnight("2026-09-10"), 5, 5_000, 0, 0)])),
          \(keySeries("staging", tracking: "sk-stage", model: "deepseek-chat",
                      buckets: [(midnight("2026-09-10"), 1, 100, 0, 0)]))
        ]}}}
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: amount, byKeyCost: nil,
                                  amountDays: "[\(day("2026-09-10", model: "deepseek-chat", requests: 6, output: 5_100, hit: 0, miss: 0))]"),
                balances: [],
                today: period
            )
        )

        #expect(detail.tables.count == 2)
        #expect(detail.tables.map(\.title) == ["By model · this month", "By API key · this month"])
        let key = try #require(detail.tables.last)
        #expect(key.columns == ["API key", "Requests", "Tokens", "Cost"])
        #expect(key.rows.map(\.name) == ["prod", "staging"], "tokens 降序")
        #expect(key.rows[0].cells == ["5", "5K", "—"])
    }

    /// 同一把 key 跨多个模型要合成一行。
    @Test
    func mergesOneKeyAcrossModels() throws {
        let amount = """
        {"data":{"biz_data":{"series":[
          \(keySeries("prod", tracking: "sk-prod", model: "deepseek-chat",
                      buckets: [(midnight("2026-09-10"), 2, 200, 0, 0)])),
          \(keySeries("prod", tracking: "sk-prod", model: "deepseek-reasoner",
                      buckets: [(midnight("2026-09-10"), 3, 300, 0, 0)]))
        ]}}}
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: amount, byKeyCost: nil),
                balances: [],
                today: period
            )
        )

        let key = try #require(detail.tables.first { $0.title == "By API key · this month" })
        #expect(key.rows.count == 1)
        #expect(key.rows[0].cells == ["5", "500", "—"])
    }

    /// amount 侧是对象、cost 侧是裸字符串 —— 两侧必须落到同一行。
    @Test
    func matchesTheObjectFormOnTheAmountSideWithTheBareStringOnTheCostSide() throws {
        let amount = """
        {"data":{"biz_data":{"series":[
          \(keySeries("prod", tracking: "sk-prod", model: "deepseek-chat",
                      buckets: [(midnight("2026-09-10"), 2, 200, 0, 0)]))
        ]}}}
        """
        let seconds = midnight("2026-09-10")
        let cost = """
        {"data":{"biz_data":{"data":[{"currency":"CNY","series":[
          {"api_key":"sk-prod","model":"deepseek-chat","buckets":[{"time":\(seconds),"cost":"0.20"}]}
        ]}]}}}
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: amount, byKeyCost: cost),
                balances: [],
                today: period
            )
        )

        let key = try #require(detail.tables.first { $0.title == "By API key · this month" })
        #expect(key.rows.count == 1, "两侧的身份推断必须一致，否则会裂成两行")
        #expect(key.rows[0].cells == ["2", "200", "0.20 CNY"])
    }

    @Test
    func renamesAPIKeysThatShareADisplayName() throws {
        let amount = """
        {"data":{"biz_data":{"series":[
          \(keySeries("prod", tracking: "sk-aaaa1111", model: "m", buckets: [(midnight("2026-09-10"), 1, 500, 0, 0)])),
          \(keySeries("prod", tracking: "sk-bbbb2222", model: "m", buckets: [(midnight("2026-09-10"), 1, 300, 0, 0)]))
        ]}}}
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: amount, byKeyCost: nil),
                balances: [],
                today: period
            )
        )

        let key = try #require(detail.tables.first { $0.title == "By API key · this month" })
        #expect(key.rows.map(\.name) == ["prod · sk-aaaa1", "prod · sk-bbbb2"])
        #expect(Set(key.rows.map(\.name)).count == 2, "同表内名字必须唯一：DetailTableRow.id 取的是 name")
    }

    @Test
    func mergesKeysWithoutAnyIdentityIntoOneRow() throws {
        let seconds = midnight("2026-09-10")
        let amount = """
        {"data":{"biz_data":{"series":[
          {"model":"m","buckets":[{"time":\(seconds),"usage":{"RESPONSE_TOKEN":"100"}}]},
          {"api_key":null,"model":"m","buckets":[{"time":\(seconds),"usage":{"RESPONSE_TOKEN":"50"}}]}
        ]}}}
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: amount, byKeyCost: nil),
                balances: [],
                today: period
            )
        )

        let key = try #require(detail.tables.first { $0.title == "By API key · this month" })
        #expect(key.rows.map(\.name) == ["Unknown key"])
        #expect(key.rows[0].cells == ["0", "150", "—"])
    }

    @Test
    func dropsBucketsOutsideTheMonth() throws {
        // 8/31 与 9/25 都在窗口外（窗口是 9/1–9/24）。
        let amount = """
        {"data":{"biz_data":{"series":[
          \(keySeries("prod", tracking: "sk-prod", model: "m",
                      buckets: [(midnight("2026-08-31"), 1, 900, 0, 0), (midnight("2026-09-25"), 1, 900, 0, 0),
                                (midnight("2026-09-10"), 1, 100, 0, 0)]))
        ]}}}
        """
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: amount, byKeyCost: nil),
                balances: [],
                today: period
            )
        )

        let key = try #require(detail.tables.first { $0.title == "By API key · this month" })
        #expect(key.rows[0].cells[1] == "100", "只有月内的那个 bucket 算数")
    }

    @Test
    func truncatesTheKeyTableWithItsOwnFootnote() throws {
        let series = (1...8).map { index in
            keySeries("key-\(index)", tracking: "sk-\(index)", model: "m",
                      buckets: [(midnight("2026-09-10"), 1, index * 100, 0, 0)])
        }
        let amount = "{\"data\":{\"biz_data\":{\"series\":[\(series.joined(separator: ","))]}}}"
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: amount, byKeyCost: nil),
                balances: [],
                today: period
            )
        )

        let key = try #require(detail.tables.first { $0.title == "By API key · this month" })
        #expect(key.rows.count == 6)
        #expect(key.footnote == "+2 more API keys")
        #expect(key.rows.first?.name == "key-8")
    }

    /// `by_api_key` 缺席时只画模型表。这里必须给 amount 一天真实数据，
    /// 否则模型表也是空的，`tables` 会整个是 `[]`，用例就测不出「少了一张」。
    @Test
    func omitsTheKeyTableWhenTheEndpointFailed() throws {
        let detail = try #require(
            DeepSeekUsageDetail.make(
                bundle: keyBundle(byKeyAmount: nil, byKeyCost: nil,
                                  amountDays: "[\(day("2026-09-10", model: "m", requests: 1, output: 10, hit: 0, miss: 0))]"),
                balances: [],
                today: period
            )
        )

        #expect(detail.tables.map(\.title) == ["By model · this month"])
    }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `bash scripts/test.sh --filter DeepSeekUsageDetailTests`
Expected: FAIL —— `detail.tables` 只有一张（`buildsAnAPIKeyTableBelowTheModelTable` 期待 2 张）

- [ ] **Step 3: 实现**

`Sources/TokenHealth/DeepSeekUsageDetail.swift` 里：

**3a.** `make` 里把 byKey 聚合接上（在 `merge(dayCosts, into: &byDay)` 之后）：

```swift
        var detail = UsageDetail()
        detail.headline = headline(from: balances)
        detail.groups = groups(today: today, daysInRange: daysInRange, byDay: byDay, calendar: calendar)
        detail.series = series(today: today, daysInRange: daysInRange, byDay: byDay, calendar: calendar)
        detail.breakdown = breakdown(byDay)
        // by_api_key 的两份响应挂在 bundle 自己的键上，不是 bundle 顶层 —— 取子对象再走形状走查。
        let byKey = keyTotals(
            fromAmount: root["byKeyAmount"] as? [String: Any] ?? [:],
            fromCost: root["byKeyCost"] as? [String: Any] ?? [:],
            allowed: Set(daysInRange),
            calendar: calendar
        )
        detail.tables = [table(byModel), keyTable(byKey)].compactMap { $0 }
        return detail
```

**3b.** 在 `// MARK: - table` 之后新增一节：

```swift
    // MARK: - key 表

    /// 一把 key 的合计与它的候选展示名。
    private typealias KeyTotals = (totals: Totals, candidateName: String)

    /// 按 key 聚合。
    ///
    /// amount 侧给 `api_key` 对象、cost 侧给裸字符串，两边的 `keyID` 必须一致 ——
    /// 所以聚合键一律取 `APIKeyIdentity.keyID`，展示名另存一份。
    private static func keyTotals(
        fromAmount root: [String: Any],
        fromCost costRoot: [String: Any],
        allowed: Set<Date>,
        calendar: Calendar
    ) -> [String: KeyTotals] {
        var byKey: [String: KeyTotals] = [:]

        for series in DeepSeekPayload.apiKeyAmountSeries(fromAmount: root) {
            let key = identity(series.apiKey)
            for bucket in series.buckets {
                guard let time = DeepSeekPayload.time(inBucket: bucket),
                      allowed.contains(calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(time)))) else {
                    continue
                }
                var model = Totals()
                let usage = bucket["usage"] as? [String: Any]
                model.requests = DeepSeekPayload.intAmount(inUsageDict: usage, type: "REQUEST")
                model.outputTokens = DeepSeekPayload.intAmount(inUsageDict: usage, type: "RESPONSE_TOKEN")
                model.cacheHitTokens = DeepSeekPayload.intAmount(inUsageDict: usage, type: "PROMPT_CACHE_HIT_TOKEN")
                model.cacheMissTokens = DeepSeekPayload.intAmount(inUsageDict: usage, type: "PROMPT_CACHE_MISS_TOKEN")

                var entry = byKey[key.id] ?? (Totals(), key.name)
                entry.totals.add(tokens: model)
                byKey[key.id] = entry
            }
        }

        for currency in DeepSeekPayload.apiKeyCostCurrencies(fromCost: costRoot) {
            for series in currency.series {
                let key = identity(series.apiKey)
                for bucket in series.buckets {
                    guard let time = DeepSeekPayload.time(inBucket: bucket),
                          allowed.contains(calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(time)))) else {
                        continue
                    }
                    var entry = byKey[key.id] ?? (Totals(), key.name)
                    entry.totals.costByCurrency[currency.currency, default: Decimal(0)] += DeepSeekPayload.costAmount(inBucket: bucket)
                    byKey[key.id] = entry
                }
            }
        }

        return byKey
    }

    /// 没有身份的行归到同一条 `Unknown key`。
    private static func identity(_ identity: DeepSeekPayload.APIKeyIdentity?) -> (id: String, name: String) {
        guard let identity else {
            return ("unknown", unknownKeyName)
        }
        return (identity.keyID, identity.displayName)
    }

    private static let unknownKeyName = "Unknown key"

    private static func keyTable(_ byKey: [String: KeyTotals]) -> DetailTable? {
        let rows = byKey
            .filter { $0.value.totals.hasAnything }
            .sorted { lhs, rhs in
                lhs.value.totals.tokens == rhs.value.totals.tokens
                    ? lhs.value.candidateName < rhs.value.candidateName
                    : lhs.value.totals.tokens > rhs.value.totals.tokens
            }
        guard !rows.isEmpty else {
            return nil
        }

        let names = disambiguatedNames(rows)
        let shown = rows.prefix(tableRowLimit)
        let hidden = rows.count - shown.count
        return DetailTable(
            title: "By API key · this month",
            columns: ["API key", "Requests", "Tokens", "Cost"],
            rows: zip(shown, names).map { row, name in
                DetailTableRow(
                    name: name,
                    cells: [
                        UsageAmountFormatter.compactAmount(row.value.totals.requests),
                        UsageAmountFormatter.compactAmount(row.value.totals.tokens),
                        costText(row.value.totals.costByCurrency)
                    ]
                )
            },
            footnote: hidden > 0 ? "+\(hidden) more API keys" : nil
        )
    }

    /// 展示名去重。
    ///
    /// `DetailTableRow.id` 取的是 `name`，同表内重名会让浮层的 `ForEach` 出错；而用户完全可能
    /// 给两把 key 起同一个名字。冲突的行改用「名字 · id 前 8 位」；id 与名字相同（裸字符串形态，
    /// 两种身份都来自同一个 tracking id）时退化成「名字 #序号」。
    /// 去重跑在**截断前**的全部行上，否则被截掉的那行一走，剩下的重名反而逃过了改名。
    private static func disambiguatedNames(_ rows: [(key: String, value: KeyTotals)]) -> [String] {
        var counts: [String: Int] = [:]
        for row in rows {
            counts[row.value.candidateName, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return rows.map { row in
            let name = row.value.candidateName
            guard counts[name, default: 0] > 1 else {
                return name
            }
            seen[name, default: 0] += 1
            guard row.key != name else {
                return "\(name) #\(seen[name] ?? 1)"
            }
            return "\(name) · \(row.key.prefix(8))"
        }
    }
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `bash scripts/test.sh --filter DeepSeekUsageDetailTests`
Expected: 全过

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenHealth/DeepSeekUsageDetail.swift Tests/TokenHealthTests/DeepSeekUsageDetailTests.swift
git commit -m "Build the DeepSeek by-API-key table"
```

---

### Task 6: native 取数发这两个请求

**Files:**
- Modify: `Sources/TokenHealth/DeepSeekUsageProvider.swift:19-56, 132-197`
- Test: `Tests/TokenHealthTests/DeepSeekDetailWiringTests.swift`

**Interfaces:**
- Consumes: `UsageDetailSupport.monthToDateWindow`（Task 2）、`DeepSeekUsageDetail`（Task 5）
- Produces: bundle 多两个键 `byKeyAmount` / `byKeyCost`（失败时为 JSON `null`）。

- [ ] **Step 1: 写失败的测试**

`Tests/TokenHealthTests/DeepSeekDetailWiringTests.swift` 加用例（`bundle` 那个私有属性保持不动，另造一份带 key 数据的）：

```swift
    /// bucket 的 `time` 是 UTC 日零点的 unix 秒。
    private func midnight(_ day: String) -> Int {
        let formatter = UsageDetailSupport.dateFormatter(calendar: UsageDetailSupport.utcCalendar())
        return Int((formatter.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)
    }

    /// 带 by_api_key 两份响应的 bundle：模型表与 key 表都该出来。
    /// 这是 raw string，插值要写 `\#(...)` 而不是 `\(...)`。
    private var bundleWithAPIKeys: Data {
        let seconds = midnight("2026-09-24")
        return Data(#"""
        {"summary":{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"1284.60"}]}}},
         "amount":{"data":{"biz_data":{"days":[{"date":"2026-09-24","data":[
           {"model":"deepseek-chat","usage":[
             {"type":"REQUEST","amount":"4"},
             {"type":"RESPONSE_TOKEN","amount":"40"},
             {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"80"},
             {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"20"}]}]}]}}},
         "cost":{},
         "byKeyAmount":{"data":{"biz_data":{"series":[
           {"api_key":{"name":"prod","tracking_id":"sk-prod"},"model":"deepseek-chat",
            "buckets":[{"time":\#(seconds),"usage":{
              "REQUEST":"4","RESPONSE_TOKEN":"40",
              "PROMPT_CACHE_HIT_TOKEN":"80","PROMPT_CACHE_MISS_TOKEN":"20"}}]}]}}},
         "byKeyCost":{"data":{"biz_data":{"data":[{"currency":"CNY","series":[
           {"api_key":"sk-prod","model":"deepseek-chat",
            "buckets":[{"time":\#(seconds),"cost":"0.02"}]}]}]}}}
        """#.utf8)
    }

    @Test
    func aBundleWithByKeyDataProducesTwoTables() throws {
        let snapshot = DeepSeekUsageProvider().platformSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundleWithAPIKeys,
            period: period,
            accountName: nil
        )

        let detail = try #require(snapshot.detail)
        #expect(detail.tables.map(\.title) == ["By model · this month", "By API key · this month"])
        let key = try #require(detail.tables.last)
        #expect(key.rows.map(\.name) == ["prod"])
        #expect(key.rows[0].cells == ["4", "140", "0.02 CNY"])
    }

    @Test
    func aBundleWithoutByKeyDataProducesOneTable() throws {
        let snapshot = DeepSeekUsageProvider().platformSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundle,
            period: period,
            accountName: nil
        )

        let detail = try #require(snapshot.detail)
        #expect(detail.tables.map(\.title) == ["By model · this month"])
    }

    @Test
    func aNullByKeyPayloadIsTolerated() throws {
        // 端点失败时 bundle 里就是 null，解析器和详情构建器都不该被它绊倒。
        let json = #"{"summary":{},"amount":{},"cost":{},"byKeyAmount":null,"byKeyCost":null}"#
        let snapshot = DeepSeekUsageProvider().platformSnapshot(
            config: config(auth: .browserLogin),
            bundle: Data(json.utf8),
            period: period,
            accountName: nil
        )

        #expect(snapshot.state == .ready)
        #expect(snapshot.detail?.tables.isEmpty == true)
    }
```

（`1758672000` 是 2026-09-24T00:00:00Z。）

- [ ] **Step 2: 跑测试**

Run: `bash scripts/test.sh --filter DeepSeekDetailWiringTests`
Expected: PASS。这里不是「先失败再通过」—— Task 5 已经让 `make` 读这两个键了，
所以这三条用例直接测的就是**bundle 键名与读取侧对得上**。
若 FAIL，先核对 Step 3c 里的键名拼写（`byKeyAmount` / `byKeyCost`）。

- [ ] **Step 3: 实现取数**

`Sources/TokenHealth/DeepSeekUsageProvider.swift`：

**3a.** `fetchUsageBundle` 的调用点加上 `now`。`let now = Date()` 与 web-session 回落那一支的
`context:` 都是 Task 3 已经改好的，这里只是把同一个 `now` 继续传下去：

```swift
                bundleData = try await fetchUsageBundle(session: session, period: period, now: now)
```

**3b.** `fetchUsageBundle` 扩成五个请求：

```swift
    private func fetchUsageBundle(
        session: DeepSeekWebSessionCredential,
        period: DeepSeekUsagePeriod,
        now: Date
    ) async throws -> Data {
        let window = Self.window(now: now)

        async let summary = fetchPlatformData(session: session, path: "/api/v0/users/get_user_summary", query: [:])
        async let amount = fetchPlatformData(
            session: session,
            path: "/api/v0/usage/amount",
            query: ["month": "\(period.month)", "year": "\(period.year)"]
        )
        async let cost = fetchPlatformData(
            session: session,
            path: "/api/v0/usage/cost",
            query: ["month": "\(period.month)", "year": "\(period.year)"]
        )
        // 这两条是可选：端点随时可能变，失败不该拖垮余额与汇总。
        async let byKeyAmount = fetchByKeyData(
            session: session,
            path: "/api/v0/usage/by_api_key/amount",
            window: window
        )
        async let byKeyCost = fetchByKeyData(
            session: session,
            path: "/api/v0/usage/by_api_key/cost",
            window: window
        )

        return try await bundle(
            summary: summary,
            amount: amount,
            cost: cost,
            byKeyAmount: byKeyAmount,
            byKeyCost: byKeyCost
        )
    }

    /// 本月至今日的 unix 秒窗口；算不出时返回 nil，两个可选请求就跳过。
    private static func window(now: Date) -> (start: Int, end: Int)? {
        UsageDetailSupport.monthToDateWindow(now: now, calendar: UsageDetailSupport.utcCalendar())
    }

    /// by_api_key 的取数：窗口缺失直接放弃，其余错误（非 2xx、超时、连接失败）一律吞掉。
    private func fetchByKeyData(
        session: DeepSeekWebSessionCredential,
        path: String,
        window: (start: Int, end: Int)?
    ) async -> Data? {
        guard let window else {
            return nil
        }
        return await fetchPlatformDataOptional(
            session: session,
            path: path,
            query: ["start": "\(window.start)", "end": "\(window.end)", "tz": "0"]
        )
    }

    private func fetchPlatformDataOptional(
        session: DeepSeekWebSessionCredential,
        path: String,
        query: [String: String]
    ) async -> Data? {
        do {
            return try await fetchPlatformData(session: session, path: path, query: query)
        } catch {
            WebSessionLog.debugLog(
                "optional request failed, path=\(path): \(error.localizedDescription)",
                providerTitle: Self.providerTitle
            )
            return nil
        }
    }
```

**3c.** `bundle` 扩成五项：

```swift
    private func bundle(
        summary: Data,
        amount: Data,
        cost: Data,
        byKeyAmount: Data?,
        byKeyCost: Data?
    ) throws -> Data {
        var object: [String: Any] = [
            "summary": try jsonObject(from: summary),
            "amount": try jsonObject(from: amount),
            "cost": try jsonObject(from: cost)
        ]
        // 解不出的可选响应按 null 处理，与「请求失败」同一条路 —— 不该让一张可选表
        // 把整次刷新拖进 web-session 回落。
        object["byKeyAmount"] = byKeyAmount.flatMap { try? jsonObject(from: $0) } ?? NSNull()
        object["byKeyCost"] = byKeyCost.flatMap { try? jsonObject(from: $0) } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object)
    }
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `bash scripts/test.sh`
Expected: 全绿

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenHealth/DeepSeekUsageProvider.swift Tests/TokenHealthTests/DeepSeekDetailWiringTests.swift
git commit -m "Fetch the DeepSeek by-key usage on the native path"
```

---

### Task 7: web-session 脚本也取这两条

**Files:**
- Modify: `Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift:61-98`
- Test: `Tests/TokenHealthTests/WebSessionDescriptorTests.swift`

**Interfaces:**
- Consumes: `WebSessionFetchContext.start` / `.end`（Task 3）
- Produces: 脚本返回体多两个字段 `byKeyAmount` / `byKeyCost`，失败时为 `null`。

- [ ] **Step 1: 写失败的测试**

`Tests/TokenHealthTests/WebSessionDescriptorTests.swift` 里，`usageScriptMentionsRequestedMonth` 之后加：

```swift
    @Test
    func usageScriptRequestsTheByKeyEndpointsOverTheWindow() {
        // 2026-09-01 与 2026-09-25 的 UTC 零点。
        let context = WebSessionFetchContext(year: 2026, month: 9, start: 1_788_220_800, end: 1_790_294_400)
        let script = descriptor.usageFetchScript(context: context)

        #expect(script.contains("/api/v0/usage/by_api_key/amount?start=1788220800&end=1790294400&tz=0"))
        #expect(script.contains("/api/v0/usage/by_api_key/cost?start=1788220800&end=1790294400&tz=0"))
    }

    /// 两条 by_api_key 是可选请求：失败不许把整次取数判成失败。
    @Test
    func usageScriptKeepsTheOptionalRequestsOutOfTheFailureCheck() {
        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9, start: 0, end: 0))

        #expect(script.contains("[summary, amount, cost].find(item => !item.ok)"))
        #expect(!script.contains("[summary, amount, cost, byKeyAmount, byKeyCost].find"))
    }

    @Test
    func usageScriptReportsNullWhenAByKeyRequestFails() {
        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9, start: 0, end: 0))

        #expect(script.contains("byKeyAmount: byKeyAmount.ok ? byKeyAmount.json : null"))
        #expect(script.contains("byKeyCost: byKeyCost.ok ? byKeyCost.json : null"))
    }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `bash scripts/test.sh --filter WebSessionDescriptorTests`
Expected: FAIL —— 脚本里还没有 `by_api_key`

- [ ] **Step 3: 实现**

`Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift` 的 `usageFetchScript` 里，在 `const cost = request(...)` 之后加：

```js
          // 可选：这两条失败只让浮层少一张表，不进 firstFailure，也不影响其余区块。
          const byKeyAmount = request('/api/v0/usage/by_api_key/amount?start=\(context.start)&end=\(context.end)&tz=0');
          const byKeyCost = request('/api/v0/usage/by_api_key/cost?start=\(context.start)&end=\(context.end)&tz=0');
```

并把返回体（`return JSON.stringify({...})`）扩成：

```js
          return JSON.stringify({
            ok: !firstFailure,
            status: firstFailure ? firstFailure.status : 200,
            text: firstFailure ? firstFailure.text : '',
            hasAccessToken: Boolean(token),
            summary: summary.json,
            amount: amount.json,
            cost: cost.json,
            byKeyAmount: byKeyAmount.ok ? byKeyAmount.json : null,
            byKeyCost: byKeyCost.ok ? byKeyCost.json : null
          });
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `bash scripts/test.sh`
Expected: 全绿

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift Tests/TokenHealthTests/WebSessionDescriptorTests.swift
git commit -m "Fetch the DeepSeek by-key usage on the web-session path"
```

---

### Task 8: README 与版本号

**Files:**
- Modify: `README.md:109-111`
- Modify: `README.en.md:106-107`
- Modify: `AppSupport/Info.plist:16`

**Interfaces:**
- Consumes: 全部前序任务
- Produces: 面向使用者的说明与新版本号

- [ ] **Step 1: 改中文 README**

`README.md:109-111` 现在是：

```
点钉住的 DeepSeek 项会弹出详情浮层：余额、`Today` 与 `This month` 的请求数 / tokens / 花费、本月按天趋势、
tokens 构成（`Output` / `Cache hit` / `Cache miss`），以及 `By model · this month` 的按模型拆分。
数据全部来自刷新时已经取回的那次响应，不额外发请求。
```

改成：

```
点钉住的 DeepSeek 项会弹出详情浮层：余额、`Today` 与 `This month` 的请求数 / tokens / 花费、本月按天趋势、
tokens 构成（`Output` / `Cache hit` / `Cache miss`），以及 `By model · this month` 与
`By API key · this month` 两张拆分表。
余额、汇总、趋势与按模型拆分来自刷新时已经取回的那次响应；两张表之外多打的两个按 key 请求是可选的 ——
它们失败时只是少一张 `By API key` 表，其余数字与菜单栏照常。
```

- [ ] **Step 2: 改英文 README**

`README.en.md:106-107` 现在是：

```
Clicking a pinned DeepSeek item opens a detail popover: balance, request count / tokens / spend for `Today` and `This month`, a by-day trend for the month, the token breakdown (`Output` / `Cache hit` / `Cache miss`), and a `By model · this month` split.
Everything comes from the response already fetched at refresh time — no extra requests.
```

改成：

```
Clicking a pinned DeepSeek item opens a detail popover: balance, request count / tokens / spend for `Today` and `This month`, a by-day trend for the month, the token breakdown (`Output` / `Cache hit` / `Cache miss`), and two splits — `By model · this month` and `By API key · this month`.
The balance, totals, trend and by-model split come from the response already fetched at refresh time; the two by-key requests are optional — if they fail you lose the `By API key` table and nothing else.
```

- [ ] **Step 3: 升版本号**

`AppSupport/Info.plist:16` 的 `1.0.6` 改成 `1.0.7`。

- [ ] **Step 4: 验证文档之外没漏**

Run: `grep -rn "1\.0\.6" README.md README.en.md AppSupport/Info.plist`
Expected: 无输出

- [ ] **Step 5: Commit**

```bash
git add README.md README.en.md AppSupport/Info.plist
git commit -m "Document the DeepSeek by-key table and cut 1.0.7"
```

---

### Task 9: 实测端点形状并核对口径（需要你参与）

**Files:**
- Modify: `docs/superpowers/specs/2026-10-06-deepseek-api-key-dimension-design.md`（把实测结论写回 §2.3 / §2.4 / §5.4）

**Interfaces:**
- Consumes: 全部前序任务
- Produces: 形状确认，或据实测调整的解析代码

这一步不能由我独立完成 —— 它需要你在本机已登录 DeepSeek Platform 的会话里跑一次。

- [ ] **Step 1: 构建并安装**

```bash
bash scripts/build-app.sh
```

```bash
rm -rf "/Applications/Token Health.app"
```

```bash
cp -R .build/app "/Applications/Token Health.app"
```

（`build-app.sh` 只产出 `.build/app`，不装到 `/Applications` —— 必须手动覆盖才生效。）

- [ ] **Step 2: 打开 debug log 并刷新一次**

Run: `log stream --predicate 'process == "Token Health"' --style compact`
另开一个窗口，在 app 里点一次 DeepSeek 的刷新。

Expected: 出现 `optional request failed, path=/api/v0/usage/by_api_key/amount…`（说明端点不被接受）
或没有任何该行（说明两个请求都成功）。

- [ ] **Step 3: 确认两张表**

点钉住的 DeepSeek 项 → 浮层里应出现 `By model · this month` 与 `By API key · this month` 两张表。

- [ ] **Step 4: 核对口径**

把 `By API key` 表的 Requests / Tokens 两列相加，与 `This month` 那一行对比：

- **对得上** → 无需改动。
- **对不上** → 按 spec §5.4，给 key 表的 `footnote` 补一句口径说明（`Excludes usage without an API key` 之类），
  并在 spec §5.4 记录实测数字。改动落在 `DeepSeekUsageDetail.keyTable`：
  `footnote: hidden > 0 ? "+\(hidden) more API keys" : (口径说明)`，注意两者同时存在时的拼接顺序。

- [ ] **Step 5: 把结论写回 spec 并提交**

```bash
git add docs/superpowers/specs/2026-10-06-deepseek-api-key-dimension-design.md
git commit -m "Record what the by-key endpoint actually returns"
```

- [ ] **Step 6: 若端点被拒**

如果 `optional request failed` 反复出现且状态码是 403，给 `fetchPlatformData` 的请求头补上
`x-client-platform: web`（CodexBar 带了这一项），重跑 Step 1–4。

---

## Self-Review

**Spec coverage：**

| spec 章节 | 落在哪个任务 |
| --- | --- |
| §2.2 新增两个端点 | Task 6（native）、Task 7（web） |
| §2.3 响应形状的五条 | Task 4（解析）、Task 5（越界过滤） |
| §2.4 形状来源与实测 | Task 9 |
| §3.1 窗口参数 | Task 2 |
| §3.2 native 取数 | Task 6 |
| §3.3 web 脚本与 context | Task 3、Task 7 |
| §4 解析 | Task 4 |
| §5.1 byKey 聚合 | Task 5 |
| §5.2 表 | Task 5 |
| §5.3 展示名与去重 | Task 5 |
| §5.4 与 By model 对不上时 | Task 9 Step 4 |
| §6.1 UsageDetail.tables | Task 1 |
| §6.2 WebSessionFetchContext | Task 3 |
| §7 文案表 | Task 1（`By model`）、Task 5（`By API key` 全部文案）、Task 8（README） |
| §8 错误与边界 | Task 5（越界/全零/未知身份）、Task 6（可选请求失败）、Task 4（标量为 null/负数） |
| §9 测试策略 | 每个任务的 Step 1 |
| §10 已知取舍 | 无需代码 |
| §11 验收 | Task 8（版本）、Task 9（实测与手动验收） |

**Review Focus 的五条各落在哪：**

1. 两侧身份一致 → `DeepSeekUsageDetailTests.matchesTheObjectFormOnTheAmountSideWithTheBareStringOnTheCostSide`（Task 5）
2. `api_key` 为 null / 第三种类型 → `DeepSeekPayloadTests.identityFallsBackInOrderOfConfidence`（Task 4）+ `DeepSeekUsageDetailTests.mergesKeysWithoutAnyIdentityIntoOneRow`（Task 5）
3. 窗口边界日 → `UsageDetailSupportTests.windowOnTheFirstSpansOneDay`（Task 2）+ `DeepSeekUsageDetailTests.dropsBucketsOutsideTheMonth`（Task 5）
4. 两把 key 同名 → `DeepSeekUsageDetailTests.renamesAPIKeysThatShareADisplayName`（Task 5）
5. 两张满表 → `DetailPopoverRenderTests.rendersBothTablesInOrder`（Task 1）

**类型一致性：** `APIKeyIdentity.keyID` / `.displayName` 在 Task 4 定义、Task 5 使用；
`KeyTotals` 是 Task 5 内部的 typealias，不出文件；`monthToDateWindow` 返回 `(start: Int, end: Int)?`，
Task 3 与 Task 6 都以 optional 处理。`fetchPlatformDataOptional` / `fetchByKeyData` / `window(now:)`
三个 helper 都在 Task 6 内定义并使用。
