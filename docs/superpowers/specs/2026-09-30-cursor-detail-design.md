# Cursor 用量详情浮层 设计

日期：2026-09-30
状态：已批准（自主执行），待实现
版本：随 1.0.4 发布

## 1. 背景与目标

钉住项的详情浮层（`UsageDetail` + `DetailPopoverView`）已有 DeepSeek、OpenCode Go、Codex 三个填充方。
本次让 **Cursor** 也产出详情卡片：点钉住的 Cursor 项弹浮层，展示三条额度池的百分比（与菜单栏同源）、
今天 / 7 天 / 本计费周期的 token 汇总、周期内每日 token 趋势、周期花费明细（Included / Bonus / Total），
以及**按模型的 Grok bot 用量表**。

数据全部来自 **Cursor 官方接口**（用的是 app 已经在读的同一个本地 access token），不新增登录流程、
不碰凭据、不引入网页会话、不读除 `state.vscdb` 之外的新本地文件。

**目标**

- 点钉住的 Cursor 项 → 浮层展示：Auto + Composer / API / Grokbot 三条额度（带额度条）、
  今天 / 7 天 / 本周期的 tokens、周期内每日 tokens 趋势、花费拆分、Grok bot 按模型用量表。
- 与既有三个详情同一路数：`DetailPopoverView` 与 `UsageDetail` 零改动，数据来自新取回的响应。
- 额度是必需项、其余是可选区块：新增的两条取数**报错或解不出**不得影响额度与菜单栏数字。

**非目标**

- 不做全模型用量表（只做 Grok bot 那张，见 §7.5 的理由）。
- 不做交互：趋势图不可悬停，没有筛选、日期范围选择、下钻。
- 不展示**按模型的花费**：能给出 per-model 花费的接口（`GetAggregatedUsageEvents`）不含
  `grok-bot-*` 行，拿它求和会得出一个「悄悄漏掉了 Grok bot」的金额（§11）。
- 不改菜单栏、不改卡片、不改刷新节奏、不改凭据读取方式、不改 `ProviderFactory` 之外的 provider 判定。
- 不搬 Cursor 的 `GetCurrentPeriodUsage`：它的 `auto_spend` / `api_spend` / `remaining` 等字段
  实测**服务端不填**（JSON 里缺席），能拿到的量在 `usage-summary` 里已有。

## 2. 数据来源（2026-09-30 在本机 pro 账号实测）

### 2.1 `GET https://api2.cursor.sh/auth/usage-summary`（已在用，本次只多解两个字段）

```json
{
  "billingCycleStart": "2026-08-30T07:13:20.000Z",
  "billingCycleEnd": "2026-09-30T07:13:20.000Z",
  "membershipType": "pro",
  "limitType": "user",
  "isUnlimited": false,
  "individualUsage": {
    "plan": {
      "enabled": true, "used": 2000, "limit": 2000, "remaining": 0,
      "breakdown": { "included": 2000, "bonus": 43019, "total": 45019 },
      "autoPercentUsed": 94.87333333333333,
      "apiPercentUsed": 100,
      "totalPercentUsed": 95.27830687830688
    },
    "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
  },
  "teamUsage": {}
}
```

必须写进实现的三条：

1. **`plan.breakdown` 的三个金额单位是「分」**：`included` 2000 = $20（Pro 的包含额度）、
   `bonus` 43019 = $430.19（Cursor 的合作方赠送额度）、`total` 45019 = $450.19。
   实测与 `GetAggregatedUsageEvents.totalCostCents` 的 45019.26 对上，确认是分。
2. **本账号的响应里没有 `grokbotPercentUsed`**（`plan` 里没有该键）。它只在 Cursor 单独开出
   Grokbot 池的账号上出现，既有 mapper 的「并入 Auto」兜底就是为这种账号写的，本次不动。
3. `remaining` / `used` / `limit` 同样是分，本次不用（浮层已有三条池的百分比）。

### 2.2 `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetDailySpendByCategory`（本次新增）

Connect 协议一元调用，报文体（字段名 camelCase / snake_case 都收，实测两种都 200；
`Connect-Protocol-Version` 头可带可不带，实现里带上）：

