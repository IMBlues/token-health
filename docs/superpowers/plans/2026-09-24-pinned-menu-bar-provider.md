# 钉住 Provider 的独立菜单栏项 实现计划

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在菜单栏上新增一个独立状态项，显示某个被钉住账号的「官方 logo + 每个额度窗口一根细竖条」，DeepSeek 退化为换算后的金额。

**Architecture:** 所有可验证的逻辑放进三个纯计算单元（`ExchangeRateTable` / `MenuBarMetrics` / `MenuBarItemLayout`），AppKit 只出现在最外层的 `MenuBarItemRenderer` 与 `PinnedStatusItemController`。`AppState` 新增 pin 与汇率状态，控制器订阅它并驱动重绘。图标走 SwiftPM 资源包，由脚本从 lobehub 图标库抓取并转成矢量 PDF。

**Tech Stack:** Swift 6、SwiftPM（macOS 14+）、SwiftUI + AppKit（`NSStatusItem`）、swift-testing、`rsvg-convert`（构建期一次性使用）。

**Spec:** `docs/superpowers/specs/2026-09-24-pinned-menu-bar-provider-design.md`

---

## 前置约束

- **本机没有 Xcode**，`swift test` 必须带 CommandLineTools 的 `Testing.framework` 路径。Chunk 1 的第一个任务会把这个包装成 `scripts/test.sh`，之后所有步骤统一用 `bash scripts/test.sh`。
- **工作区里还有另一个会话（「上次刷新时间显示」）的未提交改动**，位于 `AppState.swift` / `ConfigStore.swift` / `SettingsView.swift` / `StatusMenuView.swift` / `README.md` / `StatusMenuSummaryTests.swift`，另有新增文件 `Tests/TokenHealthTests/RefreshIntervalTests.swift`。本计划**在其之上**开发，绝不回滚这些改动。执行前先把它们单独提一个 commit（Task 0）。
- 所有 commit message 结尾必须带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 当前分支是 `main`，先切一个特性分支。

## 文件结构

**新增源码**

| 文件 | 职责 |
| --- | --- |
| `Sources/TokenHealth/ExchangeRateTable.swift` | 纯值类型：汇率表 + 换算数学 |
| `Sources/TokenHealth/ExchangeRateStore.swift` | 汇率抓取、缓存、回退（含 `ExchangeRateFetching` 协议） |
| `Sources/TokenHealth/UsageMetricSelection.swift` | 额度指标的判定与排序（卡片与菜单栏项共用） |
| `Sources/TokenHealth/MenuBarMetrics.swift` | 快照 → 有序指标列表（含 DeepSeek 金额换算） |
| `Sources/TokenHealth/MenuBarItemLayout.swift` | 纯几何：图标与竖条的位置与高度 |
| `Sources/TokenHealth/MenuBarItemRenderer.swift` | 依布局把 `NSImage` 画出来 |
| `Sources/TokenHealth/ProviderIcon.swift` | ProviderKind → logo 资源 / SF Symbol 兜底 |
| `Sources/TokenHealth/PinnedStatusItemController.swift` | 拥有 `NSStatusItem`，订阅状态、重绘、弹菜单 |

**新增资源与脚本**

| 文件 | 职责 |
| --- | --- |
| `scripts/fetch-provider-icons.sh` | 抓 logo、转 PDF、写进资源目录 |
| `scripts/test.sh` | 包掉 CLT framework 参数 |
| `Sources/TokenHealth/Resources/ProviderIcons/*.pdf` | 10 个品牌矢量 logo |

**修改**

| 文件 | 改动 |
| --- | --- |
| `Package.swift` | target 加 `resources: [.process("Resources")]` |
| `scripts/build-app.sh` | 把 `TokenHealth_TokenHealth.bundle` 拷进 `Contents/Resources/`，缺失即失败 |
| `Sources/TokenHealth/Models.swift` | `TokenUsage.amount`；`ServiceConfig.displayCurrency` |
| `Sources/TokenHealth/DeepSeekUsageProvider.swift` | 解析时填 `amount` |
| `Sources/TokenHealth/ConfigStore.swift` | pin 与汇率两个键的读写 |
| `Sources/TokenHealth/AppState.swift` | `pinnedConfigID`、`exchangeRate`、删除清理、刷新汇率 |
| `Sources/TokenHealth/StatusMenuView.swift` | 私有排序逻辑改为调用 `UsageMetricSelection` |
| `Sources/TokenHealth/SettingsView.swift` | 图标改为走 `ProviderIcon`；新增 Menu Bar 分区 |
| `Sources/TokenHealth/TokenHealthApp.swift` | 创建并启动控制器 |
| `AppSupport/Info.plist` | 版本号 |
| `README.md` | 使用说明 |

---

## Chunk 1: 纯逻辑（无 AppKit、无网络）

### Task 0: 建立分支并安顿并行会话的改动

**Files:**
- 无代码改动

- [ ] **Step 1: 确认工作区状态与分支**

Run:
```bash
git status --porcelain && git branch --show-current
```
Expected: 6 个 `M` 文件 + 1 个 `??`（`Tests/TokenHealthTests/RefreshIntervalTests.swift`），分支为 `main`。

- [ ] **Step 2: 把并行会话的改动单独提交**

这是另一个会话未提交的完整改动（刷新间隔设置 + 上次刷新时间显示），先行落盘，避免混进本次的特性提交。

```bash
git add README.md Sources/TokenHealth/AppState.swift Sources/TokenHealth/ConfigStore.swift \
        Sources/TokenHealth/SettingsView.swift Sources/TokenHealth/StatusMenuView.swift \
        Tests/TokenHealthTests/StatusMenuSummaryTests.swift Tests/TokenHealthTests/RefreshIntervalTests.swift
git commit -m "$(cat <<'EOF'
Add a configurable refresh interval and last-refresh age

The menu header now shows how long ago the last refresh finished, and the
interval moves from a constant into General settings with a 30 second floor.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```
Expected: 提交成功，`git status --porcelain` 为空。

- [ ] **Step 3: 切特性分支**

```bash
git switch -c feature/pinned-menu-bar-provider
```
Expected: `Switched to a new branch 'feature/pinned-menu-bar-provider'`

- [ ] **Step 4: 确认既有测试基线是绿的**

先把测试包装脚本写出来，否则后面每一步都要手打一长串参数。

创建 `scripts/test.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

# 本机只装了 CommandLineTools，没有 Xcode：swift-testing 的 Testing.framework
# 不在 SwiftPM 默认搜索路径里，必须显式喂进去，否则连既有测试都编译不过。
if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
  echo "Testing.framework not found at $FRAMEWORKS" >&2
  exit 1
fi

cd "$ROOT"
exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$@"
```

Run:
```bash
chmod +x scripts/test.sh && bash scripts/test.sh 2>&1 | tail -20
```
Expected: 全部通过。若有失败先停下来弄清楚，不要在红基线上开工。

- [ ] **Step 5: 提交**

