# OpenCode Go 用量详情浮层 实现计划

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 点钉住的 OpenCode Go 菜单栏项弹出详情浮层：三额度、今天/7 天/30 天汇总、30 天每日花费趋势、token 构成、按模型表。

**Architecture:** 沿用 DeepSeek 铺好的通用详情链路（`UsageDetail` → `ProviderUsageSnapshot.detail` → `DetailPopoverView`）。新增 `OpenCodeGoUsageDetail` 把一次刷新取回的信封变成 `UsageDetail`；provider 的原生路径与 WebView 兜底脚本产出**同一形状的信封**（`{goStatus, orgs, workspaceId, usageSummary, usageByDay, usageModels}`），信封 `ok`/`status`/`text` 仍只描述 `/api/go/status`（内核靠它判会话过期），用量接口失败只体现为对应键缺席。同时修掉既有网页会话路径的两个缺陷：金额标度差 100 倍、解析不了线上新形状且缺 `x-org-id` 作用域。

**Tech Stack:** Swift 6 / swift-tools 6.0、SwiftUI（macOS 14+）、swift-testing（`import Testing`、`@Suite` / `@Test` / `#expect`）、无第三方依赖。

**Spec:** `docs/superpowers/specs/2026-09-25-opencode-go-detail-design.md`

---

## 前置约束

- **分支**：当前在 `main` 且干净。先 `git switch -c feature/opencode-go-detail`。
- **跑测试**：一律 `bash scripts/test.sh`；过滤用 `bash scripts/test.sh --filter <SuiteName>`（本机无 Xcode，裸跑 `swift test` 编译不过）。
- **注释语言**：改既有文件时沿用该文件自己的风格（`UsageDetail.swift` / `DetailPopoverView.swift` / `DeepSeekUsageDetail.swift` 是中文注释；`OpenCodeGo*.swift` 是英文）；**新建的源码文件用英文**，新建的测试文件沿用 `Tests/` 目录的中文风格。计划里的代码块已经按此写死，落盘时照抄即可。
- **提交**：每个任务一个提交，message 用陈述句（不带 `feat:` 前缀），结尾固定：
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- 只用显式路径 `git add`，不要 `git add -A`。
- 每个提交都必须能编译、能通过测试。

## 文件结构

**新增**

| 文件 | 职责 |
| --- | --- |
| `Sources/TokenHealth/OpenCodeGoUsageDetail.swift` | 信封 → `UsageDetail`（纯计算，不抛错） |
| `Tests/TokenHealthTests/OpenCodeGoUsageDetailTests.swift` | 详情构建的各区块与边界 |
| `Tests/TokenHealthTests/OpenCodeGoDetailWiringTests.swift` | 信封 → 快照（含 detail）的接线 |

**修改**

| 文件 | 改动 |
| --- | --- |
| `Sources/TokenHealth/OpenCodeGoUsageProvider.swift` | 金额标度；新形状解析；信封拼装 `OpenCodeGoUsageEnvelope`；原生取数改多请求；`consoleSnapshot` 注入点 |
| `Sources/TokenHealth/OpenCodeGoWebSessionDescriptor.swift` | 脚本扩展为 5 个端点 + `x-org-id` + workspace 选择 |
| `Sources/TokenHealth/Providers.swift` | `producesUsageDetail` 加 `.openCodeGo` |
| `Sources/TokenHealth/UsageDetail.swift` | `DetailSeries` 增加 `emptyText` |
| `Sources/TokenHealth/DetailPopoverView.swift` | 空趋势图文案改读 `series.emptyText` |
| `Sources/TokenHealth/DeepSeekUsageDetail.swift` | 传入 `"No usage this month"` |
| `Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift` | fixture ×100（标度）、新形状、workspace 辅助函数、信封 |
| `Tests/TokenHealthTests/OpenCodeGoWebSessionDescriptorTests.swift` | 脚本内容断言 |
| `Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift` | Go 的两种模式 |
| `Tests/TokenHealthTests/DetailPopoverRenderTests.swift` | 两处 `DetailSeries` 构造补 `emptyText` |

---

## Chunk 1: 金额标度与新形状解析

### Task 1: 把金额标度修到 1e-8（fixture 一律 ×100）

**背景**：console 的金额单位是 microcents（1 USD = 1e8），证据见 spec §2。现有 `dollarsText` 按 `/1e6` 换算，网页会话路径会把 $12 显示成 $1200。

**Files:**
- Modify: `Sources/TokenHealth/OpenCodeGoUsageProvider.swift:333-344`（`apiLimitMicroCents`）、`:428-431`（`dollarsText`）
- Test: `Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift`

- [ ] **Step 1: 先把测试改到新标度（会失败）**

把 `formatsDollarsFromMicroCents` 整个替换为：

```swift
    @Test
    func formatsDollarsFromMicroCents() {
        // microcents: 1 USD = 1e8. The console's own price constants use this scale
        // (Go plan recurringMicroCents = 1000000000n is $10/mo).
        #expect(OpenCodeGoUsageParser.dollarsText(120_000_000) == "$1.20")
        #expect(OpenCodeGoUsageParser.dollarsText(1_200_000_000) == "$12.00")
        #expect(OpenCodeGoUsageParser.dollarsText(5_000_000) == "$0.05")
        #expect(OpenCodeGoUsageParser.dollarsText(100_000_000) == "$1.00")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter OpenCodeGoUsageProviderTests`
Expected: FAIL —— `dollarsText(120_000_000)` 现在返回 `"$120.00"`。

- [ ] **Step 3: 改实现**

`Sources/TokenHealth/OpenCodeGoUsageProvider.swift` 里，`dollarsText` 与 `apiLimitMicroCents` 替换为：

```swift
    /// Published OpenCode Go dollar limits per window, in microcents (1 USD = 1e8).
    static func apiLimitMicroCents(for key: String) -> Int? {
        switch key {
        case "rolling", "five_hour", "fiveHours", "5h":
            12 * 100_000_000
        case "weekly", "week", "calendar_week":
            30 * 100_000_000
        case "monthly", "month", "calendar_month":
            60 * 100_000_000
        default:
            nil
        }
    }
```

```swift
    /// Console money fields are microcents: 1 USD = 1e8.
    static func dollars(_ microCents: Int) -> Double {
        Double(microCents) / 100_000_000
    }

    static func dollarsText(_ microCents: Int) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), dollars(microCents))
    }
```

顺手给 `parseAPIResponse` 的 `limits` / `usage` 容错分支（`if let list = (root["limits"] as? [[String: Any]]) ?? (root["usage"] as? [[String: Any]])` 那两处）各补一行注释，落实 spec §12 的要求：

```swift
        // Amounts here come straight from the response, so they share the console's microcent
        // scale (1 USD = 1e8); unlike the API-key path's published limits, this branch has never
        // been checked against a real Zen response.
```

- [ ] **Step 4: 把其余 fixture 与断言全部 ×100**

规则（spec §3.1）：所有代表美元金额的 fixture 数值 ×100；常量驱动的数字断言 ×100；**所有显示字符串逐字不变**。逐条替换：

`sampleGoStatus` fixture：`amountMicroCents` `10000000` → `1000000000`；five_hour `limitMicroCents` `1200000` → `120000000`、`settledMicroCents` `310000` → `31000000`、`reservedMicroCents` `9000` → `900000`、`remainingMicroCents` `881000` → `88100000`；calendar_week 同比例（`3000000`→`300000000`、`900000`→`90000000`、`50000`→`5000000`、`2050000`→`205000000`）；calendar_month 同比例（`6000000`→`600000000`、`2100000`→`210000000`、`120000`→`12000000`、`3780000`→`378000000`）。

`parsesActiveGoStatusIntoThreeMeters` 的断言替换为：

```swift
        #expect(result.planName == "Go · $10.00/mo")
        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        // used = limit - remaining, in microcents
        #expect(result.usages.map(\.used) == [31_900_000, 95_000_000, 222_000_000])
        #expect(result.usages.map(\.limit) == [120_000_000, 300_000_000, 600_000_000])
        // displayValue is dollar-formatted and must not change with the scale
        #expect(result.usages.map(\.displayValue) == ["$0.32 / $1.20", "$0.95 / $3.00", "$2.22 / $6.00"])
```

`fallsBackToSettledMicroCentsWhenRemainingMissing`：fixture `limitMicroCents` `1200000` → `120000000`、`settledMicroCents` `330000` → `33000000`；断言 `used == 33_000_000`、`limit == 120_000_000`。

`skipsUnknownMeterKinds`：两条 meter 的金额 ×100（`1000`→`100000`、`500`→`50000`、`1200000`→`120000000`、`900000`→`90000000`）。

`sampleGoStatus` 里 parser 不读、也没有断言的 `nextChargeMicroCents` / `recurringChargeMicroCents` 一并 ×100（`1000000`→`100000000`），免得 fixture 里出现「$10/月的套餐、下次扣款 $0.01」这种自相矛盾的数。