```json
{ "teamId": 0, "periodStartMs": 1785542400000, "periodEndMs": 1790752400000, "groupBy": 0 }
```

响应：

```json
{
  "dailySpend": [
    { "day": "1788134400000", "category": "cursor-grok-4.6-high", "totalTokens": "49474832" },
    { "day": "1788307200000", "category": "grok-bot-default", "totalTokens": "39047" }
  ],
  "categories": ["cursor-grok-4.6-high", "grok-bot-default", "Other", "…"]
}
```

必须写进实现的性质：

1. **`day` 是 UTC 自然日零点的毫秒时间戳，且 JSON 里是字符串**；`totalTokens` 同样是字符串。
   两个字段都要按「字符串或数字」宽松解码（`decodeFlexibleInt64IfPresent` 那一路）。
2. **`spendCents` 字段在协议里有、服务端不填**：本机所有响应里该键都缺席（proto3 省略 0）。
   所以这一路只能拿 **tokens**，拿不到按天花费。浮层因此不做按天花费趋势。
3. **`category` 由 `groupBy` 决定**：`0` = 模型名（本次用这个）、`2` = 花费类型（`included`）、
   `3` = `user` / `automation`。默认（不传 `groupBy`）即 0，实现里显式传 0。
4. **范围可以超出当前计费周期**：实测请求 8/1–9/30 时返回了 8/3 起的数据；
   完全落在未来的范围返回 `{}`（`dailySpend` 键缺席）。因此「7 天」窗口在周期刚开始时也拿得到数据。
5. **`dailySpend` 缺席 = 没数据**（`{}`），不是空数组。两种都当「没有按天数据」处理，但**只有缺席**才不画区块，
   空数组会画成三行 0（与 Codex 的 `dailyUsageBuckets` 同一条口径）。
6. **`grok-bot-default` / `grok-bot-automation` 是真实的分类**：本机一个周期内
   `grok-bot-default` 114.3M tokens（1000 条事件里 723 条）、`grok-bot-automation` 3.2M。
   这正是用户要看的「Grok bot 用量」，只在这条接口里出现。
7. 体积：30 天约 5–6 KB（77 行 / 33 天 / 6.2 KB 实测），远低于既有 1 MB 上限。

> 上面两份示例是 2026-09-30 某刻的真实抓包，**只用来固定形状**，不是验收时的预期值。

## 3. 取数

`CursorUsageProvider.fetchUsage` 从「一次请求」变成「两次请求」：

1. `GET /auth/usage-summary`（必需，与今天完全一致）：失败时整次刷新按今天的方式失败。
2. `POST GetDailySpendByCategory`（可选）：**只有第 1 步映射成功后才发**；失败（网络错、
   非 2xx、解不出）→ `dailySpend = nil`，**不抛错**，额度照常 ready。

请求范围由周期决定（`today` 由调用方传入）：

```
windowStart = cycleStart ?? today - 29 天   // UTC
windowEnd   = cycleEnd   ?? today
periodStart = min(windowStart, today - 6 天)   // 「7 天」行在周期刚开始时也要有数
periodEnd   = max(windowEnd, today)
```

`CursorUsageClient` 增加：

```swift
func fetchDailySpend(accessToken: String, periodStartMs: Int64, periodEndMs: Int64) async throws -> CursorDailySpendResponse
```

超时 20 秒、`maxResponseBytes` 1 MB、401/403 → `sessionExpired`：与既有 `fetchUsage` 同参数。
新增的失败不引入新的 error case（解不出就是 `dailySpend = nil`）。

**快照构造抽成纯函数**（对齐 `CodexUsageProvider.snapshot(config:bundle:fetchedAt:today:)` 的既有做法）：

```swift
/// internal 而非 private：测试拿合成数据与固定 today 直接测这一层，不碰 UTC 午夜。
func snapshot(
    config: ServiceConfig,
    mapped: CursorMappedUsage,
    dailySpend: CursorDailySpendResponse?,
    fetchedAt: Date,
    today: Date
) -> ProviderUsageSnapshot
```

`CursorMappedUsage` 增加两个字段（`planName` / `usages` 不动）：

```swift
struct CursorMappedUsage: Equatable, Sendable {
    let planName: String?
    let usages: [TokenUsage]
    let billingCycleStart: Date?
    let billingCycleEnd: Date?
}
```