```bash
git add scripts/test.sh
git commit -m "$(cat <<'EOF'
Add a test script that supplies the CommandLineTools Testing.framework

This Mac has no Xcode, so plain `swift test` cannot find swift-testing's
Testing.framework and fails to compile even the existing tests.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 1: ExchangeRateTable

**Files:**
- Create: `Sources/TokenHealth/ExchangeRateTable.swift`
- Test: `Tests/TokenHealthTests/ExchangeRateTableTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/ExchangeRateTableTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct ExchangeRateTableTests {
    private let table = ExchangeRateTable(
        base: "USD",
        rates: ["CNY": 6.7074],
        fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
        origin: .live
    )

    @Test
    func convertsAcrossTheBaseCurrency() {
        #expect(table.convert(100, from: "USD", to: "CNY") == Decimal(string: "670.74"))
        #expect(table.convert(Decimal(string: "670.74")!, from: "CNY", to: "USD")?.rounded(2) == Decimal(string: "100"))
    }

    @Test
    func convertingToTheSameCurrencyIsIdentity() {
        #expect(table.convert(12.34, from: "CNY", to: "cny") == Decimal(string: "12.34"))
        #expect(table.convert(12.34, from: "USD", to: "USD") == Decimal(string: "12.34"))
    }

    @Test
    func returnsNilForUnknownCurrencies() {
        #expect(table.convert(10, from: "USD", to: "EUR") == nil)
        #expect(table.convert(10, from: "JPY", to: "CNY") == nil)
        #expect(table.rate(from: "USD", to: "EUR") == nil)
    }

    @Test
    func rejectsNonPositiveRates() {
        let zeroed = ExchangeRateTable(base: "USD", rates: ["CNY": 0], fetchedAt: Date(), origin: .live)
        #expect(zeroed.convert(10, from: "USD", to: "CNY") == nil)

        let negative = ExchangeRateTable(base: "USD", rates: ["CNY": -7], fetchedAt: Date(), origin: .live)
        #expect(negative.convert(10, from: "USD", to: "CNY") == nil)
    }

    @Test
    func fallbackShipsAFixedRate() {
        #expect(ExchangeRateTable.fallback.origin == .fallback)
        #expect(ExchangeRateTable.fallback.rate(from: "USD", to: "CNY") == 7.2)
    }

    @Test
    func decodesOlderPayloadsThatOmitFields() throws {
        let json = Data(#"{"rates":{"CNY":7.1}}"#.utf8)
        let decoded = try JSONDecoder().decode(ExchangeRateTable.self, from: json)
        #expect(decoded.base == "USD")
        #expect(decoded.origin == .cache)
        #expect(decoded.rates == ["CNY": 7.1])
    }
}
```

`Decimal.rounded(2)` 是测试里用的辅助方法，加在同一个文件末尾的 `private` 扩展里：

```swift
private extension Decimal {
    func rounded(_ places: Int) -> Decimal {
        var input = self
        var result = Decimal()
        NSDecimalRound(&result, &input, places, .plain)
        return result
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter ExchangeRateTableTests`
Expected: 编译失败，`cannot find 'ExchangeRateTable' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/ExchangeRateTable.swift`：

```swift
import Foundation

/// 汇率表，只以单一基准币种存储，跨币种换算经基准中转。
struct ExchangeRateTable: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        case live
        case cache
        case fallback
    }

    static let baseCurrency = "USD"

    /// 联网失败且没有任何缓存时的兜底汇率，由设置界面明确标注。
    static let fallback = ExchangeRateTable(
        base: baseCurrency,
        rates: ["CNY": 7.2],
        fetchedAt: Date(timeIntervalSince1970: 0),
        origin: .fallback
    )

    var base: String
    var rates: [String: Double]
    var fetchedAt: Date
    var origin: Origin

    init(base: String, rates: [String: Double], fetchedAt: Date, origin: Origin) {
        self.base = base
        self.rates = rates
        self.fetchedAt = fetchedAt
        self.origin = origin
    }

    /// 解码按字段可选处理：换过形状的旧数据仍能读出来，走默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = try container.decodeIfPresent(String.self, forKey: .base) ?? Self.baseCurrency
        rates = try container.decodeIfPresent([String: Double].self, forKey: .rates) ?? [:]
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .cache
    }

    /// `rate(from:to:)` 的金额版本；缺失或非法汇率返回 nil，由调用方回退到原币种。
    func convert(_ amount: Decimal, from source: String, to target: String) -> Decimal? {
        guard let rate = rate(from: source, to: target) else {
            return nil
        }
        // Double 的二进制误差会污染 Decimal 的显示结果，先截到 6 位再转。
        let text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), rate)
        guard let decimalRate = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return amount * decimalRate
    }

    func rate(from source: String, to target: String) -> Double? {
        let source = source.uppercased()
        let target = target.uppercased()
        if source == target {
            return 1
        }
        guard let sourceRate = rateAgainstBase(source), let targetRate = rateAgainstBase(target) else {
            return nil
        }
        let rate = targetRate / sourceRate
        return rate.isFinite && rate > 0 ? rate : nil
    }

    private func rateAgainstBase(_ currency: String) -> Double? {
        if currency == base.uppercased() {
            return 1
        }
        guard let rate = rates.first(where: { $0.key.uppercased() == currency })?.value,
              rate.isFinite, rate > 0 else {
            return nil
        }
        return rate
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter ExchangeRateTableTests`
Expected: `Test run with 6 tests passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/ExchangeRateTable.swift Tests/TokenHealthTests/ExchangeRateTableTests.swift
git commit -m "$(cat <<'EOF'
Add the exchange rate table

Pure value type holding one base currency and the conversion math, so the
DeepSeek pinned amount can be shown in a chosen currency.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 2: TokenUsage.amount 与 DeepSeek 解析填充

**Files:**
- Modify: `Sources/TokenHealth/Models.swift`（`TokenUsage` 定义，约 184-203 行）
- Modify: `Sources/TokenHealth/DeepSeekUsageProvider.swift`（`parseSummaryBalances` / `parseTodayCosts` / `balanceUsage`）
- Test: `Tests/TokenHealthTests/DeepSeekAmountTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/DeepSeekAmountTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct DeepSeekAmountTests {
    @Test
    func balanceUsagesCarryTheirNumericAmount() throws {
        let data = Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"12.34"}]}"#.utf8)
        let usages = try DeepSeekUsageParser().parsePublicBalance(data: data)

        #expect(usages.count == 1)
        #expect(usages[0].unit == "CNY")
        #expect(usages[0].amount == Decimal(string: "12.34"))
        #expect(usages[0].displayValue == "12.34 CNY")
    }

    @Test
    func platformBalancesSumTheWalletsPerCurrency() throws {
        let bundle = """
        {"summary":{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"10.00"}],
        "bonus_wallets":[{"currency":"CNY","balance":"2.50"}]}}}}
        """
        let usages = try DeepSeekUsageParser().parsePlatformBundle(
            data: Data(bundle.utf8),
            today: "2026-09-24"
        )
        let balance = try #require(usages.first { $0.window == .balance })

        #expect(balance.unit == "CNY")
        #expect(balance.amount == Decimal(string: "12.50"))
        #expect(balance.displayValue == "12.50 CNY")
    }

    @Test
    func todayCostUsagesCarryTheirNumericAmount() throws {
        let bundle = """
        {"cost":{"data":[{"currency":"CNY","days":[{"date":"2026-09-24",
        "data":[{"model":"deepseek-chat","usage":[{"amount":"0.1234"}]}]}]}]}}
        """
        let usages = try DeepSeekUsageParser().parsePlatformBundle(
            data: Data(bundle.utf8),
            today: "2026-09-24"
        )
        let total = try #require(usages.first { $0.window == .todayCost && $0.label?.contains("total") == true })

        #expect(total.amount == Decimal(string: "0.1234"))
        #expect(total.displayValue == "0.1234 CNY")
    }

    @Test
    func tokenUsagesCarryNoAmount() {
        let usage = TokenUsage(window: .fiveHours, used: 1200, limit: 5000)
        #expect(usage.amount == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter DeepSeekAmountTests`
Expected: 编译失败，`value of type 'TokenUsage' has no member 'amount'`

- [ ] **Step 3: 给 TokenUsage 加字段**

在 `Sources/TokenHealth/Models.swift` 的 `TokenUsage` 里，紧跟 `displayValue` 之后加一行（**必须加在最后**，成员逐一初始化器的既有调用点才能继续编译）：

```swift
    var displayValue: String? = nil
    /// 金额型窗口的数值本身（`unit` 是币种代码）。仅用于需要重新换算的展示，
    /// 卡片继续读 `displayValue`。
    var amount: Decimal? = nil
```

- [ ] **Step 4: 让 DeepSeek 解析填上 amount**

在 `Sources/TokenHealth/DeepSeekUsageProvider.swift` 里改三处。

`balanceUsage(from:)` 的返回：

```swift
        return TokenUsage(
            window: .balance,
            label: "Balance \(currency)",
            used: 0,
            limit: nil,
            resetDate: nil,
            unit: currency,
            displayValue: moneyText(totalBalance, currency: currency, minimumFractionDigits: 2),
            amount: totalBalance
        )
```

`parseSummaryBalances` 里构造 `TokenUsage` 的那处，同样在末尾加 `amount: balance`。

`parseTodayCosts` 里两处（总计与按模型的行），分别在末尾加 `amount: total` 与 `amount: row.cost`。

- [ ] **Step 5: 跑测试确认通过**

Run: `bash scripts/test.sh --filter DeepSeekAmountTests`
Expected: `Test run with 4 tests passed`

- [ ] **Step 6: 跑全量测试确认没有回归**

Run: `bash scripts/test.sh`
Expected: 全绿。

- [ ] **Step 7: 提交**

```bash
git add Sources/TokenHealth/Models.swift Sources/TokenHealth/DeepSeekUsageProvider.swift Tests/TokenHealthTests/DeepSeekAmountTests.swift
git commit -m "$(cat <<'EOF'
Carry a numeric amount on money-shaped usages

The pinned menu bar item has to re-convert DeepSeek balances into another
currency, which formatted display strings cannot support.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 3: 提取 UsageMetricSelection

**Files:**
- Create: `Sources/TokenHealth/UsageMetricSelection.swift`
- Modify: `Sources/TokenHealth/StatusMenuView.swift:293-434`（`primaryUsages` / `detailUsages` / `compactUsages` / `isTokenTotal` / `isTodayTotal` / `usageSort` / `cursorLabelRank` / `usageRank`）
- Test: `Tests/TokenHealthTests/UsageMetricSelectionTests.swift`

这一步是纯搬移加去重，**卡片的行为必须逐字节不变**，所以先写一组把现有行为钉死的测试。

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/UsageMetricSelectionTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct UsageMetricSelectionTests {
    @Test
    func ranksQuotaWindowsInDisplayOrder() {
        let fiveHours = TokenUsage(window: .fiveHours, used: 1, limit: 10)
        let week = TokenUsage(window: .week, used: 1, limit: 10)
        let month = TokenUsage(window: .month, used: 1, limit: 10)
        let mcp = TokenUsage(window: .mcpMonth, used: 1, limit: 10)
        let video = TokenUsage(window: .videoGift, used: 1, limit: 10)

        #expect(UsageMetricSelection.rank(fiveHours) < UsageMetricSelection.rank(week))
        #expect(UsageMetricSelection.rank(week) < UsageMetricSelection.rank(month))
        #expect(UsageMetricSelection.rank(month) < UsageMetricSelection.rank(mcp))
        #expect(UsageMetricSelection.rank(mcp) < UsageMetricSelection.rank(video))
    }

    @Test
    func treatsLabelledModelBucketsAsNotAccountLevel() {
        let account = TokenUsage(window: .fiveHours, used: 1, limit: 10)
        let bucket = TokenUsage(window: .fiveHours, label: "gpt-5 · 5h", used: 1, limit: 10)
        let cursorPool = TokenUsage(window: .month, label: "Auto + Composer", used: 1, limit: 10)

        #expect(UsageMetricSelection.isAccountLevel(account))
        #expect(!UsageMetricSelection.isAccountLevel(bucket))
        #expect(UsageMetricSelection.isAccountLevel(cursorPool))
    }

    @Test
    func classifiesRollingQuotaWindowsOnly() {
        #expect(UsageMetricSelection.isRollingQuota(TokenUsage(window: .fiveHours, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isRollingQuota(TokenUsage(window: .week, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isRollingQuota(TokenUsage(window: .month, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isRollingQuota(TokenUsage(window: .mcpMonth, used: 1, limit: 10)))
        #expect(UsageMetricSelection.isRollingQuota(TokenUsage(window: .videoGift, used: 1, limit: 10)))

        #expect(!UsageMetricSelection.isRollingQuota(TokenUsage(window: .balance, used: 0, limit: nil)))
        #expect(!UsageMetricSelection.isRollingQuota(TokenUsage(window: .todayCost, used: 0, limit: nil)))
        #expect(!UsageMetricSelection.isRollingQuota(TokenUsage(window: .sevenDaysTokens, label: "7d Token total", used: 5, limit: nil)))
        #expect(!UsageMetricSelection.isRollingQuota(TokenUsage(window: .sevenDaysTools, used: 5, limit: nil)))
    }

    @Test
    func pinnedMetricsTakeEveryQuotaWindow() {
        let usages = [
            TokenUsage(window: .week, used: 10, limit: 100),
            TokenUsage(window: .fiveHours, used: 10, limit: 100),
            TokenUsage(window: .mcpMonth, used: 10, limit: 100),
            TokenUsage(window: .todayTokens, label: "Today tokens total", used: 10, limit: nil)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .zhipuCode)

        #expect(pinned.map(\.window) == [.fiveHours, .week, .mcpMonth])
    }

    @Test
    func pinnedMetricsDropCodexModelBuckets() {
        let usages = [
            TokenUsage(window: .fiveHours, used: 10, limit: 100),
            TokenUsage(window: .fiveHours, label: "gpt-5 · 5h", used: 10, limit: 100),
            TokenUsage(window: .week, used: 10, limit: 100)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .codex)

        #expect(pinned.count == 2)
        #expect(pinned.allSatisfy { UsageMetricSelection.isAccountLevel($0) })
    }

    @Test
    func pinnedMetricsOrderCursorPoolsByTheirLabel() {
        let usages = [
            TokenUsage(window: .month, label: "Grokbot", used: 10, limit: 100),
            TokenUsage(window: .month, label: "API", used: 10, limit: 100),
            TokenUsage(window: .month, label: "Auto + Composer", used: 10, limit: 100)
        ]
        let pinned = UsageMetricSelection.pinnedMetrics(from: usages, kind: .cursor)

        #expect(pinned.map(\.label) == ["Auto + Composer", "API", "Grokbot"])
    }

    @Test
    func pinnedMetricsAreEmptyWhenNothingHasAQuota() {
        let usages = [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "12.34 CNY")
        ]
        #expect(UsageMetricSelection.pinnedMetrics(from: usages, kind: .deepSeek).isEmpty)
    }

    @Test
    func sortingIsStableForEqualRanks() {
        let usages = [
            TokenUsage(window: .week, used: 1, limit: 10),
            TokenUsage(window: .fiveHours, used: 1, limit: 10)
        ]
        #expect(UsageMetricSelection.sorted(usages, kind: .kimiCode).map(\.window) == [.fiveHours, .week])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter UsageMetricSelectionTests`
Expected: 编译失败，`cannot find 'UsageMetricSelection' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/UsageMetricSelection.swift`。逻辑**逐字搬自** `StatusMenuView.UsageCard` 的私有方法，只把 `config.providerKind` 改成 `kind` 参数：

```swift
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

    /// 滚动额度窗口：5h / 周 / 月 / MCP 月 / 视频赠送。
    /// 余额、今日用量、7 日明细都是计数或金额，没有比例可画。
    static func isRollingQuota(_ usage: TokenUsage) -> Bool {
        switch usage.window {
        case .fiveHours, .week, .month, .mcpMonth, .videoGift:
            true
        case .balance, .tokenQuota, .todayCost, .todayTokens, .todayRequests,
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
    static func pinnedMetrics(from usages: [TokenUsage], kind: ProviderKind) -> [TokenUsage] {
        let quota = usages.filter { usage in
            guard isRollingQuota(usage) else {
                return false
            }
            return kind == .codex ? isAccountLevel(usage) : true
        }
        return sorted(quota, kind: kind)
    }
}
```

- [ ] **Step 4: 让 UsageCard 改用它**

在 `Sources/TokenHealth/StatusMenuView.swift` 的 `UsageCard` 里：

删掉私有方法 `isTokenTotal`、`isTodayTotal`、`usageSort`、`cursorLabelRank`、`usageRank`（约 363-434 行）。

`primaryUsages` 改成：

```swift
    private func primaryUsages(from usages: [TokenUsage]) -> [TokenUsage] {
        let selected = usages.filter { usage in
            switch usage.window {
            case .sevenDaysTokens:
                return UsageMetricSelection.isTokenTotal(usage)
            case .sevenDaysTools:
                return false
            case .balance, .tokenQuota:
                return true
            case .todayCost, .todayTokens, .todayRequests:
                return UsageMetricSelection.isTodayTotal(usage)
            case .fiveHours, .week, .month, .mcpMonth, .videoGift:
                return true
            }
        }
        return UsageMetricSelection.sorted(selected, kind: config.providerKind)
    }
```

`detailUsages` 同样把 `isTokenTotal` / `isTodayTotal` 换成 `UsageMetricSelection.` 前缀，把 `.sorted(by: usageSort)` 换成 `UsageMetricSelection.sorted(selected, kind: config.providerKind)`。

`compactUsages` 把三处 `.sorted(by: usageSort)` 换成 `UsageMetricSelection.sorted(..., kind: config.providerKind)`，并把 Codex 的账号级判定换成 `UsageMetricSelection.isAccountLevel($0)`；末尾的 `primaryUsages(from: usages)` 保持不变。

- [ ] **Step 5: 跑测试确认通过**

Run: `bash scripts/test.sh --filter UsageMetricSelectionTests`
Expected: `Test run with 8 tests passed`

- [ ] **Step 6: 跑全量测试确认卡片没有回归**

Run: `bash scripts/test.sh`
Expected: 全绿（尤其 `StatusMenuSummaryTests`）。

- [ ] **Step 7: 提交**

```bash
git add Sources/TokenHealth/UsageMetricSelection.swift Sources/TokenHealth/StatusMenuView.swift Tests/TokenHealthTests/UsageMetricSelectionTests.swift
git commit -m "$(cat <<'EOF'
Extract the quota metric selection out of the usage card

The pinned menu bar item needs the same notion of which windows count as
quotas and in what order, so lift it out of the card's private helpers
instead of keeping two copies.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 4: MenuBarMetrics

**Files:**
- Create: `Sources/TokenHealth/MenuBarMetrics.swift`
- Test: `Tests/TokenHealthTests/MenuBarMetricsTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/MenuBarMetricsTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct MenuBarMetricsTests {
    private let rateTable = ExchangeRateTable(
        base: "USD",
        rates: ["CNY": 7],
        fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
        origin: .live
    )

    private func snapshot(kind: ProviderKind, usages: [TokenUsage], state: ProviderUsageSnapshot.State = .ready) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: UUID(),
            serviceName: "Test",
            providerTitle: kind.title,
            usages: usages,
            state: state,
            statusMessage: "ok",
            updatedAt: Date()
        )
    }

    @Test
    func buildsOneRatioMetricPerQuotaWindow() {
        let snap = snapshot(kind: .zhipuCode, usages: [
            TokenUsage(window: .fiveHours, used: 50, limit: 100),
            TokenUsage(window: .week, used: 10, limit: 100),
            TokenUsage(window: .mcpMonth, used: 0, limit: 100)
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .zhipuCode, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.count == 3)
        #expect(metrics.map(\.label) == ["5h", "Week", "MCP"])
        #expect(metrics[0].shape == .ratio(0.5))
        #expect(metrics[1].shape == .ratio(0.1))
        #expect(metrics[0].severity == 0.5)
    }

    @Test
    func clampsRatiosAboveOne() {
        let snap = snapshot(kind: .kimiCode, usages: [TokenUsage(window: .fiveHours, used: 300, limit: 100)])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.first?.shape == .ratio(1))
    }

    @Test
    func usesTheShortWindowLabelWhenTheUsageHasNone() {
        let snap = snapshot(kind: .openCodeGo, usages: [
            TokenUsage(window: .month, used: 1, limit: 10),
            TokenUsage(window: .videoGift, used: 1, limit: 10)
        ])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .openCodeGo, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.map(\.label) == ["Month", "Video"])
    }

    @Test
    func returnsNothingWhenTheSnapshotIsNotReady() {
        let snap = snapshot(kind: .kimiCode, usages: [], state: .unavailable)
        #expect(MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable).isEmpty)
    }

    @Test
    func returnsNothingWithoutASnapshot() {
        #expect(MenuBarMetrics.metrics(for: nil, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable).isEmpty)
    }

    @Test
    func deepSeekWithoutATargetCurrencyShowsTheLeadingBalance() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "12.50 CNY", amount: Decimal(string: "12.50")),
            TokenUsage(window: .balance, label: "Balance USD", used: 0, limit: nil, unit: "USD", displayValue: "3.00 USD", amount: Decimal(string: "3.00"))
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: nil, rateTable: rateTable)

        #expect(metrics.count == 1)
        #expect(metrics[0].shape == .amount("12.50"))
        #expect(metrics[0].severity == nil)
    }

    @Test
    func deepSeekConvertsAndSumsEveryWalletIntoTheTargetCurrency() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "10.00 CNY", amount: Decimal(string: "10.00")),
            TokenUsage(window: .balance, label: "Balance USD", used: 0, limit: nil, unit: "USD", displayValue: "2.00 USD", amount: Decimal(string: "2.00"))
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: "CNY", rateTable: rateTable)

        #expect(metrics.count == 1)
        #expect(metrics[0].shape == .amount("24.00"))
    }

    @Test
    func deepSeekFallsBackToTheOriginalAmountWhenTheRateIsMissing() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .balance, label: "Balance CNY", used: 0, limit: nil, unit: "CNY", displayValue: "10.00 CNY", amount: Decimal(string: "10.00")),
            TokenUsage(window: .balance, label: "Balance USD", used: 0, limit: nil, unit: "USD", displayValue: "2.00 USD", amount: Decimal(string: "2.00"))
        ])

        let metrics = MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: "EUR", rateTable: rateTable)

        #expect(metrics.count == 1)
        #expect(metrics[0].shape == .amount("10.00"))
        #expect(metrics[0].label.contains("rate unavailable"))
    }

    @Test
    func deepSeekWithNoBalanceProducesNothing() {
        let snap = snapshot(kind: .deepSeek, usages: [
            TokenUsage(window: .todayTokens, label: "Today tokens total", used: 5, limit: nil, unit: "tokens")
        ])
        #expect(MenuBarMetrics.metrics(for: snap, kind: .deepSeek, displayCurrency: "CNY", rateTable: rateTable).isEmpty)
    }

    @Test
    func tooltipTextListsEveryMetric() {
        let snap = snapshot(kind: .kimiCode, usages: [
            TokenUsage(window: .fiveHours, used: 62, limit: 100),
            TokenUsage(window: .week, used: 34, limit: 100)
        ])
        let metrics = MenuBarMetrics.metrics(for: snap, kind: .kimiCode, displayCurrency: nil, rateTable: rateTable)

        #expect(MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: metrics) == "Kimi · 5h 62% · Week 34%")
    }

    @Test
    func tooltipTextFallsBackToTheStatusMessage() {
        #expect(MenuBarMetrics.tooltipText(serviceName: "Kimi", metrics: [], statusMessage: "Waiting for refresh") == "Kimi · Waiting for refresh")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter MenuBarMetricsTests`
Expected: 编译失败，`cannot find 'MenuBarMetrics' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/MenuBarMetrics.swift`：

```swift
import Foundation

/// 菜单栏项上的一个指标：要么是一根比例条，要么是一段金额文字。
struct MenuBarMetric: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case ratio(Double)
        case amount(String)
    }

    var label: String
    var shape: Shape
    /// 用于选色；金额型没有严重度。
    var severity: Double?
}

enum MenuBarMetrics {
    /// 快照不可用时画这个，让菜单栏上留一根空槽而不是整项消失。
    static let placeholder = MenuBarMetric(label: "", shape: .ratio(0), severity: nil)

    static func metrics(
        for snapshot: ProviderUsageSnapshot?,
        kind: ProviderKind,
        displayCurrency: String?,
        rateTable: ExchangeRateTable
    ) -> [MenuBarMetric] {
        guard let snapshot, snapshot.state == .ready else {
            return []
        }
        if kind == .deepSeek {
            return deepSeekMetrics(from: snapshot.usages, displayCurrency: displayCurrency, rateTable: rateTable)
        }
        return UsageMetricSelection.pinnedMetrics(from: snapshot.usages, kind: kind).map { usage in
            let ratio = min(max(usage.ratio ?? 0, 0), 1)
            return MenuBarMetric(label: shortLabel(for: usage), shape: .ratio(ratio), severity: ratio)
        }
    }

    static func tooltipText(serviceName: String, metrics: [MenuBarMetric], statusMessage: String? = nil) -> String {
        guard !metrics.isEmpty else {
            return "\(serviceName) · \(statusMessage ?? "Waiting for refresh")"
        }
        let parts = metrics.map { metric in
            switch metric.shape {
            case let .ratio(value):
                "\(metric.label) \(percentText(value))"
            case let .amount(text):
                "\(metric.label) \(text)"
            }
        }
        return ([serviceName] + parts).joined(separator: " · ")
    }

    static func percentText(_ ratio: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let percent = (ratio * 100).rounded()
        return "\(formatter.string(from: NSNumber(value: percent)) ?? "\(Int(percent))")%"
    }

    /// tooltip 用的短标签；usage 自带 label 时优先用它的（Cursor 的池名靠这个）。
    static func shortLabel(for usage: TokenUsage) -> String {
        if let label = usage.label, !label.isEmpty {
            return label
        }
        return switch usage.window {
        case .fiveHours: "5h"
        case .week: "Week"
        case .month: "Month"
        case .mcpMonth: "MCP"
        case .videoGift: "Video"
        default: usage.window.title
        }
    }

    static func moneyText(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private static func deepSeekMetrics(
        from usages: [TokenUsage],
        displayCurrency: String?,
        rateTable: ExchangeRateTable
    ) -> [MenuBarMetric] {
        let balances = usages.filter { $0.window == .balance }
        guard !balances.isEmpty else {
            return []
        }

        let target = displayCurrency?.trimmingCharacters(in: .whitespaces).uppercased()
        guard let target, !target.isEmpty else {
            // 没选目标币种：与卡片折叠态一致，取排序最前的那一个原值。
            let ordered = UsageMetricSelection.sorted(balances, kind: .deepSeek)
            guard let first = ordered.first, let amount = first.amount else {
                return []
            }
            return [MenuBarMetric(label: shortLabel(for: first), shape: .amount(moneyText(amount)), severity: nil)]
        }

        var total = Decimal(0)
        for balance in balances {
            guard let amount = balance.amount,
                  let currency = balance.unit,
                  let converted = rateTable.convert(amount, from: currency, to: target) else {
                // 只要有一个币种换不了就整体退回原值，避免给出一个悄悄漏了钱的数。
                guard let fallback = UsageMetricSelection.sorted(balances, kind: .deepSeek).first,
                      let fallbackAmount = fallback.amount else {
                    return []
                }
                return [MenuBarMetric(
                    label: "\(shortLabel(for: fallback)) · rate unavailable",
                    shape: .amount(moneyText(fallbackAmount)),
                    severity: nil
                )]
            }
            total += converted
        }
        return [MenuBarMetric(label: target, shape: .amount(moneyText(total)), severity: nil)]
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter MenuBarMetricsTests`
Expected: `Test run with 11 tests passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/MenuBarMetrics.swift Tests/TokenHealthTests/MenuBarMetricsTests.swift
git commit -m "$(cat <<'EOF'
Turn a snapshot into the metrics the pinned item draws

One ratio per quota window, or a single converted DeepSeek amount, plus
the tooltip text that carries the numbers the item itself does not show.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 5: MenuBarItemLayout

**Files:**
- Create: `Sources/TokenHealth/MenuBarItemLayout.swift`
- Test: `Tests/TokenHealthTests/MenuBarItemLayoutTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/MenuBarItemLayoutTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct MenuBarItemLayoutTests {
    @Test
    func placesBarsLeftToRightAfterTheIcon() {
        let metrics = [
            MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5),
            MenuBarMetric(label: "Week", shape: .ratio(0.25), severity: 0.25)
        ]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)

        #expect(layout.iconRect?.width == MenuBarItemLayout.iconSize)
        #expect(layout.tracks.count == 2)
        #expect(layout.tracks[1].minX - layout.tracks[0].maxX == MenuBarItemLayout.barGap)
        #expect(layout.tracks.allSatisfy { $0.height == MenuBarItemLayout.maxBarHeight })
    }

    @Test
    func dropsTheIconGapWhenThereIsNoIcon() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)
        let withIcon = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 0)

        #expect(layout.iconRect == nil)
        #expect(layout.tracks[0].minX == 0)
        #expect(withIcon.size.width - layout.size.width == MenuBarItemLayout.iconSize + MenuBarItemLayout.iconGap)
    }

    @Test
    func fillsScaleWithTheRatio() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.5), severity: 0.5)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)

        #expect(layout.fills[0].height == MenuBarItemLayout.maxBarHeight * 0.5)
        #expect(layout.fills[0].minY == layout.tracks[0].minY)
    }

    @Test
    func keepsATinyFillVisible() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0.02), severity: 0.02)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)

        #expect(layout.fills[0].height == MenuBarItemLayout.minimumVisibleHeight)
    }

    @Test
    func drawsNoFillAtZero() {
        let metrics = [MenuBarMetric(label: "5h", shape: .ratio(0), severity: 0)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: false, amountWidth: 0)

        #expect(layout.fills[0].height == 0)
        #expect(layout.tracks.count == 1)
    }

    @Test
    func anEmptyMetricListStillReservesOneTrack() {
        let layout = MenuBarItemLayout.make(metrics: [], hasIcon: true, amountWidth: 0)

        #expect(layout.tracks.count == 1)
        #expect(layout.fills[0].height == 0)
        #expect(layout.size.width > MenuBarItemLayout.iconSize)
    }

    @Test
    func amountContentReplacesTheBarsWithText() {
        let metrics = [MenuBarMetric(label: "CNY", shape: .amount("24.00"), severity: nil)]
        let layout = MenuBarItemLayout.make(metrics: metrics, hasIcon: true, amountWidth: 30)

        #expect(layout.tracks.isEmpty)
        #expect(layout.fills.isEmpty)
        #expect(layout.amountRect?.width == 30)
        #expect(layout.amountRect?.height == MenuBarItemLayout.maxBarHeight)
        #expect(layout.size.width == MenuBarItemLayout.iconSize + MenuBarItemLayout.iconGap + 30)
    }

    @Test
    func heightCoversTheTallestBarPlusPadding() {
        let layout = MenuBarItemLayout.make(metrics: [], hasIcon: false, amountWidth: 0)
        #expect(layout.size.height == MenuBarItemLayout.maxBarHeight + 2 * MenuBarItemLayout.verticalPadding)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter MenuBarItemLayoutTests`
Expected: 编译失败，`cannot find 'MenuBarItemLayout' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/MenuBarItemLayout.swift`：

```swift
import CoreGraphics

/// 菜单栏项的纯几何计算：图标与每根条画在哪里。
/// 刻意不碰 AppKit，这样布局可以在没有窗口服务器的测试进程里验证。
struct MenuBarItemLayout: Equatable {
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1.5
    static let maxBarHeight: CGFloat = 13
    static let iconSize: CGFloat = 12
    static let iconGap: CGFloat = 4
    static let verticalPadding: CGFloat = 1
    /// 2% 的额度在 13pt 高里只有 0.26pt，不兜底等于看不见。
    static let minimumVisibleHeight: CGFloat = 1.5
    /// 状态项两侧各留一点，避免图像贴着相邻项。
    static let statusItemPadding: CGFloat = 6

    var size: CGSize
    var iconRect: CGRect?
    /// 每根条的空槽，满高。
    var tracks: [CGRect]
    /// 每根条的填充，从空槽底部起算。
    var fills: [CGRect]
    /// 金额型内容的可用区域；有它时 `tracks` 与 `fills` 必为空。
    var amountRect: CGRect?

    static func make(metrics: [MenuBarMetric], hasIcon: Bool, amountWidth: CGFloat) -> MenuBarItemLayout {
        let iconWidth = hasIcon ? iconSize + iconGap : 0
        let height = maxBarHeight + 2 * verticalPadding
        let iconRect = hasIcon
            ? CGRect(x: 0, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            : nil

        if let amountText = amountText(in: metrics) {
            _ = amountText
            let width = iconWidth + max(amountWidth, 0)
            return MenuBarItemLayout(
                size: CGSize(width: width, height: height),
                iconRect: iconRect,
                tracks: [],
                fills: [],
                amountRect: CGRect(
                    x: iconWidth,
                    y: verticalPadding,
                    width: max(amountWidth, 0),
                    height: maxBarHeight
                )
            )
        }

        var ratios = metrics.compactMap { metric -> Double? in
            guard case let .ratio(value) = metric.shape else {
                return nil
            }
            return min(max(value, 0), 1)
        }
        if ratios.isEmpty {
            ratios = [0]
        }

        var tracks: [CGRect] = []
        var fills: [CGRect] = []
        var x = iconWidth
        for ratio in ratios {
            let track = CGRect(x: x, y: verticalPadding, width: barWidth, height: maxBarHeight)
            tracks.append(track)
            let fillHeight = ratio > 0 ? max(minimumVisibleHeight, maxBarHeight * CGFloat(ratio)) : 0
            fills.append(CGRect(x: x, y: verticalPadding, width: barWidth, height: fillHeight))
            x += barWidth + barGap
        }

        let barsWidth = CGFloat(ratios.count) * barWidth + CGFloat(ratios.count - 1) * barGap
        return MenuBarItemLayout(
            size: CGSize(width: iconWidth + barsWidth, height: height),
            iconRect: iconRect,
            tracks: tracks,
            fills: fills,
            amountRect: nil
        )
    }

    /// 金额型内容只可能来自 DeepSeek，且一次只有一个。
    static func amountText(in metrics: [MenuBarMetric]) -> String? {
        metrics.compactMap { metric -> String? in
            guard case let .amount(text) = metric.shape else {
                return nil
            }
            return text
        }.first
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter MenuBarItemLayoutTests`
Expected: `Test run with 8 tests passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/MenuBarItemLayout.swift Tests/TokenHealthTests/MenuBarItemLayoutTests.swift
git commit -m "$(cat <<'EOF'
Lay out the pinned menu bar item

Pure geometry for the icon and the per-window bars, including the floor
that keeps a two percent quota from rendering as nothing.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 6: ConfigStore 的两个新键

**Files:**
- Modify: `Sources/TokenHealth/ConfigStore.swift`
- Test: `Tests/TokenHealthTests/PinnedProviderConfigTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/PinnedProviderConfigTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

struct PinnedProviderConfigTests {
    private func makeStore() -> ConfigStore {
        let suite = UserDefaults(suiteName: "pinned-provider-tests-\(UUID().uuidString)")!
        return ConfigStore(defaults: suite)
    }

    @Test
    func pinnedConfigIDRoundTrips() {
        let store = makeStore()
        #expect(store.loadPinnedConfigID() == nil)

        let id = UUID()
        store.savePinnedConfigID(id)
        #expect(store.loadPinnedConfigID() == id)

        store.savePinnedConfigID(nil)
        #expect(store.loadPinnedConfigID() == nil)
    }

    @Test
    func exchangeRateRoundTrips() {
        let store = makeStore()
        #expect(store.loadExchangeRate() == nil)

        let table = ExchangeRateTable(
            base: "USD",
            rates: ["CNY": 6.9],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            origin: .live
        )
        store.saveExchangeRate(table)
        #expect(store.loadExchangeRate() == table)
    }

    @Test
    func decodesLegacyConfigsWithoutADisplayCurrency() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","displayName":"DeepSeek","providerKind":"deepSeek",
          "authMode":"api","isEnabled":true}]
        """
        let configs = try JSONDecoder().decode([ServiceConfig].self, from: Data(json.utf8))

        #expect(configs.count == 1)
        #expect(configs[0].displayCurrency == nil)
    }

    @Test
    func encodesAndDecodesADisplayCurrency() throws {
        var config = ServiceConfig(displayName: "DeepSeek", providerKind: .deepSeek, authMode: .api)
        config.displayCurrency = "CNY"

        let data = try JSONEncoder().encode([config])
        let decoded = try JSONDecoder().decode([ServiceConfig].self, from: data)

        #expect(decoded[0].displayCurrency == "CNY")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter PinnedProviderConfigTests`
Expected: 编译失败，`value of type 'ConfigStore' has no member 'loadPinnedConfigID'`

- [ ] **Step 3: 给 ServiceConfig 加 displayCurrency**

在 `Sources/TokenHealth/Models.swift` 的 `ServiceConfig` 里：

- 属性区加 `var displayCurrency: String?`
- 初始化器参数末尾加 `displayCurrency: String? = nil`
- `CodingKeys` 加 `case displayCurrency`
- `init(from:)` 加 `displayCurrency = try container.decodeIfPresent(String.self, forKey: .displayCurrency)`

`Equatable` 由合成实现，无需改动。

- [ ] **Step 4: 加 ConfigStore 的读写**

在 `Sources/TokenHealth/ConfigStore.swift` 里，键声明区加：

```swift
    private let pinnedProviderDefaultsKey = "pinned-provider.config.v1"
    private let exchangeRateDefaultsKey = "exchange-rate.config.v1"
```

在 `saveRefreshInterval` 之后加：

```swift
    func loadPinnedConfigID() -> UUID? {
        guard let raw = defaults.string(forKey: pinnedProviderDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    func savePinnedConfigID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: pinnedProviderDefaultsKey)
        } else {
            defaults.removeObject(forKey: pinnedProviderDefaultsKey)
        }
    }

    func loadExchangeRate() -> ExchangeRateTable? {
        guard let data = defaults.data(forKey: exchangeRateDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ExchangeRateTable.self, from: data)
    }

    func saveExchangeRate(_ table: ExchangeRateTable) {
        guard let data = try? JSONEncoder().encode(table) else {
            return
        }
        defaults.set(data, forKey: exchangeRateDefaultsKey)
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash scripts/test.sh --filter PinnedProviderConfigTests`
Expected: `Test run with 4 tests passed`

- [ ] **Step 6: 跑全量测试**

Run: `bash scripts/test.sh`
Expected: 全绿。

- [ ] **Step 7: 提交**

```bash
git add Sources/TokenHealth/Models.swift Sources/TokenHealth/ConfigStore.swift Tests/TokenHealthTests/PinnedProviderConfigTests.swift
git commit -m "$(cat <<'EOF'
Persist the pinned account and the cached exchange rate

Adds the display currency field to the config model, decoded optionally so
existing stored configs keep loading.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: 资源、汇率抓取与渲染

### Task 7: 抓取图标资源并接进构建

**Files:**
- Create: `scripts/fetch-provider-icons.sh`
- Create: `Sources/TokenHealth/Resources/ProviderIcons/*.pdf`（脚本产物）
- Modify: `Package.swift`
- Modify: `scripts/build-app.sh:42-47`

- [ ] **Step 1: 写抓取脚本**

创建 `scripts/fetch-provider-icons.sh`：

```bash
#!/usr/bin/env bash
# 抓取各 Provider 的官方 logo，转成矢量 PDF 放进 App 资源目录。
# 图标来自 lobehub 的 icons-static-svg，版本固定，保证可重复执行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Sources/TokenHealth/Resources/ProviderIcons"
PACKAGE="@lobehub/icons-static-svg@1.95.1"
BASE_URL="https://cdn.jsdelivr.net/npm/$PACKAGE/icons"
SLUGS=(openai anthropic cursor codex kimi zhipu deepseek minimax volcengine opencode)

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. Install it with: brew install librsvg" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for slug in "${SLUGS[@]}"; do
  target="$OUT_DIR/$slug.pdf"
  if [[ -s "$target" && "$FORCE" -eq 0 ]]; then
    echo "skip  $slug (already present)"
    continue
  fi

  source="$TMP_DIR/$slug.svg"
  if ! curl -fsSL --max-time 30 -o "$source" "$BASE_URL/$slug.svg"; then
    echo "failed to download $slug from $BASE_URL" >&2
    exit 1
  fi

  if ! rsvg-convert -f pdf -o "$target" "$source"; then
    echo "failed to convert $slug to PDF" >&2
    exit 1
  fi

  if [[ ! -s "$target" ]] || [[ "$(head -c 4 "$target")" != "%PDF" ]]; then
    echo "$slug produced no usable PDF" >&2
    exit 1
  fi
  echo "wrote $slug.pdf"
done

echo "$OUT_DIR"
```

Run:
```bash
chmod +x scripts/fetch-provider-icons.sh && bash scripts/fetch-provider-icons.sh
```
Expected: 10 行 `wrote ...`，最后打印目录路径。目录里应有 10 个非空 PDF。

- [ ] **Step 2: 让 SwiftPM 打包资源**

把 `Package.swift` 里的可执行 target 改成：

```swift
        .executableTarget(
            name: "TokenHealth",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit")
            ]
        ),
```

Run:
```bash
bash scripts/test.sh 2>&1 | tail -5
```
Expected: 测试仍然全绿（此时还没人读资源，只是确认加资源不破坏构建）。

- [ ] **Step 3: 让打包脚本带上资源 bundle**

`Bundle.module` 找不到 bundle 时会 `fatalError`，所以这一步是必须的，不是优化。

把 `scripts/build-app.sh` 末尾的拷贝段改成：

```bash
RESOURCE_BUNDLE="$SCRATCH_PATH/release/TokenHealth_TokenHealth.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Missing $RESOURCE_BUNDLE; the Provider logo resources did not build." >&2
  exit 1
fi

rm -rf "$APP_DIR" "$LEGACY_APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILT_BINARY" "$APP_DIR/Contents/MacOS/TokenHealth"
cp "$ROOT/AppSupport/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/AppSupport/TokenHealth.icns" "$APP_DIR/Contents/Resources/TokenHealth.icns"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
codesign --force --deep --sign - "$APP_DIR"
```

- [ ] **Step 4: 构建验证**

Run:
```bash
bash scripts/build-app.sh && ls ".build/app/Token Health.app/Contents/Resources/" && ls ".build/app/Token Health.app/Contents/Resources/TokenHealth_TokenHealth.bundle/"
```
Expected: 打印出 app 路径；Resources 下有 `TokenHealth.icns` 与 `TokenHealth_TokenHealth.bundle`；bundle 里能看到 `ProviderIcons` 目录（SwiftPM 会保留 `.process` 的目录结构）。

- [ ] **Step 5: 提交**

```bash
git add scripts/fetch-provider-icons.sh scripts/build-app.sh Package.swift Sources/TokenHealth/Resources
git commit -m "$(cat <<'EOF'
Bundle the official provider logos as vector assets

Fetched from the lobehub icon set at a pinned version and converted to PDF,
which NSImage renders as vector on every supported macOS rather than
relying on SVG decoding that only newer systems have.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 8: ProviderIcon

**Files:**
- Create: `Sources/TokenHealth/ProviderIcon.swift`
- Modify: `Sources/TokenHealth/SettingsView.swift`（删掉私有 `iconName(for:)`，改调 `ProviderIcon`）
- Test: `Tests/TokenHealthTests/ProviderIconTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/ProviderIconTests.swift`：

```swift
import AppKit
import Foundation
import Testing
@testable import TokenHealth

struct ProviderIconTests {
    @Test
    func everyProviderResolvesToOneFormOfIcon() {
        for kind in ProviderKind.allCases {
            let hasAsset = ProviderIcon.assetName(for: kind) != nil
            let hasSymbol = !ProviderIcon.symbolName(for: kind).isEmpty
            #expect(hasAsset || hasSymbol, "\(kind) has neither a logo asset nor a fallback symbol")
        }
    }

    @Test
    func brandedProvidersDeclareAnAsset() {
        #expect(ProviderIcon.assetName(for: .kimiCode) == "kimi")
        #expect(ProviderIcon.assetName(for: .deepSeek) == "deepseek")
        #expect(ProviderIcon.assetName(for: .volcengineArk) == "volcengine")
        #expect(ProviderIcon.assetName(for: .genericHTTP) == nil)
        #expect(ProviderIcon.assetName(for: .demo) == nil)
    }

    @Test
    func loadsTheBundledLogo() throws {
        let image = ProviderIcon.image(for: .kimiCode, size: 16, tint: .black)
        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
        #expect(!image.isTemplate, "the composed menu bar image must keep its colors")
    }

    @Test
    func fallsBackToASymbolForProvidersWithoutALogo() {
        let image = ProviderIcon.image(for: .genericHTTP, size: 16, tint: .black)
        #expect(image.size.width == 16)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter ProviderIconTests`
Expected: 编译失败，`cannot find 'ProviderIcon' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/ProviderIcon.swift`：

```swift
import AppKit

/// Provider 的图标来源：能拿到官方 logo 就用 logo，否则退回 SF Symbol。
/// 设置侧边栏与菜单栏项共用这一处，避免两边各有一份「谁长什么样」。
enum ProviderIcon {
    /// 内嵌资源名。nil 表示这个 Provider 没有品牌 logo。
    static func assetName(for kind: ProviderKind) -> String? {
        switch kind {
        case .openAI: "openai"
        case .anthropic: "anthropic"
        case .cursor: "cursor"
        case .codex: "codex"
        case .kimiCode: "kimi"
        case .zhipuCode: "zhipu"
        case .deepSeek: "deepseek"
        case .miniMax: "minimax"
        case .volcengineArk: "volcengine"
        case .openCodeGo: "opencode"
        case .genericHTTP, .demo: nil
        }
    }

    static func symbolName(for kind: ProviderKind) -> String {
        switch kind {
        case .openAI: "sparkles"
        case .anthropic: "text.bubble"
        case .cursor: "cursorarrow"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .kimiCode: "moon.stars"
        case .zhipuCode: "brain.head.profile"
        case .deepSeek: "waveform.path.ecg"
        case .miniMax: "m.circle"
        case .volcengineArk: "flame"
        case .openCodeGo: "terminal"
        case .genericHTTP: "network"
        case .demo: "chart.bar"
        }
    }

    /// 指定尺寸与颜色的位图。资源缺失时静默退回 SF Symbol，不让菜单栏项消失。
    static func image(for kind: ProviderKind, size: CGFloat, tint: NSColor) -> NSImage {
        let source = bundledLogo(for: kind) ?? symbolImage(for: kind, size: size)
        return tinted(source, color: tint, size: size)
    }

    private static func bundledLogo(for kind: ProviderKind) -> NSImage? {
        guard let name = assetName(for: kind),
              let url = Bundle.module.url(forResource: name, withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func symbolImage(for kind: ProviderKind, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let symbol = NSImage(systemSymbolName: symbolName(for: kind), accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        return symbol ?? NSImage(size: NSSize(width: size, height: size))
    }

    /// 绘图被推迟到实际绘制时执行，动态颜色（如 `.labelColor`）因此在正确的
    /// 外观上下文里解析，菜单栏项也就拿到了「单色模板」的自适应效果。
    private static func tinted(_ image: NSImage, color: NSColor, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}
```

- [ ] **Step 4: 让设置界面改用它**

在 `Sources/TokenHealth/SettingsView.swift` 里删掉私有的 `iconName(for:)`，把两处 `Image(systemName: iconName(for: config.providerKind))` 改成：

```swift
                            Image(nsImage: ProviderIcon.image(for: config.providerKind, size: 16, tint: .labelColor))
                                .frame(width: 18)
```

（两处分别在侧边栏的 provider 列表与「Usage reporting」的 provider 列表里。）

- [ ] **Step 5: 跑测试确认通过**

Run: `bash scripts/test.sh --filter ProviderIconTests`
Expected: `Test run with 4 tests passed`

- [ ] **Step 6: 构建一次确认资源真的能加载**

Run: `bash scripts/build-app.sh && bash scripts/test.sh`
Expected: 构建成功、测试全绿。

- [ ] **Step 7: 提交**

```bash
git add Sources/TokenHealth/ProviderIcon.swift Sources/TokenHealth/SettingsView.swift Tests/TokenHealthTests/ProviderIconTests.swift
git commit -m "$(cat <<'EOF'
Resolve provider icons from the bundled logos

One place decides what each provider looks like, shared by the settings
sidebar and the pinned menu bar item, with SF Symbols as the fallback for
providers that have no brand mark.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 9: 汇率抓取与缓存

**Files:**
- Create: `Sources/TokenHealth/ExchangeRateStore.swift`
- Test: `Tests/TokenHealthTests/ExchangeRateStoreTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/ExchangeRateStoreTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

private struct StubFetcher: ExchangeRateFetching {
    var result: Result<ExchangeRateTable, Error>

    func fetchTable() async throws -> ExchangeRateTable {
        try result.get()
    }
}

private struct StubError: Error {}

@MainActor
struct ExchangeRateStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "exchange-rate-tests-\(UUID().uuidString)")!
    }

    private func liveTable(rate: Double, at date: Date) -> ExchangeRateTable {
        ExchangeRateTable(base: "USD", rates: ["CNY": rate], fetchedAt: date, origin: .live)
    }

    @Test
    func startsFromTheFallbackWhenNothingIsCached() {
        let store = ExchangeRateStore(
            configStore: ConfigStore(defaults: makeDefaults()),
            fetcher: StubFetcher(result: .failure(StubError()))
        )
        #expect(store.table.origin == .fallback)
    }

    @Test
    func aFreshFetchIsStoredAndPublished() async {
        let defaults = makeDefaults()
        let store = ExchangeRateStore(
            configStore: ConfigStore(defaults: defaults),
            fetcher: StubFetcher(result: .success(liveTable(rate: 6.5, at: Date())))
        )

        await store.refreshNow()

        #expect(store.table.origin == .live)
        #expect(store.table.rates["CNY"] == 6.5)
        #expect(ConfigStore(defaults: defaults).loadExchangeRate()?.rates["CNY"] == 6.5)
    }

    @Test
    func aFailedFetchKeepsTheCachedRate() async {
        let defaults = makeDefaults()
        let cache = ConfigStore(defaults: defaults)
        cache.saveExchangeRate(liveTable(rate: 6.4, at: Date().addingTimeInterval(-60)))

        let store = ExchangeRateStore(
            configStore: cache,
            fetcher: StubFetcher(result: .failure(StubError()))
        )
        await store.refreshNow()

        #expect(store.table.rates["CNY"] == 6.4)
        #expect(store.table.origin == .cache)
    }

    @Test
    func aFreshCacheIsNotRefetched() async {
        let defaults = makeDefaults()
        let cache = ConfigStore(defaults: defaults)
        cache.saveExchangeRate(liveTable(rate: 6.4, at: Date()))

        let store = ExchangeRateStore(
            configStore: cache,
            fetcher: StubFetcher(result: .success(liveTable(rate: 9.9, at: Date())))
        )
        await store.refreshIfStale()

        #expect(store.table.rates["CNY"] == 6.4, "a cache younger than the TTL must not be refetched")
    }

    @Test
    func aStaleCacheIsRefetched() async {
        let defaults = makeDefaults()
        let cache = ConfigStore(defaults: defaults)
        cache.saveExchangeRate(liveTable(rate: 6.4, at: Date().addingTimeInterval(-ExchangeRateStore.ttl - 60)))

        let store = ExchangeRateStore(
            configStore: cache,
            fetcher: StubFetcher(result: .success(liveTable(rate: 9.9, at: Date())))
        )
        await store.refreshIfStale()

        #expect(store.table.rates["CNY"] == 9.9)
        #expect(store.table.origin == .live)
    }

    @Test
    func aFallbackTableIsAlwaysConsideredStale() {
        let store = ExchangeRateStore(
            configStore: ConfigStore(defaults: makeDefaults()),
            fetcher: StubFetcher(result: .failure(StubError()))
        )
        #expect(store.isStale)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter ExchangeRateStoreTests`
Expected: 编译失败，`cannot find 'ExchangeRateStore' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/TokenHealth/ExchangeRateStore.swift`：

```swift
import Foundation

/// 汇率来源。抽成协议是为了让缓存与回退逻辑能在测试里不碰网络。
protocol ExchangeRateFetching: Sendable {
    func fetchTable() async throws -> ExchangeRateTable
}

/// Frankfurter 提供 ECB 数据，无需 API key，返回形如
/// `{"amount":1.0,"base":"USD","date":"2026-09-23","rates":{"CNY":6.7074}}`。
struct FrankfurterRateFetcher: ExchangeRateFetching {
    static let endpoint = URL(string: "https://api.frankfurter.app/latest?from=USD&to=CNY")!

    var session: URLSession = .shared

    private struct Response: Decodable {
        let base: String
        let rates: [String: Double]
    }

    func fetchTable() async throws -> ExchangeRateTable {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.rates.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return ExchangeRateTable(
            base: decoded.base,
            rates: decoded.rates,
            fetchedAt: Date(),
            origin: .live
        )
    }
}

/// 持有当前汇率，负责抓取与回退。AppState 拥有它并把 `table` 发布出去。
@MainActor
final class ExchangeRateStore {
    static let ttl: TimeInterval = 12 * 60 * 60

    private let configStore: ConfigStore
    private let fetcher: any ExchangeRateFetching
    private var isRefreshing = false

    private(set) var table: ExchangeRateTable

    init(
        configStore: ConfigStore = ConfigStore(),
        fetcher: any ExchangeRateFetching = FrankfurterRateFetcher()
    ) {
        self.configStore = configStore
        self.fetcher = fetcher
        table = configStore.loadExchangeRate() ?? .fallback
    }

    var isStale: Bool {
        Date().timeIntervalSince(table.fetchedAt) >= Self.ttl
    }

    /// 启动与每次刷新后调用；只有缓存过期才真的发请求。
    @discardableResult
    func refreshIfStale() async -> ExchangeRateTable {
        guard isStale else {
            return table
        }
        return await refreshNow()
    }

    /// 设置里的手动刷新按钮。
    @discardableResult
    func refreshNow() async -> ExchangeRateTable {
        guard !isRefreshing else {
            return table
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await fetcher.fetchTable()
            table = fetched
            configStore.saveExchangeRate(fetched)
            return fetched
        } catch {
            // 拿不到就用手里最好的那份：有缓存标 cache，没有就还是 fallback。
            // 这是展示层的降级，不写 AppState.lastError。
            if table.origin == .live {
                table = ExchangeRateTable(
                    base: table.base,
                    rates: table.rates,
                    fetchedAt: table.fetchedAt,
                    origin: .cache
                )
            }
            return table
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter ExchangeRateStoreTests`
Expected: `Test run with 6 tests passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/ExchangeRateStore.swift Tests/TokenHealthTests/ExchangeRateStoreTests.swift
git commit -m "$(cat <<'EOF'
Fetch and cache the USD to CNY rate

Frankfurter serves ECB data without an API key; a failed fetch keeps the
last good rate, and a first-run failure falls back to a marked default.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 10: MenuBarItemRenderer

**Files:**
- Create: `Sources/TokenHealth/MenuBarItemRenderer.swift`

渲染层不做单元测试：可验证的部分已经在 `MenuBarItemLayout` 与 `MenuBarMetrics` 里，
这里只保留「按布局画」这一步，靠 Task 15 的手动验收覆盖。

- [ ] **Step 1: 实现**

创建 `Sources/TokenHealth/MenuBarItemRenderer.swift`：

```swift
import AppKit

/// 把一份布局画成菜单栏项用的位图。
enum MenuBarItemRenderer {
    static let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// 金额型内容的文本宽度。布局层拿不到字体度量，所以由这里量好传进去。
    static func amountWidth(for metrics: [MenuBarMetric]) -> CGFloat {
        guard let text = MenuBarItemLayout.amountText(in: metrics) else {
            return 0
        }
        return (text as NSString).size(withAttributes: [.font: amountFont]).width
    }

    static func image(
        layout: MenuBarItemLayout,
        kind: ProviderKind,
        metrics: [MenuBarMetric],
        iconColor: NSColor,
        scale: CGFloat
    ) -> NSImage {
        let pointSize = layout.size
        let pixelSize = NSSize(
            width: max(1, (pointSize.width * scale).rounded()),
            height: max(1, (pointSize.height * scale).rounded())
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: pointSize)
        }

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        draw(layout: layout, kind: kind, metrics: metrics, iconColor: iconColor)
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = false
        return image
    }

    private static func draw(
        layout: MenuBarItemLayout,
        kind: ProviderKind,
        metrics: [MenuBarMetric],
        iconColor: NSColor
    ) {
        if let iconRect = layout.iconRect {
            ProviderIcon.image(for: kind, size: iconRect.width, tint: iconColor)
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let trackColor = iconColor.withAlphaComponent(0.18)
        for track in layout.tracks {
            trackColor.setFill()
            NSBezierPath(
                roundedRect: track,
                xRadius: MenuBarItemLayout.barWidth / 2,
                yRadius: MenuBarItemLayout.barWidth / 2
            ).fill()
        }

        let severities = metrics.compactMap(\.severity)
        for (index, fill) in layout.fills.enumerated() where fill.height > 0 {
            fillColor(for: index < severities.count ? severities[index] : nil).setFill()
            NSBezierPath(
                roundedRect: fill,
                xRadius: MenuBarItemLayout.barWidth / 2,
                yRadius: MenuBarItemLayout.barWidth / 2
            ).fill()
        }

        if let amountRect = layout.amountRect,
           let text = MenuBarItemLayout.amountText(in: metrics) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: amountFont,
                .foregroundColor: iconColor
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            string.draw(
                at: NSPoint(
                    x: amountRect.minX,
                    y: amountRect.midY - textSize.height / 2
                )
            )
        }
    }

    /// 阈值与菜单卡片保持一致：≥90% 红、≥70% 橙、其余绿。
    private static func fillColor(for severity: Double?) -> NSColor {
        guard let severity else {
            return .systemGreen
        }
        if severity >= 0.9 {
            return .systemRed
        }
        if severity >= 0.7 {
            return .systemOrange
        }
        return .systemGreen
    }
}
```

- [ ] **Step 2: 编译确认**

Run: `swift build 2>&1 | tail -20`
Expected: 构建成功。（`swift build` 不需要 Testing.framework，正常可用。）

- [ ] **Step 3: 跑全量测试**

Run: `bash scripts/test.sh`
Expected: 全绿。

- [ ] **Step 4: 提交**

```bash
git add Sources/TokenHealth/MenuBarItemRenderer.swift
git commit -m "$(cat <<'EOF'
Draw the pinned menu bar item

Composes the logo, the per-window bars and the DeepSeek amount into one
non-template image, since a template image would flatten the bar colors.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 3: 接线与界面

### Task 11: AppState 接线

**Files:**
- Modify: `Sources/TokenHealth/AppState.swift`
- Test: `Tests/TokenHealthTests/AppStatePinnedProviderTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/TokenHealthTests/AppStatePinnedProviderTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

@MainActor
struct AppStatePinnedProviderTests {
    private func makeState(defaults: UserDefaults) -> AppState {
        AppState(
            configStore: ConfigStore(defaults: defaults),
            usageReporter: UsageReporter()
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "app-state-pin-tests-\(UUID().uuidString)")!
    }

    @Test
    func pinningIsExclusiveAndPersists() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let first = state.addConfig(providerKind: .kimiCode)
        let second = state.addConfig(providerKind: .zhipuCode)

        state.setPinnedConfigID(first)
        #expect(state.pinnedConfigID == first)

        state.setPinnedConfigID(second)
        #expect(state.pinnedConfigID == second)
        #expect(ConfigStore(defaults: defaults).loadPinnedConfigID() == second)
    }

    @Test
    func unpinningClearsTheStoredValue() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let id = state.addConfig(providerKind: .kimiCode)

        state.setPinnedConfigID(id)
        state.setPinnedConfigID(nil)

        #expect(state.pinnedConfigID == nil)
        #expect(ConfigStore(defaults: defaults).loadPinnedConfigID() == nil)
    }

    @Test
    func deletingThePinnedConfigClearsThePin() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let pinned = state.addConfig(providerKind: .kimiCode)
        let other = state.addConfig(providerKind: .zhipuCode)

        state.setPinnedConfigID(pinned)
        #expect(state.deleteConfig(id: pinned))

        #expect(state.pinnedConfigID == nil)
        #expect(state.pinnedConfigID != other)
    }

    @Test
    func deletingAnotherConfigKeepsThePin() {
        let defaults = makeDefaults()
        let state = makeState(defaults: defaults)
        let pinned = state.addConfig(providerKind: .kimiCode)
        let other = state.addConfig(providerKind: .zhipuCode)

        state.setPinnedConfigID(pinned)
        #expect(state.deleteConfig(id: other))

        #expect(state.pinnedConfigID == pinned)
    }

    @Test
    func pinnedSnapshotIsReachableByID() {
        let state = makeState(defaults: makeDefaults())
        let id = state.addConfig(providerKind: .kimiCode)
        state.setPinnedConfigID(id)

        #expect(state.pinnedConfig?.id == id)
        #expect(state.pinnedSnapshot == nil, "no refresh has run yet")

        state.snapshots[id] = ProviderUsageSnapshot(
            id: id,
            serviceName: "Kimi",
            providerTitle: "Kimi Code",
            usages: [TokenUsage(window: .fiveHours, used: 1, limit: 10)],
            state: .ready,
            statusMessage: "ok",
            updatedAt: Date()
        )

        #expect(state.pinnedSnapshot?.usages.count == 1)
    }

    @Test
    func pinnedConfigIsNilWhenThePinPointsNowhere() {
        let state = makeState(defaults: makeDefaults())
        state.setPinnedConfigID(UUID())

        #expect(state.pinnedConfig == nil)
        #expect(state.pinnedSnapshot == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh --filter AppStatePinnedProviderTests`
Expected: 编译失败，`value of type 'AppState' has no member 'setPinnedConfigID'`

- [ ] **Step 3: 实现**

在 `Sources/TokenHealth/AppState.swift` 里：

属性区加：

```swift
    @Published var pinnedConfigID: UUID?
    @Published private(set) var exchangeRate: ExchangeRateTable
```

`init` 里，在 `refreshInterval = ...` 之后加：

```swift
        pinnedConfigID = configStore.loadPinnedConfigID()
        exchangeRate = rateStore.table
```

新增私有属性与初始化参数：

```swift
    private let rateStore: ExchangeRateStore
```

```swift
    init(
        configStore: ConfigStore = ConfigStore(),
        usageReporter: UsageReporter = UsageReporter(),
        rateStore: ExchangeRateStore? = nil
    ) {
        self.configStore = configStore
        self.usageReporter = usageReporter
        let resolvedRateStore = rateStore ?? ExchangeRateStore(configStore: configStore)
        self.rateStore = resolvedRateStore
        configs = configStore.loadConfigs()
        ...
```

（`rateStore` 声明成参数可以为测试注入桩，但它的默认构造要用同一个 `configStore`。）

`normalizeReportProviderSelection()` 之后、`scheduleNextRefresh()` 之前加：

```swift
        normalizePinnedConfigID()
```

新增方法：

```swift
    var pinnedConfig: ServiceConfig? {
        guard let pinnedConfigID else {
            return nil
        }
        return configs.first { $0.id == pinnedConfigID }
    }

    var pinnedSnapshot: ProviderUsageSnapshot? {
        guard let pinnedConfigID else {
            return nil
        }
        return snapshots[pinnedConfigID]
    }

    func setPinnedConfigID(_ id: UUID?) {
        guard pinnedConfigID != id else {
            return
        }
        pinnedConfigID = id
        configStore.savePinnedConfigID(id)
    }

    /// 指向已不存在的账号时清掉，避免 UI 一直等一个不会来的配置。
    private func normalizePinnedConfigID() {
        guard let pinnedConfigID, !configs.contains(where: { $0.id == pinnedConfigID }) else {
            return
        }
        setPinnedConfigID(nil)
    }

    func refreshExchangeRate(force: Bool = false) async {
        let updated = force ? await rateStore.refreshNow() : await rateStore.refreshIfStale()
        if updated != exchangeRate {
            exchangeRate = updated
        }
    }
```

`deleteConfig` 成功分支里，在 `snapshots[id] = nil` 之后加：

```swift
            if pinnedConfigID == id {
                setPinnedConfigID(nil)
            }
```

`refreshAll` 的 `defer` 之后（即每次刷新结束）加：

```swift
        await refreshExchangeRate()
```

注意顺序：`refreshExchangeRate()` 要放在 `defer { ... }` 覆盖的范围之外还是之内都可以，但要确保它在 `isRefreshing` 复位之后再跑，避免设置界面在刷新汇率时显示「Refreshing」。放在 `for` 循环之后、方法体末尾即可。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh --filter AppStatePinnedProviderTests`
Expected: `Test run with 6 tests passed`

- [ ] **Step 5: 跑全量测试**

Run: `bash scripts/test.sh`
Expected: 全绿。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/AppState.swift Tests/TokenHealthTests/AppStatePinnedProviderTests.swift
git commit -m "$(cat <<'EOF'
Track the pinned account and the exchange rate in AppState

Pinning is exclusive, survives relaunch, and clears itself when the
account it points at is deleted.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 12: PinnedStatusItemController

**Files:**
- Create: `Sources/TokenHealth/PinnedStatusItemController.swift`

AppKit 与通知驱动，不做单元测试，靠 Task 15 的手动验收覆盖。

- [ ] **Step 1: 实现**

创建 `Sources/TokenHealth/PinnedStatusItemController.swift`：

```swift
import AppKit
import Combine

/// 拥有那个钉住的菜单栏项：订阅 AppState，重算指标，重绘，弹菜单。
@MainActor
final class PinnedStatusItemController {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var pendingRedraw: DispatchWorkItem?

    /// 状态项在 NSApplication 启动完成前创建会被系统丢掉，所以首次重绘挂在启动通知上。
    private var hasLaunched = false

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        NotificationCenter.default
            .publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                self?.hasLaunched = true
                self?.scheduleRedraw()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeEffectiveAppearanceNotification)
            .sink { [weak self] _ in
                self?.scheduleRedraw()
            }
            .store(in: &cancellables)

        // objectWillChange 在变更之前发出，所以只用来触发一次延后重绘。
        appState.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleRedraw()
            }
            .store(in: &cancellables)

        hasLaunched = NSApp.isFinishedLaunching
        redraw()
    }

    func stop() {
        cancellables.removeAll()
        removeStatusItem()
    }

    // MARK: - 重绘

    /// 一次刷新会连着改好几个 @Published，去抖一下只画最后一帧。
    private func scheduleRedraw() {
        pendingRedraw?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.redraw()
        }
        pendingRedraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func redraw() {
        guard hasLaunched, let config = appState.pinnedConfig, config.isEnabled else {
            removeStatusItem()
            return
        }

        let metrics = MenuBarMetrics.metrics(
            for: appState.pinnedSnapshot,
            kind: config.providerKind,
            displayCurrency: config.displayCurrency,
            rateTable: appState.exchangeRate
        )
        let displayMetrics = metrics.isEmpty ? [MenuBarMetrics.placeholder] : metrics
        let iconColor = Self.iconColor(for: NSApp.effectiveAppearance)
        let layout = MenuBarItemLayout.make(
            metrics: displayMetrics,
            hasIcon: true,
            amountWidth: MenuBarItemRenderer.amountWidth(for: displayMetrics)
        )
        let image = MenuBarItemRenderer.image(
            layout: layout,
            kind: config.providerKind,
            metrics: displayMetrics,
            iconColor: iconColor,
            scale: NSScreen.main?.backingScaleFactor ?? 2
        )

        let item = ensureStatusItem()
        item.length = image.size.width + MenuBarItemLayout.statusItemPadding
        item.button?.image = image
        item.button?.toolTip = MenuBarMetrics.tooltipText(
            serviceName: config.displayName,
            metrics: metrics,
            statusMessage: appState.pinnedSnapshot?.statusMessage
        )
        item.menu = makeMenu(displayName: config.displayName)
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        created.autosaveName = "TokenHealthPinned"
        statusItem = created
        return created
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    /// 菜单栏外观决定 logo 画成白还是黑 —— 这是「单色模板」的效果，
    /// 但因为整张图必须保留竖条的颜色，只能自己解析。
    private static func iconColor(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .white : .black
    }

    // MARK: - 菜单

    private func makeMenu(displayName: String) -> NSMenu {
        let menu = NSMenu()
        let unpin = NSMenuItem(
            title: "Unpin \(displayName)",
            action: #selector(unpin),
            keyEquivalent: ""
        )
        unpin.target = self
        menu.addItem(unpin)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Token Health", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func unpin() {
        appState.setPinnedConfigID(nil)
    }

    @objc private func openSettings() {
        // SwiftUI 的 openSettings 环境值只在 View 里可用，这里走同一套 responder action。
        for selector in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector(selector), to: nil, from: nil) {
                break
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2: 编译确认**

Run: `swift build 2>&1 | tail -20`
Expected: 构建成功。

- [ ] **Step 3: 提交**

```bash
git add Sources/TokenHealth/PinnedStatusItemController.swift
git commit -m "$(cat <<'EOF'
Own the pinned status item

Subscribes to AppState, composes the image, follows the menu bar's
appearance for the logo colour, and offers unpin, settings and quit on
a click.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 13: 在 App 里启动控制器

**Files:**
- Modify: `Sources/TokenHealth/TokenHealthApp.swift`

- [ ] **Step 1: 接线**

把 `Sources/TokenHealth/TokenHealthApp.swift` 改成：

```swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokenHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    private let pinnedItemController: PinnedStatusItemController

    init() {
        // 控制器要订阅 AppState 的整个生命周期，而 MenuBarExtra 的内容视图是懒加载的，
        // 挂在视图的 onAppear 上会让钉住项直到菜单被打开过才出现。
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        pinnedItemController = PinnedStatusItemController(appState: state)

        // App.init 在 NSApplicationMain 完成之前就跑，所以启动留给控制器自己等
        // didFinishLaunching 通知，见 PinnedStatusItemController.start()。
        DispatchQueue.main.async {
            pinnedItemController.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView()
                .environmentObject(appState)
                .frame(width: 360)
        } label: {
            Image(systemName: "bolt.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 760, height: 500)
        }
    }
}
```

- [ ] **Step 2: 构建并手工冒烟**

Run:
```bash
bash scripts/build-app.sh && open ".build/app/Token Health.app"
```
Expected: 菜单栏出现原来的 `bolt.circle`。没有 pin 时**不应**出现第二个图标。

- [ ] **Step 3: 提交**

```bash
git add Sources/TokenHealth/TokenHealthApp.swift
git commit -m "$(cat <<'EOF'
Start the pinned status item with the app

The controller outlives the lazy menu popover, so it is created next to
AppState instead of from a view's onAppear.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 14: 设置界面

**Files:**
- Modify: `Sources/TokenHealth/SettingsView.swift`

- [ ] **Step 1: 加 Menu Bar 分区**

在 `SettingsView.detail` 的配置表单里，紧跟第一个 `Section { ... }`（Name / Provider / Auth / Enabled）之后插入：

```swift
                Section("Menu Bar") {
                    Toggle("Pin to menu bar", isOn: pinBinding(for: binding))

                    if binding.wrappedValue.providerKind == .deepSeek {
                        Picker("Display currency", selection: binding.displayCurrency) {
                            Text("Original").tag(String?.none)
                            Text("CNY").tag(String?.some("CNY"))
                            Text("USD").tag(String?.some("USD"))
                        }

                        LabeledContent("Exchange rate") {
                            HStack(spacing: 6) {
                                Text(exchangeRateSummary)
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task {
                                        await appState.refreshExchangeRate(force: true)
                                    }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Refresh exchange rate")
                            }
                        }
                    }

                    Text("Shows one thin bar per quota window next to the provider logo. The other icon keeps managing everything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 2: 加绑定与文案**

在 `SettingsView` 里加：

```swift
    private func pinBinding(for binding: Binding<ServiceConfig>) -> Binding<Bool> {
        Binding {
            appState.pinnedConfigID == binding.wrappedValue.id
        } set: { isPinned in
            if isPinned {
                appState.setPinnedConfigID(binding.wrappedValue.id)
            } else if appState.pinnedConfigID == binding.wrappedValue.id {
                appState.setPinnedConfigID(nil)
            }
        }
    }

    private var exchangeRateSummary: String {
        let table = appState.exchangeRate
        guard let rate = table.rate(from: "USD", to: "CNY") else {
            return "Unavailable"
        }
        let value = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), rate)
        switch table.origin {
        case .live:
            return "USD → CNY \(value) · live · \(StatusMenuSummary.relativeAge(from: table.fetchedAt))"
        case .cache:
            return "USD → CNY \(value) · cached · \(StatusMenuSummary.relativeAge(from: table.fetchedAt))"
        case .fallback:
            return "USD → CNY \(value) · built-in default, never fetched"
        }
    }
```

`StatusMenuSummary.relativeAge` 已有默认参数 `now: Date()`，直接可用。

- [ ] **Step 3: 构建并手工验证**

Run:
```bash
bash scripts/build-app.sh && open ".build/app/Token Health.app"
```
Expected: 打开设置 → 选一个 Kimi 账号 → 「Menu Bar」里出现 `Pin to menu bar`；打开后菜单栏出现第二个图标。
选一个 DeepSeek 账号 → 多出币种选择器与汇率行。

- [ ] **Step 4: 提交**

```bash
git add Sources/TokenHealth/SettingsView.swift
git commit -m "$(cat <<'EOF'
Expose pinning and the DeepSeek display currency in settings

Pinning is a toggle on the account, and DeepSeek accounts also get the
target currency plus the provenance of the rate in use.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 15: 版本、文档与验收

**Files:**
- Modify: `AppSupport/Info.plist`
- Modify: `README.md`

- [ ] **Step 1: 找到版本号**

Run: `grep -n "CFBundleShortVersionString" -A 1 AppSupport/Info.plist`
Expected: 打印当前版本（应为 0.9.0）。

- [ ] **Step 2: 升到 0.10.0**

把 `CFBundleShortVersionString` 改成 `0.10.0`；若存在 `CFBundleVersion`，一并递增。

- [ ] **Step 3: 更新 README**

在「使用」一节末尾追加：

```markdown
### 钉住一个账号

在设置的账号详情里打开 **Menu Bar → Pin to menu bar**，菜单栏会出现第二个图标：左边是该 Provider 的官方 logo，
右边是每个额度窗口一根细竖条，条越高用得越多，颜色随用量从绿转橙转红，悬停可以看到各窗口的具体百分比。
原来的 `bolt.circle` 仍然是全局入口，两者互不影响，同一时间只能钉一个账号。

DeepSeek 账号还可以在同一个分区里选显示币种（原币种 / CNY / USD）。汇率每天自动从 ECB 数据源取一次，
取不到时沿用上一次的缓存；首次使用且拿不到汇率时会用内置默认值并在设置里明确标出。
换算只影响菜单栏那个数字，卡片与设置里始终显示原币种原值。
```

同时在「支持的服务」表格下方或「使用」开头保持不变，不要改动既有段落。

- [ ] **Step 4: 全量验收**

Run:
```bash
bash scripts/test.sh 2>&1 | tail -5
bash scripts/build-app.sh
```
Expected: 测试全绿；构建成功并打印 app 路径。

- [ ] **Step 5: 逐条走一遍手工验收**

对照 spec 第 8 节：

1. `bash scripts/fetch-provider-icons.sh` 输出 10 个 PDF；再跑一次应全部 `skip`。
2. 钉住 Kimi → 月亮 logo + 2 根条；把 5h 用到 70% 以上 → 该条变橙。
3. 钉住 Zhipu → 3 根条。
4. 钉住 DeepSeek → 显示金额；切到 USD → 数字变化；断网重启 → 仍有数字，设置里标注为 built-in default 或 cached。
5. 删除被钉的账号 → 图标消失；禁用 → 消失，重新启用 → 回来。
6. 全局 `bolt.circle` 的面板与改动前一致。
7. 点钉住项 → 菜单有 Unpin / Settings… / Quit，三者都生效。
8. 切换系统浅色/深色 → logo 颜色跟着反色，竖条颜色不变。

- [ ] **Step 6: 提交**

```bash
git add AppSupport/Info.plist README.md
git commit -m "$(cat <<'EOF'
Bump to 0.10.0 and document the pinned menu bar account

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: 收尾**

Run: `git log --oneline main..HEAD`
Expected: Task 0 起的全部提交都在分支上。

然后按 `superpowers:finishing-a-development-branch` 决定合并方式，并请用户确认。

---

## 已知风险

| 风险 | 应对 |
| --- | --- |
| `Bundle.module` 找不到资源 bundle 会 `fatalError` | Task 7 已在 `build-app.sh` 里加硬失败检查 |
| `NSApp.sendAction(showSettingsWindow:)` 在新系统上可能改名 | Task 12 里按 `showSettingsWindow:` → `showPreferencesWindow:` 依次尝试；Task 15 步骤 5.7 手工验证 |
| 状态项宽度按 `image.size.width + 6` 估的，可能与系统留白叠加 | Task 15 步骤 5.2/5.3 目视确认，必要时调 `statusItemPadding` |
| lobehub 图标库的 slug 若变更 | 脚本固定 `1.95.1`，不会随 `latest` 漂移；变更时改版本号即可复现 |
| Codex 的模型桶 label 格式若改变，账号级判定会失准 | 判定集中在 `UsageMetricSelection.isAccountLevel`，有测试钉住 |