**注意**：下面每条只替换列出的行/断言，用例里其余没提到的断言（如 `subscriptionMessage == nil`、`resetDates` 计数、`unit == nil`、window 顺序）原样保留。

`unwrapsWebViewEnvelopeFromGoStatus`：三条 meter 的 `limitMicroCents` / `remainingMicroCents` ×100；断言 `used == [30_000_000, 100_000_000, 200_000_000]`。

`parsesRealAPIUsageShape`：常量已变，断言替换为：

```swift
        #expect(sorted.map(\.used) == [60_000_000, 480_000_000, 480_000_000])
        #expect(sorted.map(\.limit) == [1_200_000_000, 3_000_000_000, 6_000_000_000])
        #expect(sorted.map(\.displayValue) == ["$0.60 / $12.00", "$4.80 / $30.00", "$4.80 / $60.00"])
```

`apiUsageOverLimitClampsToLimit`：断言 `used == 1_200_000_000`、`limit == 1_200_000_000`。

`parsesAPIUsageLimitsArray`：fixture 三个 `limitMicroCents` / `usedMicroCents` ×100；断言 `used == [30_000_000, 90_000_000, 210_000_000]`、`limit == [120_000_000, 300_000_000, 600_000_000]`。

`parsesAPIUsageLimitsDictionary`：fixture 三个 `limit` / `used` ×100；断言 `used == [40_000_000, 80_000_000, 200_000_000]`。

`parsesAPIUsageDataEnvelope`：fixture `limitMicroCents` `1200000`→`120000000`、`remainingMicroCents` `1000000`→`100000000`；断言 `used == 20_000_000`、`limit == 120_000_000`。

- [ ] **Step 5: 跑测试确认全绿**

Run: `bash scripts/test.sh`
Expected: PASS，且**没有任何 `displayValue` / `planName` 字符串断言需要改动**（这是「用户可见行为没变」的证据）。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/OpenCodeGoUsageProvider.swift Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift
git commit -m "$(cat <<'EOF'
Fix the OpenCode Go money scale to microcents

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 2: 解析 console 现在的新形状（`access.meters`）

**背景**：线上 `/api/go/status` 返回 `{access: {meters: {fiveHour|week|month: {limitMicroCents, usedMicroCents, resetsAt}}, endsAt}, cancelAtPeriodEnd, renewalPending}`；`access` 缺失/null 表示未订阅。月窗口没有 `resetsAt`，用 `access.endsAt`。新形状没有价格，`planName` 固定 `"Go"`。

**Files:**
- Modify: `Sources/TokenHealth/OpenCodeGoUsageProvider.swift:196-232`（`parseBundle`）及其后新增私有方法
- Test: `Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift`

- [ ] **Step 1: 写失败测试**

在 `OpenCodeGoUsageProviderTests` 里加：

```swift
    @Test
    func parsesAccessMetersShape() throws {
        // The live console shape (2026-09): access.meters.fiveHour/week/month.
        let response = """
        {
          "access": {
            "startsAt": "2026-09-01T00:00:00.000Z",
            "endsAt": "2026-10-01T00:00:00.000Z",
            "meters": {
              "fiveHour": { "limitMicroCents": 1200000000, "usedMicroCents": 32000000, "resetsAt": "2026-09-25T12:00:00.000Z" },
              "week": { "limitMicroCents": 3000000000, "usedMicroCents": 95000000, "resetsAt": "2026-09-28T00:00:00.000Z" },
              "month": { "limitMicroCents": 6000000000, "usedMicroCents": 222000000 }
            }
          },
          "cancelAtPeriodEnd": false,
          "renewalPending": false
        }
        """
        let result = try parse(response)

        #expect(result.subscriptionMessage == nil)
        #expect(result.planName == "Go")
        #expect(result.usages.map(\.window) == [.fiveHours, .week, .month])
        #expect(result.usages.map(\.used) == [32_000_000, 95_000_000, 222_000_000])
        #expect(result.usages.map(\.limit) == [1_200_000_000, 3_000_000_000, 6_000_000_000])
        #expect(result.usages.map(\.displayValue) == ["$0.32 / $12.00", "$0.95 / $30.00", "$2.22 / $60.00"])
        // The month window has no resetsAt of its own; it falls back to access.endsAt.
        #expect(result.usages[2].resetDate == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        #expect(result.usages[0].resetDate == ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z"))
    }

    @Test
    func accessShapeWithoutUsableMetersReportsNotSubscribed() throws {
        let response = """
        { "access": { "endsAt": "2026-10-01T00:00:00.000Z", "meters": {} } }
        """
        let result = try parse(response)

        #expect(result.usages.isEmpty)
        #expect(result.subscriptionMessage?.contains("not subscribed") == true)
    }

    @Test
    func missingAccessFailsOverToTheLegacyShape() throws {
        // No access object: the key is absent or null. The legacy shape still parses.
        let response = """
        {
          "subscriptionStatus": "active",
          "meters": [
            { "kind": "five_hour", "resetsAt": "2026-08-07T12:00:00.000Z", "limitMicroCents": 120000000, "remainingMicroCents": 90000000 }
          ]
        }
        """
        let result = try parse(response)

        #expect(result.usages.count == 1)
        #expect(result.usages[0].window == .fiveHours)
        #expect(result.usages[0].used == 30_000_000)
    }

    @Test
    func accessMetersShapeInsideTheWebViewEnvelope() throws {
        // The WebView script wraps the response in {ok, status, ..., goStatus: {...}}.
        let envelope = """
        {
          "ok": true, "status": 200, "text": "", "hasSession": true,
          "goStatus": {
            "access": { "meters": {
              "fiveHour": { "limitMicroCents": 1200000000, "usedMicroCents": 32000000, "resetsAt": "2026-09-25T12:00:00.000Z" }
            } }
          }
        }
        """
        let result = try parse(envelope)

        #expect(result.usages.map(\.displayValue) == ["$0.32 / $12.00"])
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter OpenCodeGoUsageProviderTests`
Expected: FAIL —— 新形状会走旧路径解析出空（`parsesAccessMetersShape` 断言 usages 为空后失败）。

- [ ] **Step 3: 实现**

`parseBundle` 里，在 `let goStatusRoot = ...` 这一行**之后**插入早退分支：

```swift
        // The live console shape (2026-09) carries its meters under `access`; it has no price or
        // subscriptionStatus, so it returns early and never reaches the legacy walk below.
        if let access = goStatusRoot["access"] as? [String: Any] {
            return accessShapeResult(access: access)
        }
```

在 `parseAPIResponse` 之前新增私有方法：