周期解析沿用既有 `parseDate`（带/不带小数秒的 ISO8601），两个字段各自可缺。

### 3.1 解码形状

```swift
struct CursorDailySpendResponse: Decodable, Sendable {
    let dailySpend: [CursorDailySpendRow]?
}

struct CursorDailySpendRow: Decodable, Sendable {
    let day: String?          // 毫秒时间戳，字符串或数字
    let category: String?
    let totalTokens: String?  // 同上
}
```

- 每个字段宽容解码（`decodeCursorInt64IfPresent`：字符串 / 数字都认）。
- **整份响应解不出**（比如 `dailySpend` 不是数组）→ `dailySpend = nil`。
- **单行坏数据整条忽略**（`day` 缺 / 解析不出、`totalTokens` 缺 / 为负、`category` 空），不当 0：
  0 是「那天没用」，缺字段是「不知道」。

## 4. 触发

```swift
case .codex, .cursor:
    // 两者都是 usesLocalLogin：AppState.saveConfigs() 把它们的 authMode 固定成 .api，
    // 所以这一支不能看 authMode（与 DeepSeek / OpenCode Go 那条规则不同）。
    true
```

**行为变化**（与 OpenCode Go / Codex 上线时同款，需在验收里确认）：钉住的 Cursor 项点开变成浮层，
不再是 Unpin / Settings / Quit 小菜单。没装 Cursor、没登录、或取数失败的账号看到的是浮层里的错误行，
底部三个按钮仍在。

## 5. 详情填充规则

新增 `Sources/TokenHealth/CursorUsageDetail.swift`：

```swift
enum CursorUsageDetail {
    static func make(
        usages: [TokenUsage],
        cycle: (start: Date, end: Date)?,
        dailySpend: CursorDailySpendResponse?,
        today: Date
    ) -> UsageDetail?
}
```

不抛错；四个区块都填不出来就返回 nil（浮层退回错误行）。**时间锚点显式注入**：
「今天」与所有窗口按传入 `today` 的 UTC 自然日推导，构建器内部不取 `Date()`。

窗口：

| 名字 | 定义 |
| --- | --- |
| 今天 | `today` 当天（UTC） |
| 7 天 | `[today-6, today]`（UTC，滚动） |
| **本周期** | `cycle == nil` 时退化为 `[today-29, today]`，行标题也相应变成 `30 days` |

### 5.1 headline（额度，与菜单栏同源）

直接取 `UsageMetricSelection.pinnedMetrics(from: usages, kind: .cursor)`，逐条：

- `label` = `MenuBarMetrics.shortLabel(for:)` → Cursor 走 usage 自带的 label：`Auto + Composer` / `API` / `Grokbot`
- `value` = `UsageAmountFormatter.exactAmountText(_)` → `95%`
- `ratio` = `usage.ratio` → 浮层画额度条

**不要自己写百分比格式**：复用是为了让浮层与菜单栏 tooltip 永远同源。label 撞车时只留第一条
（`DetailStat.id == label` 的唯一性不变量），与 Codex 那条规则一致（Cursor 的 label 天然唯一，兜底而已）。

### 5.2 groups（今天 / 7 天 / 本周期）

来自按天数据，**所有 category 求和**（Grok bot 也在内），UTC 自然日：

- 行：`Today` / `7 days` / `Billing cycle`（周期未知时第三行是 `30 days`）
- 列：`Tokens`（`UsageAmountFormatter.compactAmount`）
- 没有数据的那天就是 0，行照画；求和用 `UsageDetailSupport.saturatingAdd`。
- `dailySpend == nil`（接口缺席或失败）→ **整段不画**；空数组 → 照画三行 0。

### 5.3 series（每日 tokens）

- 覆盖 `[windowStart, windowEnd]`（UTC）逐日一点，缺的日期补 0，同一天多条求和。
- `title` = `Tokens · billing cycle`（周期未知时 `Tokens · last 30 days`）
- `axisStart` / `axisEnd` = 起止日 `M/d`
- `emptyText` = `No usage in this billing cycle`（周期未知时 `No usage in the last 30 days`）

### 5.4 breakdown（花费 + 重置日）

四项，**各自的源为 nil 就不占位**；全缺 → 整段不画：

| label | 来源 | 呈现 |
| --- | --- | --- |
| `Included` | `plan.breakdown.included` | 分 → `$20.00` |
| `Bonus` | `plan.breakdown.bonus` | `$430.19` |
| `Total` | `plan.breakdown.total` | `$450.19` |
| `Resets` | `billingCycleEnd` | `M/d` → `9/30` |

- 金额走 `UsageAmountFormatter.moneyText(Decimal(cents) / 100)`，**前缀 `$` 由调用方加**
  （`moneyText` 按设计不带单位）。负数（坏数据）不占位。
- `breakdown` 缺席（老响应）→ 只少 `Total` 一类项，`Resets` 照画。

### 5.5 table（Grok bot 用量，本次的主角）

一行一个 grok 模型，数据来自按天数据里 **category 含 `grok`（不区分大小写）** 的那些行：

- 时间范围：**本周期**（周期未知时退化为 30 天）内的行，与 §5.2 的第三行同窗口。
- `title` = `Grok bot · this cycle`（周期未知时 `Grok bot · last 30 days`）
- `columns` = `["Model", "Tokens"]`；`name` = category 原文（`cursor-grok-4.6-high` 这类显示原文，
  不美化 —— 名字是 Cursor 的，改写了就对不上它自己的面板）。
- 排序：tokens 降序，其次名字升序（稳定、可断言）。
- 最多 6 行（`tableRowLimit`，与 `OpenCodeGoUsageDetail` 同值），截断时 `footnote = "+N more models"`。
- 一个 grok 模型都没有 → `table = nil`，浮层不画这段（「如有详细的」的兜底）。

### 5.6 不做的区块

- 全模型表：`table` 只有 Grok bot 一张（§11）。
- 按天花费趋势：接口不填 `spendCents`（§2.2）。
- `onDemand`（按需付费）：本机 `enabled: false`，且浮层没有对应的呈现位；本次不解码。

## 6. 文案表

| 位置 | 文案 |
| --- | --- |
| headline | label 取自 usage 自带 label（`Auto + Composer` / `API` / `Grokbot`）；value 取自 `exactAmountText`（`95%`） |
| 分组 | 列 `Tokens`；行 `Today` / `7 days` / `Billing cycle`（退化 `30 days`） |
| 趋势图 | `Tokens · billing cycle`（退化 `Tokens · last 30 days`）；无数据 `No usage in this billing cycle`（退化 `No usage in the last 30 days`） |
| 花费行 | `Included` / `Bonus` / `Total` / `Resets` |
| 表 | `Grok bot · this cycle`（退化 `Grok bot · last 30 days`）；列 `Model` / `Tokens`；脚注 `+N more models` |

## 7. 错误与边界

| 情况 | 表现 |
| --- | --- |
| 没装 Cursor / 没登录 | 与今天一致：`.needsConfiguration` + 浮层错误行 |
| `usage-summary` 401/403 | 与今天一致：`sessionExpired`（`.needsConfiguration`） |
| `usage-summary` 其它失败 | 与今天一致：`.unavailable` + 错误行 |
| `GetDailySpendByCategory` 失败 / 解不出 / 返回 `{}` | `dailySpend = nil`：详情只剩 headline + 花费行，额度与菜单栏数字照常 ready |
| 按天数据为空数组 | 三行全 0、趋势图走 `emptyText`、无表 |
| 某行 `day` 解析失败 / `totalTokens` 缺失或为负 / `category` 空 | 该行忽略 |
| `billingCycleStart/End` 缺失或解析失败 | 窗口退化为最近 30 天；`Resets` 不占位；行/图/表标题用退化文案 |
| `plan.breakdown` 缺席 | 三项金额都不占位，`Resets` 照画 |
| 额度窗口为空（`usages.isEmpty`） | 与今天一致 `invalidResponse` / `.unavailable`，不产详情 |
| 刷新失败但有旧 detail | 沿用 `AppState.storeSnapshot` 的「非 ready 且无新 detail 时保留上次 detail」 |

## 8. 测试策略

跑测试一律 `bash scripts/test.sh`（本机只有 CommandLineTools）。