```swift
    /// Parse the current console shape:
    /// `{access: {meters: {fiveHour|week|month: {limitMicroCents, usedMicroCents, resetsAt}}, endsAt}}`.
    /// `access` absent or null means no subscription and falls through to the legacy shape.
    private func accessShapeResult(access: [String: Any]) -> ParseResult {
        let meters = access["meters"] as? [String: Any] ?? [:]
        let periodEnd = dateValue(access["endsAt"])

        var usages: [TokenUsage] = []
        for (key, window) in [("fiveHour", UsageWindow.fiveHours), ("week", .week), ("month", .month)] {
            guard let item = meters[key] as? [String: Any],
                  let limit = intValue(item["limitMicroCents"]), limit > 0 else {
                continue
            }
            let used = max(0, intValue(item["usedMicroCents"]) ?? 0)
            usages.append(TokenUsage(
                window: window,
                used: used,
                limit: limit,
                // The month meter has no resetsAt of its own; the paid period end stands in for it.
                resetDate: dateValue(item["resetsAt"]) ?? periodEnd,
                unit: nil,
                displayValue: "\(Self.dollarsText(used)) / \(Self.dollarsText(limit))"
            ))
        }

        guard !usages.isEmpty else {
            return ParseResult(
                planName: nil,
                subscriptionMessage: subscriptionMessage(for: "inactive"),
                usages: []
            )
        }

        // This shape carries no price (the console keeps it in the checkout product), so the plan
        // name is the bare "Go" — the same fallback the API-key path uses.
        return ParseResult(planName: "Go", subscriptionMessage: nil, usages: usages)
    }
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `bash scripts/test.sh`
Expected: PASS（含 Task 1 的旧形状用例）。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/OpenCodeGoUsageProvider.swift Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift
git commit -m "$(cat <<'EOF'
Parse the console's current access.meters shape

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: 信封与两条取数路径

### Task 3: 信封拼装纯函数

**Files:**
- Modify: `Sources/TokenHealth/OpenCodeGoUsageProvider.swift`（文件末尾新增类型）
- Test: `Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    @Test
    func envelopeKeepsOkBoundToTheStatusRequest() throws {
        // ok/status/text describe /api/go/status only: the kernel throws on ok == false, so a
        // failed usage call must never flip it — it only shows up as a missing key.
        let data = OpenCodeGoUsageEnvelope.make(
            status: Data(#"{"access":{"meters":{}}}"#.utf8),
            orgs: Data(#"[{"id":"wrk_1","name":"Home"}]"#.utf8),
            workspaceId: "wrk_1",
            summary: nil,
            byDay: nil,
            models: nil
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["ok"] as? Bool == true)
        #expect(object["workspaceId"] as? String == "wrk_1")
        #expect(object["goStatus"] != nil)
        #expect((object["orgs"] as? [[String: Any]])?.first?["id"] as? String == "wrk_1")
        #expect(object["usageSummary"] == nil)
        #expect(object["usageByDay"] == nil)
        #expect(object["usageModels"] == nil)
    }

    @Test
    func envelopeCarriesEveryUsagePayloadWhenPresent() throws {
        let data = OpenCodeGoUsageEnvelope.make(
            status: Data(#"{"access":{"meters":{}}}"#.utf8),
            orgs: Data("[]".utf8),
            workspaceId: nil,
            summary: Data(#"{"totalRequests":1}"#.utf8),
            byDay: Data(#"[{"date":"2026-09-25","totalRequests":1}]"#.utf8),
            models: Data(#"{"items":[]}"#.utf8)
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect((object["usageSummary"] as? [String: Any])?["totalRequests"] as? Int == 1)
        #expect((object["usageByDay"] as? [[String: Any]])?.count == 1)
        #expect(object["usageModels"] != nil)
        #expect(object["workspaceId"] == nil)
    }

    @Test
    func workspaceIDsAndAccessAreReadFromRawBodies() throws {
        let orgs = Data(#"[{"id":"wrk_a","name":"A"},{"id":"","name":"B"},{"nope":1}]"#.utf8)
        #expect(OpenCodeGoUsageParser.workspaceIDs(fromOrgs: orgs) == ["wrk_a"])

        #expect(OpenCodeGoUsageParser.hasGoAccess(statusData: Data(#"{"access":{"meters":{}}}"#.utf8)))
        #expect(!OpenCodeGoUsageParser.hasGoAccess(statusData: Data(#"{"access":null}"#.utf8)))
        #expect(OpenCodeGoUsageParser.hasGoAccess(statusData: Data(#"{"subscriptionStatus":"active","meters":[]}"#.utf8)))
        #expect(!OpenCodeGoUsageParser.hasGoAccess(statusData: Data(#"{"subscriptionStatus":"canceled"}"#.utf8)))
        #expect(!OpenCodeGoUsageParser.hasGoAccess(statusData: Data("not json".utf8)))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter OpenCodeGoUsageProviderTests`
Expected: FAIL —— `OpenCodeGoUsageEnvelope` / `workspaceIDs` / `hasGoAccess` 未定义（编译错误）。

- [ ] **Step 3: 实现**

在 `OpenCodeGoUsageProvider.swift` 的 `OpenCodeGoUsageParser` 里新增两个静态方法（放在 `accessShapeResult` 附近）：

```swift
    /// `/api/orgs` → `[{id, name}]`; the app only needs the ids.
    static func workspaceIDs(fromOrgs data: Data) -> [String] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    /// Whether this workspace carries a Go subscription, in either the current (`access`) or the
    /// legacy (`subscriptionStatus`) shape.
    ///
    /// An `access` object without usable meters still counts as "has access": the parser reports
    /// that as not-subscribed, which is the honest degrade. Do not read `true` as "has quota".
    static func hasGoAccess(statusData: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else {
            return false
        }
        let goStatus = (root["goStatus"] as? [String: Any]) ?? root
        if goStatus["access"] is [String: Any] {
            return true
        }
        guard let status = goStatus["subscriptionStatus"] as? String else {
            return false
        }
        return status == "active" || status == "grace"
    }
```

在文件末尾新增枚举：

```swift
/// Assembles the native path's responses into the same envelope the WebView script returns.
///
/// `ok` / `status` / `text` describe the `/api/go/status` request only: the session kernel throws
/// on `ok == false` (and maps 401/403 to session-expired), so a failed usage call must never flip
/// them — it only shows up as the matching `usage*` key being absent. Absent keys and explicit
/// nulls are equivalent: both consumers read them with optional casts.
enum OpenCodeGoUsageEnvelope {
    static func make(
        status: Data,
        orgs: Data,
        workspaceId: String?,
        summary: Data?,
        byDay: Data?,
        models: Data?
    ) -> Data {
        var object: [String: Any] = [
            "ok": true,
            "status": 200,
            "text": "",
            "hasSession": true
        ]

        object["goStatus"] = jsonObject(from: status) ?? [:]
        if let orgsObject = jsonObject(from: orgs) {
            object["orgs"] = orgsObject
        }
        if let workspaceId {
            object["workspaceId"] = workspaceId
        }
        if let summary, let value = jsonObject(from: summary) {
            object["usageSummary"] = value
        }
        if let byDay, let value = jsonObject(from: byDay) {
            object["usageByDay"] = value
        }
        if let models, let value = jsonObject(from: models) {
            object["usageModels"] = value
        }

        return (try? JSONSerialization.data(withJSONObject: object)) ?? status
    }

    private static func jsonObject(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }
}
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `bash scripts/test.sh --filter OpenCodeGoUsageProviderTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/OpenCodeGoUsageProvider.swift Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift
git commit -m "$(cat <<'EOF'
Assemble the native OpenCode Go envelope

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 4: 原生路径改多请求（orgs → 逐 workspace 状态 → 三份用量）

**背景**：`/api/go/status` 与 `/api/usage/*` 都要 `x-org-id`（缺了 400），workspace 列表来自 `GET /api/orgs`。现有 `fetchUsageBundle` 只打一个无作用域的 `/api/go/status`。

**Files:**
- Modify: `Sources/TokenHealth/OpenCodeGoUsageProvider.swift:142-176`（`fetchUsageBundle`）

- [ ] **Step 1: 替换 `fetchUsageBundle`**

```swift
    private func fetchUsageBundle(session: OpenCodeGoWebSessionCredential) async throws -> Data {
        let orgsData = try await fetchData(session: session, path: "/api/orgs")
        let workspaces = OpenCodeGoUsageParser.workspaceIDs(fromOrgs: orgsData)

        // Prefer the first workspace that carries a Go subscription; fall back to the first
        // workspace's response so "not subscribed" still gets its own message.
        var statusData: Data?
        var workspaceID: String?
        for workspace in workspaces.prefix(Self.workspaceProbeLimit) {
            let data = try await fetchData(session: session, path: "/api/go/status", workspaceID: workspace)
            if statusData == nil {
                statusData = data
                workspaceID = workspace
            }
            if OpenCodeGoUsageParser.hasGoAccess(statusData: data) {
                statusData = data
                workspaceID = workspace
                break
            }
        }

        guard let statusData else {
            throw WebSessionError.requestFailed(
                providerTitle: Self.providerTitle,
                message: "OpenCode Go has no workspace"
            )
        }

        async let summary = fetchUsageData(session: session, path: "/api/usage/summary", query: [("range", "30d")], workspaceID: workspaceID)
        async let byDay = fetchUsageData(session: session, path: "/api/usage/cost-by-day", query: [("range", "30d"), ("bucket", "day")], workspaceID: workspaceID)
        async let models = fetchUsageData(session: session, path: "/api/usage/models", query: [("range", "30d"), ("pageSize", "100"), ("costOrder", "desc")], workspaceID: workspaceID)

        return OpenCodeGoUsageEnvelope.make(
            status: statusData,
            orgs: orgsData,
            workspaceId: workspaceID,
            summary: await summary,
            byDay: await byDay,
            models: await models
        )
    }

    /// The usage endpoints are a nice-to-have: a failure only drops the matching card section, it
    /// must not fail the whole refresh.
    private func fetchUsageData(
        session: OpenCodeGoWebSessionCredential,
        path: String,
        query: [(String, String)],
        workspaceID: String?
    ) async -> Data? {
        do {
            return try await fetchData(session: session, path: path, query: query, workspaceID: workspaceID)
        } catch {
            WebSessionLog.debugLog(
                "usage request failed path=\(path): \(error.localizedDescription)",
                providerTitle: Self.providerTitle
            )
            return nil
        }
    }

    private func fetchData(
        session: OpenCodeGoWebSessionCredential,
        path: String,
        query: [(String, String)] = [],
        workspaceID: String? = nil
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = consoleHost
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Scoped console endpoints answer HTTP 400 when this header is missing.
        if let workspaceID, !workspaceID.isEmpty {
            request.setValue(workspaceID, forHTTPHeaderField: "x-org-id")
        }
        if let cookieHeader = session.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        WebSessionLog.debugLog(
            "native request endpoint=\(url.absoluteString), \(session.debugSummary)",
            providerTitle: Self.providerTitle
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            WebSessionLog.debugLog(
                "native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))",
                providerTitle: Self.providerTitle
            )
            throw WebSessionError.requestFailed(
                providerTitle: Self.providerTitle,
                message: "OpenCode Go HTTP \(httpResponse.statusCode): \(body.prefix(160))"
            )
        }
        WebSessionLog.debugLog("native request succeeded, path=\(path), bytes=\(data.count)", providerTitle: Self.providerTitle)
        return data
    }
```

- [ ] **Step 2: 常量**

在 `OpenCodeGoUsageProvider` 顶部（`consoleHost` 旁边）加：

```swift
    private let consoleHost = "console.opencode.ai"
    /// Keep in sync with the web script's `workspaces.slice(0, 5)`.
    private static let workspaceProbeLimit = 5
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
```

原 `fetchUsageBundle` 里内联的 UA 字符串随之删除（它现在在 `fetchData` 里）。

同时把 `fetchConsoleUsage` 里那条注释改准（脚本现在会打带固定 30 天参数的用量接口）：

```swift
                // The console script scrapes a fixed 30-day window and takes no period from the
                // context, so the values passed in are inert.
                bundleData = try await controller.fetchUsage(
```

- [ ] **Step 3: 编译 + 跑全量测试**

Run: `bash scripts/test.sh`
Expected: PASS（这一层没有网络测试，纯编译与既有用例）。

- [ ] **Step 4: 提交**

```bash
git add Sources/TokenHealth/OpenCodeGoUsageProvider.swift
git commit -m "$(cat <<'EOF'
Fetch OpenCode Go usage across the workspace's console endpoints

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 5: WebView 兜底脚本扩展

**Files:**
- Modify: `Sources/TokenHealth/OpenCodeGoWebSessionDescriptor.swift:31-64`（`usageFetchScript`）
- Test: `Tests/TokenHealthTests/OpenCodeGoWebSessionDescriptorTests.swift`

- [ ] **Step 1: 写失败的描述符测试**

```swift
    @Test
    func usageScriptCoversTheConsoleEndpoints() {
        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9))

        for path in ["/api/orgs", "/api/go/status", "/api/usage/summary", "/api/usage/cost-by-day", "/api/usage/models"] {
            #expect(script.contains(path), "脚本少打了 \(path)")
        }
        #expect(script.contains("x-org-id"))
        #expect(script.contains("usageSummary"))
        #expect(script.contains("usageByDay"))
        #expect(script.contains("usageModels"))
        // ok/status/text must keep describing the go/status request alone: the kernel throws on
        // ok == false, so a failed usage call must not be able to fail the whole refresh.
        #expect(script.contains("ok: !failed"))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter OpenCodeGoWebSessionDescriptorTests`
Expected: FAIL —— 脚本里还没有 `/api/orgs`。

- [ ] **Step 3: 替换脚本**

`usageFetchScript(context:)` 的 `"""` 内容整体替换为（其上的文档注释 `/// The status endpoint takes no period parameters…` 同时改成 `/// The console usage endpoints take a fixed 30-day window; the context is intentionally unused.`）：

```js
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const request = (path, headers) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', path, false);
            xhr.withCredentials = true;
            xhr.setRequestHeader('Accept', 'application/json');
            if (headers) {
              for (const name of Object.keys(headers)) {
                xhr.setRequestHeader(name, headers[name]);
              }
            }
            xhr.send();
            return {
              ok: xhr.status >= 200 && xhr.status < 300,
              status: xhr.status,
              text: xhr.responseText || '',
              json: parseJSON(xhr.responseText || '')
            };
          };
          const session = request('/auth/session');
          const orgs = request('/api/orgs');
          const workspaces = Array.isArray(orgs.json)
            ? orgs.json.map((item) => item && item.id).filter(Boolean)
            : [];
          // Scoped console endpoints need x-org-id; pick the first workspace that has a Go
          // subscription, else keep the first workspace's response so "not subscribed" survives.
          // The 5 must stay in sync with the provider's workspaceProbeLimit.
          const hasAccess = (json) => Boolean(json && (json.access || (json.goStatus && json.goStatus.access)));
          let chosen = null;
          let workspaceId = workspaces.length > 0 ? workspaces[0] : null;
          for (const id of workspaces.slice(0, 5)) {
            const attempt = request('/api/go/status', { 'x-org-id': id });
            if (chosen === null) {
              chosen = attempt;
              workspaceId = id;
            }
            if (hasAccess(attempt.json)) {
              chosen = attempt;
              workspaceId = id;
              break;
            }
          }
          const status = chosen || { ok: false, status: 400, text: 'OpenCode Go has no workspace', json: null };
          const scoped = (path) => workspaceId
            ? request(path, { 'x-org-id': workspaceId })
            : { ok: false, status: 0, text: '', json: null };
          const summary = scoped('/api/usage/summary?range=30d');
          const byDay = scoped('/api/usage/cost-by-day?range=30d&bucket=day');
          const models = scoped('/api/usage/models?range=30d&pageSize=100&costOrder=desc');
          const failed = !status.ok;
          return JSON.stringify({
            ok: !failed,
            status: status.status,
            text: failed ? status.text : '',
            hasSession: Boolean(session.ok && session.json && session.json.user),
            goStatus: status.json,
            session: session.ok ? session.json : null,
            orgs: Array.isArray(orgs.json) ? orgs.json : null,
            workspaceId: workspaceId,
            usageSummary: summary.ok ? summary.json : null,
            usageByDay: byDay.ok ? byDay.json : null,
            usageModels: models.ok ? models.json : null
          });
        })();
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `bash scripts/test.sh --filter OpenCodeGoWebSessionDescriptorTests`
Expected: PASS。再跑一次全量 `bash scripts/test.sh`。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/OpenCodeGoWebSessionDescriptor.swift Tests/TokenHealthTests/OpenCodeGoWebSessionDescriptorTests.swift
git commit -m "$(cat <<'EOF'
Fetch the console usage payloads from the web session script

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 3: 详情构建与接线

### Task 6: `DetailSeries.emptyText`

**Files:**
- Modify: `Sources/TokenHealth/UsageDetail.swift:34-39`
- Modify: `Sources/TokenHealth/DetailPopoverView.swift:116-119`
- Modify: `Sources/TokenHealth/DeepSeekUsageDetail.swift:124-129`
- Test: `Tests/TokenHealthTests/DetailPopoverRenderTests.swift:31`、`:69-79`

- [ ] **Step 1: 改模型**

`DetailSeries` 替换为：

```swift
struct DetailSeries: Equatable, Sendable {
    var title: String
    var points: [DetailSeriesPoint]
    var axisStart: String
    var axisEnd: String
    /// 全零时视图要显示的那句话：文案随数据来源不同（「本月」或「最近 30 天」），由填充方给。
    var emptyText: String
}
```

- [ ] **Step 2: 改视图**

`DetailPopoverView.swift` 的：

```swift
                if DetailSeriesChart.maximum(of: series.points) == 0 {
                    Text("No usage this month")
```

替换为：

```swift
                if DetailSeriesChart.maximum(of: series.points) == 0 {
                    Text(series.emptyText)
```

- [ ] **Step 3: DeepSeek 传入原文案**

`DeepSeekUsageDetail.swift` 的 `DetailSeries(...)` 补一行（其余字段不动）：

```swift
            axisEnd: daysInRange.last.map { formatter.string(from: $0) } ?? "",
            emptyText: "No usage this month"
        )
```

- [ ] **Step 4: 渲染测试补字段**

`DetailPopoverRenderTests.swift` 两处：

```swift
            series: DetailSeries(title: "Tokens this month", points: points, axisStart: "9/1", axisEnd: "9/24", emptyText: "No usage this month")
```

```swift
                axisStart: "9/1",
                axisEnd: "9/24",
                emptyText: "No usage this month"
            ),
```

- [ ] **Step 5: 跑测试**

Run: `bash scripts/test.sh`
Expected: PASS（DeepSeek 的显示文案逐字未变）。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/UsageDetail.swift Sources/TokenHealth/DetailPopoverView.swift Sources/TokenHealth/DeepSeekUsageDetail.swift Tests/TokenHealthTests/DetailPopoverRenderTests.swift
git commit -m "$(cat <<'EOF'
Let the detail series carry its own empty-state copy

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 7: `OpenCodeGoUsageDetail`（信封 → `UsageDetail`）

**Files:**
- Create: `Sources/TokenHealth/OpenCodeGoUsageDetail.swift`
- Test: `Tests/TokenHealthTests/OpenCodeGoUsageDetailTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/TokenHealthTests/OpenCodeGoUsageDetailTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

@Suite
struct OpenCodeGoUsageDetailTests {
    /// 2026-09-25T00:00:00Z —— 30 天窗口是 8/27 … 9/25。
    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    private var usages: [TokenUsage] {
        [
            TokenUsage(window: .fiveHours, used: 32_000_000, limit: 1_200_000_000, resetDate: nil, unit: nil, displayValue: "$0.32 / $12.00"),
            TokenUsage(window: .week, used: 95_000_000, limit: 3_000_000_000, resetDate: nil, unit: nil, displayValue: "$0.95 / $30.00"),
            TokenUsage(window: .month, used: 222_000_000, limit: 6_000_000_000, resetDate: nil, unit: nil, displayValue: "$2.22 / $60.00")
        ]
    }

    private func bundle(
        summary: String? = #"{"totalRequests":902,"totalInputTokens":44000000,"totalOutputTokens":9000000,"totalCacheReadTokens":33000000,"totalCacheWrite5mTokens":1500000,"totalCacheWrite1hTokens":500000,"totalCostMicroCents":1986000000}"#,
        byDay: String? = Self.byDayJSON,
        models: String? = Self.modelsJSON
    ) -> Data {
        var object: [String: Any] = ["goStatus": ["access": ["meters": [:] as [String: Any]]]]
        if let summary { object["usageSummary"] = try! JSONSerialization.jsonObject(with: Data(summary.utf8)) }
        if let byDay { object["usageByDay"] = try! JSONSerialization.jsonObject(with: Data(byDay.utf8)) }
        if let models { object["usageModels"] = try! JSONSerialization.jsonObject(with: Data(models.utf8)) }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static let byDayJSON = """
    [
      {"date":"2026-09-25","totalRequests":12,"totalTokens":1200000,"totalCostMicroCents":41000000},
      {"date":"2026-09-25","totalRequests":1,"totalTokens":100000,"totalCostMicroCents":1000000},
      {"date":"2026-09-24","totalRequests":10,"totalTokens":1000000,"totalCostMicroCents":30000000},
      {"date":"2026-09-20","totalRequests":8,"totalTokens":800000,"totalCostMicroCents":20000000},
      {"date":"2026-09-19","totalRequests":7,"totalTokens":700000,"totalCostMicroCents":10000000},
      {"date":"2026-09-18","totalRequests":6,"totalTokens":600000,"totalCostMicroCents":5000000},
      {"date":"2026-08-27","totalRequests":5,"totalTokens":500000,"totalCostMicroCents":4000000},
      {"date":"2026-08-26","totalRequests":99,"totalTokens":9900000,"totalCostMicroCents":99000000},
      {"date":"2026-09-26","totalRequests":99,"totalTokens":9900000,"totalCostMicroCents":99000000}
    ]
    """

    private static let modelsJSON = """
    {
      "items": [
        {"model":"claude-sonnet-5","provider":"anthropic","totalRequests":402,"totalInputTokens":20000000,"totalOutputTokens":3000000,"totalCacheReadTokens":18000000,"totalCacheWrite5mTokens":100000,"totalCacheWrite1hTokens":100000,"totalCostMicroCents":819000000},
        {"model":"kimi-k2.5","provider":"opencode","totalRequests":310,"totalInputTokens":15000000,"totalOutputTokens":2000000,"totalCacheReadTokens":13000000,"totalCacheWrite5mTokens":50000,"totalCacheWrite1hTokens":50000,"totalCostMicroCents":602000000},
        {"model":"kimi-k2.5","provider":"moonshot","totalRequests":30,"totalInputTokens":500000,"totalOutputTokens":50000,"totalCacheReadTokens":50000,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":1000000},
        {"model":"","provider":"opencode","totalRequests":9,"totalInputTokens":90000,"totalOutputTokens":9000,"totalCacheReadTokens":1000,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":30000000},
        {"model":"free-model","provider":"opencode","totalRequests":4,"totalInputTokens":1000,"totalOutputTokens":0,"totalCacheReadTokens":0,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":0},
        {"model":"zero-model","provider":"opencode","totalRequests":0,"totalInputTokens":0,"totalOutputTokens":0,"totalCacheReadTokens":0,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":0}
      ],
      "pageInfo": {"page":1,"pageSize":100,"total":6,"pageCount":1}
    }
    """

    @Test
    func buildsHeadlineFromTheSnapshotsUsages() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))

        #expect(detail.headline.map(\.label) == ["5 hours", "Week", "Month"])
        #expect(detail.headline.map(\.value) == ["$0.32 / $12.00", "$0.95 / $30.00", "$2.22 / $60.00"])
    }

    @Test
    func headlinesSkipWindowsThatAreNotInTheSnapshot() throws {
        let onlyWeek = [TokenUsage(window: .week, used: 1, limit: 2, resetDate: nil, unit: nil, displayValue: "$0.01 / $0.02")]
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: onlyWeek, today: today))

        #expect(detail.headline.map(\.label) == ["Week"])
    }

    @Test
    func groupsSumTodaySevenAndThirtyDays() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))

        // Duplicate 9/25 rows sum; 8/26 and 9/26 fall outside the window and are dropped.
        #expect(detail.groups.map(\.title) == ["Today", "7 days", "30 days"])
        #expect(detail.groups[0].values.map(\.value) == ["13", "1.3M", "$0.42"])
        #expect(detail.groups[1].values.map(\.value) == ["38", "3.8M", "$1.02"])
        #expect(detail.groups[2].values.map(\.value) == ["49", "4.9M", "$1.11"])
        #expect(detail.groups[0].values.map(\.label) == ["Requests", "Tokens", "Cost"])
    }

    @Test
    func seriesCoversThirtyDaysEndingToday() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))
        let series = try #require(detail.series)

        #expect(series.points.count == 30)
        #expect(series.title == "Cost · last 30 days")
        #expect(series.emptyText == "No usage in the last 30 days")
        #expect(series.axisStart == "8/27")
        #expect(series.axisEnd == "9/25")
        // First point is 8/27 ($0.04); the 8/26 row must not leak into it.
        #expect(series.points.first?.value == 0.04)
        #expect(series.points.last?.value == 0.42)
        // 9/21..9/23 have no rows and are zero-filled.
        #expect(series.points.filter { $0.value == 0 }.count == 30 - 6)
    }

    @Test
    func breakdownSumsBothCacheWriteWindows() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))

        #expect(detail.breakdown.map(\.label) == ["Input", "Output", "Cache read", "Cache write"])
        #expect(detail.breakdown.map(\.value) == ["44M", "9M", "33M", "2M"])
    }

    @Test
    func tableMergesModelsDropsEmptyRowsAndSortsByCost() throws {
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(), usages: usages, today: today))
        let table = try #require(detail.table)

        #expect(table.title == "By model · last 30 days")
        #expect(table.columns == ["Model", "Requests", "Tokens", "Cost"])
        // kimi-k2.5 appears twice (two providers) and must be one row; zero-model is dropped.
        #expect(table.rows.map(\.name) == ["claude-sonnet-5", "kimi-k2.5", "Unknown model", "free-model"])
        #expect(table.rows[0].cells == ["402", "41.2M", "$8.19"])
        #expect(table.rows[1].cells == ["340", "30.7M", "$6.03"])
        #expect(table.footnote == nil)
    }

    @Test
    func tableTruncatesToSixRowsAndCountsTheRest() throws {
        let items = (0..<8).map { index in
            """
            {"model":"model-\(index)","provider":"opencode","totalRequests":1,"totalInputTokens":1000,"totalOutputTokens":0,"totalCacheReadTokens":0,"totalCacheWrite5mTokens":0,"totalCacheWrite1hTokens":0,"totalCostMicroCents":\(100_000_000 - index * 1_000_000)}
            """
        }
        let models = "{\"items\":[\(items.joined(separator: ","))]}"
        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle(models: models), usages: usages, today: today))
        let table = try #require(detail.table)

        #expect(table.rows.count == 6)
        #expect(table.rows.first?.name == "model-0")
        #expect(table.footnote == "+2 more models")
    }

    @Test
    func missingUsageKeysLeaveTheSectionsOut() throws {
        let detail = try #require(
            OpenCodeGoUsageDetail.make(bundle: bundle(summary: nil, byDay: nil, models: nil), usages: usages, today: today)
        )

        #expect(detail.headline.count == 3)
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.table == nil)
    }

    @Test
    func anEmptyThirtyDaysStillDrawsZeros() throws {
        let detail = try #require(
            OpenCodeGoUsageDetail.make(bundle: bundle(summary: #"{}"#, byDay: "[]", models: #"{"items":[]}"#), usages: usages, today: today)
        )

        #expect(detail.groups[2].values.map(\.value) == ["0", "0", "$0.00"])
        #expect(detail.series?.points.allSatisfy { $0.value == 0 } == true)
        #expect(detail.breakdown.map(\.value) == ["0", "0", "0", "0"])
        #expect(detail.table == nil)
    }

    @Test
    func noMetersAndNoUsageMeansNoDetail() {
        #expect(OpenCodeGoUsageDetail.make(bundle: bundle(summary: nil, byDay: nil, models: nil), usages: [], today: today) == nil)
    }

    @Test
    func garbageBundleMeansNoDetail() {
        #expect(OpenCodeGoUsageDetail.make(bundle: Data("not json".utf8), usages: usages, today: today) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter OpenCodeGoUsageDetailTests`
Expected: FAIL —— `OpenCodeGoUsageDetail` 未定义（编译错误）。

- [ ] **Step 3: 实现**

新建 `Sources/TokenHealth/OpenCodeGoUsageDetail.swift`：

```swift
import Foundation

/// Turns one console envelope into the `UsageDetail` the pinned-item popover draws.
///
/// Never throws: an unparseable envelope returns nil and the popover falls back to its error
/// line. A single failed console call only removes that section — the meters still render.
enum OpenCodeGoUsageDetail {
    static let tableRowLimit = 6
    static let unknownModelName = "Unknown model"
    static let dayFormat = "yyyy-MM-dd"
    static let axisDateFormat = "M/d"
    static let rangeDays = 30

    /// Headline rows, in window order. Labels are the card's copy, not `UsageWindow.title`.
    static let windowLabels: [(window: UsageWindow, label: String)] = [
        (.fiveHours, "5 hours"),
        (.week, "Week"),
        (.month, "Month")
    ]

    private struct Totals: Equatable {
        var requests = 0
        var tokens = 0
        var costMicroCents = 0

        mutating func add(_ other: Totals) {
            requests += other.requests
            tokens += other.tokens
            costMicroCents += other.costMicroCents
        }
    }

    static func make(bundle: Data, usages: [TokenUsage], today: Date) -> UsageDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: bundle) as? [String: Any] else {
            return nil
        }

        var detail = UsageDetail()
        detail.headline = headline(from: usages)

        let calendar = utcCalendar()
        let dayRange = dayList(today: today, calendar: calendar)
        if let rows = root["usageByDay"] as? [[String: Any]], !dayRange.isEmpty {
            let byDay = dayTotals(from: rows, allowed: Set(dayRange), calendar: calendar)
            detail.groups = groups(dayRange: dayRange, byDay: byDay)
            detail.series = series(dayRange: dayRange, byDay: byDay, calendar: calendar)
        }
        if let summary = root["usageSummary"] as? [String: Any] {
            detail.breakdown = breakdown(summary)
        }
        if let models = root["usageModels"] as? [String: Any],
           let items = models["items"] as? [[String: Any]] {
            detail.table = table(items)
        }

        return detail.isEmpty ? nil : detail
    }

    // MARK: - headline

    private static func headline(from usages: [TokenUsage]) -> [DetailStat] {
        windowLabels.compactMap { window, label in
            guard let usage = usages.first(where: { $0.window == window }),
                  let value = usage.displayValue, !value.isEmpty else {
                return nil
            }
            return DetailStat(label: label, value: value)
        }
    }

    // MARK: - groups

    private static func groups(dayRange: [Date], byDay: [Date: Totals]) -> [DetailGroup] {
        guard let today = dayRange.last else {
            return []
        }

        let todayTotals = byDay[today] ?? Totals()
        var last7 = Totals()
        var last30 = Totals()
        for (index, date) in dayRange.enumerated() {
            let totals = byDay[date] ?? Totals()
            last30.add(totals)
            if index >= dayRange.count - 7 {
                last7.add(totals)
            }
        }

        return [
            DetailGroup(title: "Today", values: values(todayTotals)),
            DetailGroup(title: "7 days", values: values(last7)),
            DetailGroup(title: "30 days", values: values(last30))
        ]
    }

    private static func values(_ totals: Totals) -> [DetailStat] {
        [
            DetailStat(label: "Requests", value: UsageAmountFormatter.compactAmount(totals.requests)),
            DetailStat(label: "Tokens", value: UsageAmountFormatter.compactAmount(totals.tokens)),
            DetailStat(label: "Cost", value: OpenCodeGoUsageParser.dollarsText(totals.costMicroCents))
        ]
    }

    // MARK: - series

    private static func series(dayRange: [Date], byDay: [Date: Totals], calendar: Calendar) -> DetailSeries {
        let points = dayRange.map { date in
            DetailSeriesPoint(date: date, value: OpenCodeGoUsageParser.dollars(byDay[date]?.costMicroCents ?? 0))
        }
        let formatter = axisDateFormatter(calendar: calendar)
        return DetailSeries(
            title: "Cost · last 30 days",
            points: points,
            axisStart: dayRange.first.map { formatter.string(from: $0) } ?? "",
            axisEnd: dayRange.last.map { formatter.string(from: $0) } ?? "",
            emptyText: "No usage in the last 30 days"
        )
    }

    // MARK: - breakdown

    private static func breakdown(_ summary: [String: Any]) -> [DetailStat] {
        let cacheWrite = intValue(summary["totalCacheWrite5mTokens"]) ?? 0
        let cacheWriteLong = intValue(summary["totalCacheWrite1hTokens"]) ?? 0
        return [
            DetailStat(label: "Input", value: UsageAmountFormatter.compactAmount(intValue(summary["totalInputTokens"]) ?? 0)),
            DetailStat(label: "Output", value: UsageAmountFormatter.compactAmount(intValue(summary["totalOutputTokens"]) ?? 0)),
            DetailStat(label: "Cache read", value: UsageAmountFormatter.compactAmount(intValue(summary["totalCacheReadTokens"]) ?? 0)),
            DetailStat(label: "Cache write", value: UsageAmountFormatter.compactAmount(cacheWrite + cacheWriteLong))
        ]
    }

    // MARK: - table

    private static func table(_ items: [[String: Any]]) -> DetailTable? {
        var byModel: [String: Totals] = [:]
        for item in items {
            var totals = byModel[modelName(from: item)] ?? Totals()
            totals.requests += intValue(item["totalRequests"]) ?? 0
            totals.tokens += tokens(in: item)
            totals.costMicroCents += intValue(item["totalCostMicroCents"]) ?? 0
            byModel[modelName(from: item)] = totals
        }

        // Rows with neither tokens nor cost are dropped: they would eat one of the six slots and
        // inflate the footnote count.
        let rows = byModel
            .filter { $0.value.tokens > 0 || $0.value.costMicroCents > 0 }
            .sorted { lhs, rhs in
                lhs.value.costMicroCents == rhs.value.costMicroCents
                    ? lhs.key < rhs.key
                    : lhs.value.costMicroCents > rhs.value.costMicroCents
            }
        guard !rows.isEmpty else {
            return nil
        }

        let shown = rows.prefix(tableRowLimit)
        let hidden = rows.count - shown.count
        return DetailTable(
            title: "By model · last 30 days",
            columns: ["Model", "Requests", "Tokens", "Cost"],
            rows: shown.map { name, totals in
                DetailTableRow(
                    name: name,
                    cells: [
                        UsageAmountFormatter.compactAmount(totals.requests),
                        UsageAmountFormatter.compactAmount(totals.tokens),
                        OpenCodeGoUsageParser.dollarsText(totals.costMicroCents)
                    ]
                )
            },
            footnote: hidden > 0 ? "+\(hidden) more models" : nil
        )
    }

    /// The console has no total field: tokens are the sum of the five components, matching the
    /// console's own `totalTokens` getter.
    private static func tokens(in item: [String: Any]) -> Int {
        [
            "totalInputTokens",
            "totalOutputTokens",
            "totalCacheReadTokens",
            "totalCacheWrite5mTokens",
            "totalCacheWrite1hTokens"
        ].reduce(0) { $0 + (intValue(item[$1]) ?? 0) }
    }

    private static func modelName(from item: [String: Any]) -> String {
        guard let name = item["model"] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return unknownModelName
        }
        return name
    }

    // MARK: - 聚合与日期

    private static func dayTotals(
        from rows: [[String: Any]],
        allowed: Set<Date>,
        calendar: Calendar
    ) -> [Date: Totals] {
        var byDay: [Date: Totals] = [:]
        for row in rows {
            guard let date = date(fromDay: row["date"], calendar: calendar), allowed.contains(date) else {
                continue
            }
            var totals = byDay[date] ?? Totals()
            totals.requests += intValue(row["totalRequests"]) ?? 0
            totals.tokens += intValue(row["totalTokens"]) ?? 0
            totals.costMicroCents += intValue(row["totalCostMicroCents"]) ?? 0
            byDay[date] = totals
        }
        return byDay
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
    private static func date(fromDay value: Any?, calendar: Calendar) -> Date? {
        guard let text = value as? String, text.count >= 10 else {
            return nil
        }
        return dateFormatter(calendar: calendar).date(from: String(text.prefix(10)))
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

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `bash scripts/test.sh --filter OpenCodeGoUsageDetailTests`
Expected: PASS。再跑全量 `bash scripts/test.sh`。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/OpenCodeGoUsageDetail.swift Tests/TokenHealthTests/OpenCodeGoUsageDetailTests.swift
git commit -m "$(cat <<'EOF'
Build the OpenCode Go usage detail from the console envelope

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 8: 接线（快照注入点 + 浮层门槛）

**Files:**
- Modify: `Sources/TokenHealth/OpenCodeGoUsageProvider.swift`（`fetchConsoleUsage` 收口到新的 `consoleSnapshot`）
- Modify: `Sources/TokenHealth/Providers.swift:17-24`
- Test: `Tests/TokenHealthTests/OpenCodeGoDetailWiringTests.swift`（新建）、`Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift`

- [ ] **Step 1: 写失败的接线测试**

新建 `Tests/TokenHealthTests/OpenCodeGoDetailWiringTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct OpenCodeGoDetailWiringTests {
    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
    }

    private func config(auth: AuthMode) -> ServiceConfig {
        ServiceConfig(displayName: "OpenCode Go", providerKind: .openCodeGo, authMode: auth)
    }

    /// 一份完整的信封：新形状额度 + 三份用量响应。
    private var bundle: Data {
        Data(#"""
        {
          "ok": true, "status": 200, "text": "", "hasSession": true,
          "goStatus": { "access": { "endsAt": "2026-10-01T00:00:00.000Z", "meters": {
            "fiveHour": { "limitMicroCents": 1200000000, "usedMicroCents": 32000000 },
            "week": { "limitMicroCents": 3000000000, "usedMicroCents": 95000000 },
            "month": { "limitMicroCents": 6000000000, "usedMicroCents": 222000000 }
          } } },
          "workspaceId": "wrk_1",
          "usageSummary": { "totalInputTokens": 44000000, "totalOutputTokens": 9000000, "totalCacheReadTokens": 33000000, "totalCacheWrite5mTokens": 1500000, "totalCacheWrite1hTokens": 500000, "totalCostMicroCents": 1986000000 },
          "usageByDay": [ { "date": "2026-09-25", "totalRequests": 12, "totalTokens": 1200000, "totalCostMicroCents": 41000000 } ],
          "usageModels": { "items": [ { "model": "claude-sonnet-5", "provider": "anthropic", "totalRequests": 402, "totalInputTokens": 20000000, "totalOutputTokens": 3000000, "totalCacheReadTokens": 18000000, "totalCacheWrite5mTokens": 100000, "totalCacheWrite1hTokens": 100000, "totalCostMicroCents": 819000000 } ] }
        }
        """#.utf8)
    }

    @Test
    func aConsoleEnvelopeProducesAReadySnapshotWithDetail() throws {
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundle,
            accountName: "blues",
            today: today
        )

        #expect(snapshot.state == .ready)
        // The access.meters shape carries no price, so the parser pins the plan name to "Go";
        // accountName is only the fallback for shapes that have no plan name at all.
        #expect(snapshot.planName == "Go")
        #expect(snapshot.usages.map(\.window) == [.fiveHours, .week, .month])

        let detail = try #require(snapshot.detail)
        #expect(detail.headline.map(\.value) == ["$0.32 / $12.00", "$0.95 / $30.00", "$2.22 / $60.00"])
        #expect(detail.series?.points.count == 30)
    }

    @Test
    func headlineMatchesTheSnapshotsQuotaUsages() throws {
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: bundle,
            accountName: nil,
            today: today
        )

        let quota = snapshot.usages.filter { [.fiveHours, .week, .month].contains($0.window) }
        let detail = try #require(snapshot.detail)
        #expect(detail.headline.count == quota.count, "headline 就是那三条额度，不该另解析一遍")
        #expect(detail.headline.map(\.value) == quota.compactMap(\.displayValue))
    }

    @Test
    func aMalformedEnvelopeStillYieldsAnUnavailableSnapshot() {
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: Data("not json".utf8),
            accountName: nil,
            today: today
        )

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.detail == nil)
    }

    @Test
    func usageSectionsAreAbsentWhenTheApiKeysAreMissing() throws {
        let metersOnly = Data(#"{"ok":true,"goStatus":{"access":{"meters":{"fiveHour":{"limitMicroCents":1200000000,"usedMicroCents":32000000}}}}}"#.utf8)
        let snapshot = OpenCodeGoUsageProvider().consoleSnapshot(
            config: config(auth: .browserLogin),
            bundle: metersOnly,
            accountName: nil,
            today: today
        )

        #expect(snapshot.state == .ready)
        let detail = try #require(snapshot.detail)
        #expect(detail.headline.count == 1)
        #expect(detail.groups.isEmpty)
        #expect(detail.series == nil)
        #expect(detail.breakdown.isEmpty)
        #expect(detail.table == nil)
    }
}
```

同时把 `ProviderDetailCapabilityTests` 里 `everyOtherProviderIsUnsupported` 的过滤条件与新增用例改成：

```swift
    @Test
    func browserLoginOpenCodeGoProducesDetail() {
        #expect(ProviderFactory.producesUsageDetail(for: config(.openCodeGo, auth: .browserLogin)))
        #expect(
            !ProviderFactory.producesUsageDetail(for: config(.openCodeGo, auth: .api)),
            "API key 模式只有百分比与重置时间，撑不起卡片"
        )
    }

    @Test
    func everyOtherProviderIsUnsupported() {
        for kind in ProviderKind.allCases where kind != .deepSeek && kind != .openCodeGo {
            for auth in AuthMode.allCases {
                #expect(
                    !ProviderFactory.producesUsageDetail(for: config(kind, auth: auth)),
                    "\(kind) / \(auth) 不该被当成支持详情"
                )
            }
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter OpenCodeGoDetailWiringTests`
Expected: FAIL —— `consoleSnapshot` 未定义（编译错误）。

- [ ] **Step 3: 实现接入点**

`fetchConsoleUsage` 里把「解析 + 组装快照」那段（`let result = try OpenCodeGoUsageParser().parseBundle(data: bundleData)` 到返回快照的 `return ProviderUsageSnapshot(...)`）替换为一行：

```swift
            return consoleSnapshot(config: config, bundle: bundleData, accountName: session.accountName, today: Date())
```

并在 `fetchConsoleUsage` 之后新增：

```swift
    /// 把一次取回的信封变成快照。
    ///
    /// 抽出来是因为 `fetchUsage` 永远会打真实网络（失败还回落到 WebKit 会话），没有注入点 ——
    /// 拿合成信封测这一层，才不用去碰 console.opencode.ai。
    func consoleSnapshot(
        config: ServiceConfig,
        bundle: Data,
        accountName: String?,
        today: Date
    ) -> ProviderUsageSnapshot {
        do {
            let result = try OpenCodeGoUsageParser().parseBundle(data: bundle)
            guard !result.usages.isEmpty else {
                return ProviderUsageSnapshot.unavailable(
                    config: config,
                    message: result.subscriptionMessage ?? "No OpenCode Go usage found"
                )
            }
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: result.planName ?? accountName,
                usages: result.usages,
                detail: OpenCodeGoUsageDetail.make(bundle: bundle, usages: result.usages, today: today),
                state: .ready,
                statusMessage: "OpenCode Go API",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }
```

- [ ] **Step 4: 打开浮层门槛**

`Providers.swift` 的 `producesUsageDetail` 替换为：

```swift
    static func producesUsageDetail(for config: ServiceConfig) -> Bool {
        switch config.providerKind {
        case .deepSeek, .openCodeGo:
            config.authMode == .browserLogin
        default:
            false
        }
    }
```

（保留该函数上方已有的注释块；把其中「目前只有配置成登录模式的 DeepSeek 会」改成「目前是 DeepSeek 与 OpenCode Go」。）

- [ ] **Step 5: 跑测试确认全绿**

Run: `bash scripts/test.sh`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/OpenCodeGoUsageProvider.swift Sources/TokenHealth/Providers.swift Tests/TokenHealthTests/OpenCodeGoDetailWiringTests.swift Tests/TokenHealthTests/ProviderDetailCapabilityTests.swift
git commit -m "$(cat <<'EOF'
Feed the OpenCode Go detail into its snapshot

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 4: 验收

### Task 9: 构建、替换运行实例与截图 QA

**Files:**
- Modify: `AppSupport/Info.plist`（版本号，按仓库惯例 +1）

- [ ] **Step 1: 全量测试**

Run: `bash scripts/test.sh`
Expected: 全绿（基线 276 tests / 35 suites，本计划新增若干用例后只增不减）。

- [ ] **Step 2: 升版本号并构建**

按仓库惯例把 `AppSupport/Info.plist` 的 **`CFBundleShortVersionString` 与 `CFBundleVersion` 两个键都加一**（当前 `1.0.2` / `24` → `1.0.3` / `25`；历次发包提交都是两行一起改），然后：

Run: `bash scripts/build-app.sh`
Expected: 构建产物在 `.build/app`。

- [ ] **Step 3: 卡片离屏渲染截图（不需要凭据，先看版式）**

新建一个**临时**测试文件 `Tests/TokenHealthTests/ZZGoCardSnapshot.swift`（跑完删除、不提交），用合成信封渲染 `DetailPopoverView` 并把 PNG 写到 `/tmp/opencode-go-card.png`：

```swift
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TokenHealth

@MainActor
struct ZZGoCardSnapshot {
    @Test
    func writeTheGoCardToDisk() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!

        let usages = [
            TokenUsage(window: .fiveHours, used: 32_000_000, limit: 1_200_000_000, resetDate: nil, unit: nil, displayValue: "$0.32 / $12.00"),
            TokenUsage(window: .week, used: 95_000_000, limit: 3_000_000_000, resetDate: nil, unit: nil, displayValue: "$0.95 / $30.00"),
            TokenUsage(window: .month, used: 222_000_000, limit: 6_000_000_000, resetDate: nil, unit: nil, displayValue: "$2.22 / $60.00")
        ]
        let bundle = Data(#"""
        {
          "usageSummary": { "totalInputTokens": 44000000, "totalOutputTokens": 9000000, "totalCacheReadTokens": 33000000, "totalCacheWrite5mTokens": 1500000, "totalCacheWrite1hTokens": 500000, "totalCostMicroCents": 1986000000 },
          "usageByDay": [
            { "date": "2026-09-25", "totalRequests": 12, "totalTokens": 1200000, "totalCostMicroCents": 41000000 },
            { "date": "2026-09-24", "totalRequests": 10, "totalTokens": 1000000, "totalCostMicroCents": 30000000 },
            { "date": "2026-09-20", "totalRequests": 8, "totalTokens": 800000, "totalCostMicroCents": 20000000 },
            { "date": "2026-09-19", "totalRequests": 7, "totalTokens": 700000, "totalCostMicroCents": 10000000 },
            { "date": "2026-09-18", "totalRequests": 6, "totalTokens": 600000, "totalCostMicroCents": 5000000 },
            { "date": "2026-09-12", "totalRequests": 20, "totalTokens": 3000000, "totalCostMicroCents": 90000000 },
            { "date": "2026-09-05", "totalRequests": 14, "totalTokens": 2000000, "totalCostMicroCents": 60000000 },
            { "date": "2026-08-27", "totalRequests": 5, "totalTokens": 500000, "totalCostMicroCents": 4000000 }
          ],
          "usageModels": { "items": [
            { "model": "claude-sonnet-5", "provider": "anthropic", "totalRequests": 402, "totalInputTokens": 20000000, "totalOutputTokens": 3000000, "totalCacheReadTokens": 18000000, "totalCacheWrite5mTokens": 100000, "totalCacheWrite1hTokens": 100000, "totalCostMicroCents": 819000000 },
            { "model": "kimi-k2.5", "provider": "opencode", "totalRequests": 310, "totalInputTokens": 15000000, "totalOutputTokens": 2000000, "totalCacheReadTokens": 13000000, "totalCacheWrite5mTokens": 50000, "totalCacheWrite1hTokens": 50000, "totalCostMicroCents": 602000000 },
            { "model": "glm-5.1", "provider": "opencode", "totalRequests": 190, "totalInputTokens": 8000000, "totalOutputTokens": 1000000, "totalCacheReadTokens": 7000000, "totalCacheWrite5mTokens": 50000, "totalCacheWrite1hTokens": 50000, "totalCostMicroCents": 365000000 },
            { "model": "deepseek-v4-flash", "provider": "opencode", "totalRequests": 120, "totalInputTokens": 4000000, "totalOutputTokens": 500000, "totalCacheReadTokens": 3000000, "totalCacheWrite5mTokens": 20000, "totalCacheWrite1hTokens": 20000, "totalCostMicroCents": 120000000 },
            { "model": "minimax-m2.5", "provider": "opencode", "totalRequests": 90, "totalInputTokens": 2000000, "totalOutputTokens": 200000, "totalCacheReadTokens": 1000000, "totalCacheWrite5mTokens": 10000, "totalCacheWrite1hTokens": 10000, "totalCostMicroCents": 60000000 },
            { "model": "qwen3.7-plus", "provider": "opencode", "totalRequests": 60, "totalInputTokens": 1000000, "totalOutputTokens": 100000, "totalCacheReadTokens": 500000, "totalCacheWrite5mTokens": 5000, "totalCacheWrite1hTokens": 5000, "totalCostMicroCents": 30000000 },
            { "model": "mimo-v2.5", "provider": "opencode", "totalRequests": 30, "totalInputTokens": 500000, "totalOutputTokens": 50000, "totalCacheReadTokens": 200000, "totalCacheWrite5mTokens": 2000, "totalCacheWrite1hTokens": 2000, "totalCostMicroCents": 10000000 }
          ] }
        }
        """#.utf8)

        let detail = try #require(OpenCodeGoUsageDetail.make(bundle: bundle, usages: usages, today: today))
        let renderer = ImageRenderer(
            content: DetailPopoverView(
                serviceName: "OpenCode Go",
                detail: detail,
                statusMessage: nil,
                updatedAt: Date(),
                onRefresh: {}, onUnpin: {}, onOpenSettings: {}, onQuit: {}
            )
        )
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/opencode-go-card.png"))
    }
}
```

Run: `bash scripts/test.sh --filter ZZGoCardSnapshot`
然后用 Read 工具打开 `/tmp/opencode-go-card.png` 核对版式：三额度行、三行汇总（列对齐）、柱状图与 `8/27` / `9/25` 轴标签、四个构成项、模型表 6 行 + `+1 more models`、底部三个按钮。核对完删除该临时文件。

- [ ] **Step 4: 替换本机运行实例**

```bash
osascript -e 'quit app "Token Health"' || true
pkill -x TokenHealth || true
sleep 1
rm -rf "/Applications/Token Health.app"
cp -R .build/app/"Token Health.app" /Applications/
plutil -extract CFBundleShortVersionString raw "/Applications/Token Health.app/Contents/Info.plist"
open -a "Token Health"
```

Expected: `plutil` 打印新版本号（1.0.3）。截图确认应用正常起来（菜单栏图标、设置窗口）：

```bash
screencapture -x /tmp/qa-01-installed.png
```

- [ ] **Step 5: 登录（如果账号还没有网页会话）**

Settings → 选中 OpenCode Go 账号 → Auth 切 **Login** → 「Login with OpenCode Go」→ 在弹窗里完成 GitHub/Google 登录 → 等控制台加载 → **Import Session**。
（这一步需要账号凭据，由人完成。成功的标志是设置里那条状态行变成 `OpenCode Go web session connected: <账号>`。）

- [ ] **Step 6: 浮层截图 QA**

点钉住的 OpenCode Go 菜单栏项，浮层保持打开的瞬间截图：

```bash
screencapture -x /tmp/qa-02-popover.png
```

逐项核对：三额度（`$已用 / $上限`）、Today / 7 days / 30 days 三行、`Cost · last 30 days` 柱状图、`Input/Output/Cache read/Cache write`、`By model · last 30 days` 表。若截图拿不到（TCC 屏幕录制权限），退回到让用户点开后自行截图人工核对。

补两条 spec §13 的边界人工检查：

- **API 模式仍走小菜单**：把同一个账号的 Auth 切回 API（或钉住另一个 API 模式的 Go 账号）→ 点菜单栏项 → 应弹原来的 Unpin / Settings / Quit 小菜单，不是浮层。
- **失败保留旧数据**：断开网络 → 在浮层里点 Refresh → 数字保留、顶部出现红色错误行，菜单栏项**不**退回小菜单。

- [ ] **Step 7: 数字对账**

把浮层三额度的 `已用 ÷ 上限` 与 console Go 页的百分比对照（应一致）；把 30 天合计与 `opencode.ai/console/<wrk>/usage` 页面对照（滚动 30 天，UTC）。

- [ ] **Step 8: 提交**

```bash
git add AppSupport/Info.plist
git commit -m "$(cat <<'EOF'
Cut the next release as 1.0.3

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## 已知风险

- **金额标度**以 console 自身的定价常量为准（spec §2）。若实机发现三额度金额仍与 console 百分比不符，先复核 `dollarsText` 的除数（这是唯一改错会放大的地方）。
- **个人 workspace 可能没有 Go 订阅**：此时卡片走"未订阅"文案；换 workspace 探测上限 5 个。
- **`/api/usage/*` 对个人 Go 工作区是否有数据**未在实现前实测（模拟登录后才能验证）。若返回空数组，卡片仍能画出全 0 的三行汇总与空趋势图；若 404/400，则这三个区块整体缺席，只有额度——按 §10 的降级规则处理，不改设计。
- **截图 QA 依赖 TCC 权限**：`screencapture` 需要屏幕录制权限、AppleScript 点菜单栏项需要辅助功能权限。拿不到就退回到「离屏渲染截图 + 人工点开核对」。