| 测试 | 覆盖 |
| --- | --- |
| `CursorUsageDetailTests`（新） | headline 顺序与文案（`Auto + Composer` / `API` / `Grokbot`）、比例透传；三行汇总（补 0、同日求和、周期外不计入、空数组、nil 不画）；趋势 30 点与轴文案、退化窗口；breakdown 四项与各自缺失时的降级、分→元换算（`2000` → `$20.00`）、负数不占位；Grok bot 表的筛选（大小写、`grok-bot-*` 与 `cursor-grok-*` 都在内、`Other` 不在内）、tokens 降序、6 行截断与脚注、无 grok 行时不画表；`today` 注入固定时刻 + 一条下午锚点用例；饱和加法不许 trap |
| `CursorUsageProviderTests`（扩） | mapper 多解周期两个字段（有 / 无 / 解不出）；`snapshot(config:mapped:dailySpend:fetchedAt:today:)` 纯函数层：带按天数据 → `ready` 且区块齐全；`dailySpend` 为 nil → 只剩 headline + breakdown；无额度窗口 → `unavailable` 且无 detail；请求范围计算（周期内 / 周期刚开始要往前多取 6 天 / 周期未知退化 30 天） |
| `CursorDailySpendDecodingTests`（并入上一条文件） | 字符串 / 数字两种 `day` 与 `totalTokens`；`dailySpend` 缺席与 `{}`；坏行忽略 |
| `ProviderDetailCapabilityTests`（扩） | `.cursor` 在两种 authMode 下都为真；`everyOtherProviderIsUnsupported` 的例外集合加上 `.cursor` |
| 既有测试 | 全绿（`CursorTestSupport` 若需新 helper 一并加） |

## 9. 已知取舍

- **只做 Grok bot 的表，不做全模型表**：用户这次要的就是 Grok bot 用量；全模型表要等有 per-model 花费的
  可用接口（见下条）。多一张表还会把 320pt 宽的浮层撑长。
- **不展示 per-model 花费**：`GetAggregatedUsageEvents` 能给出 per-model 的 tokens + 花费，
  但**不含 `grok-bot-*` 行** —— 实测该接口的 `totalCostCents` 与 `plan.breakdown.total` 相等，
  而 Grok bot 的 114M tokens 不在它的聚合里。用它求和得到的「Grok bot 花费」会悄悄漏掉最大的一块，
  宁可不显示（与 `MenuBarMetrics.deepSeekMetrics` 里「宁可显示原币种，也不要给出一个悄悄漏掉了某个钱包的合计」同一条原则）。
- **`Other` 这一分类不归入 Grok bot**：它按定义是「没归到具体模型的量」，无法归属，所以 Grok bot 表的
  合计会略小于真实值。表里不写合计行，避免把不完整的数当成完整的。
- **多一次请求**：每次刷新 1 → 2 次（多出来的约 6 KB / 30 天）。最短刷新间隔 30 秒，量级可以接受；
  不加缓存 —— 既有 Cursor 路径本来就没有缓存，为一条可选请求引入缓存会是本次唯一的额外状态。
- **`used` / `limit` / `remaining` 不解码**：浮层不展示它们（三条池的百分比已经表达了同一件事）。
- **不做按天花费**：接口不填 `spendCents`，不是我们没接。

## 10. 验收

1. `bash scripts/test.sh` 全绿。
2. `bash scripts/build-app.sh` 通过，装到 `/Applications/Token Health.app`，用
   `plutil -extract CFBundleShortVersionString raw` 核对是 **1.0.4**。
3. 手动：点钉住的 Cursor 项 → 浮层出现 `Auto + Composer` / `API` / `Grokbot` 三条带条的百分比、
   Today / 7 days / Billing cycle 的 tokens、周期内每日 token 柱状图、
   `Included` / `Bonus` / `Total` / `Resets` 四项、`Grok bot · this cycle` 表。
4. 手动：headline 的百分比与菜单栏项 tooltip 逐字一致。
5. 手动：Grok bot 表的模型名与 Cursor 自己面板上的模型名逐字一致（不改写名字）。
6. 回归：钉住的 DeepSeek / OpenCode Go / Codex 浮层不变。
7. 手动：断网刷新 → 保留上次数字 + 红色错误行，不退回小菜单。
