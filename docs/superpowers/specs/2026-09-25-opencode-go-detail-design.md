# OpenCode Go 用量详情浮层 设计

日期：2026-09-25
状态：已批准，待实现

## 1. 背景与目标

钉住项的详情浮层（`UsageDetail` + `DetailPopoverView`）目前只有 DeepSeek 填过。本次让 **OpenCode Go** 也产出详情卡片：
点钉住的 Go 项弹浮层，展示订阅三额度、30 天用量汇总、每日花费趋势、token 构成与按模型拆分。

数据全部来自 console 的后端 JSON 接口，经**网页会话**（cookie）抓取，卡片由 app 自己重绘，不嵌入任何控制台页面。

**目标**

- 点钉住的 Go 项 → 浮层展示：三额度（5 小时 / 周 / 月）、今天 / 7 天 / 30 天汇总、30 天每日花费趋势、token 构成、按模型表。
- 与 DeepSeek 同一路数：数据来自已抓回的响应，不新增第三方依赖；视图层零改动版式。
- 顺带修好网页会话取数路径上两个既有缺陷（见 §3）——不修则卡片拿不到任何数据、金额还差 100 倍。

**非目标**

- 不做交互：趋势图不可悬停，没有筛选、日期范围选择、下钻。时间范围固定为**最近 30 天（滚动，UTC）**。
- 不做跨账号汇总，一个浮层只讲一个账号。
- 不改 API key 模式的行为与卡片：`producesUsageDetail` 只对**登录模式**的 Go 账号为真（见 §6）。API key 模式（`/zen/go/v1/usage`）只有百分比与重置时间，撑不起本卡片，维持现状。
- 不新增设置项，不改凭据格式（Keychain 里仍是 `opencode-go-web-session:` 前缀的 cookie 凭据，无需迁移）。

## 2. 术语

- **console**：OpenCode 的网页控制台，登录域 `console.opencode.ai`，前后端同一套 API 也挂在 `opencode.ai/console/*`。
- **网页会话**：登录模式下由 WebView 导入的 cookie 凭据；原生请求把它作为 `Cookie` 头。
- **workspace**：console 的工作区，id 形如 `wrk_…` / `org_…`；Go 订阅挂在某个 workspace 上，用量接口按 workspace 作用域查询（请求头 `x-org-id`）。
- **microcents**：console 全部金额字段的单位，**1 美元 = 1e8 microcents**。证据：console 前端自身的定价常量 `price.recurringMicroCents = 1000000000n`（= $10/月）与 `usageLimits.fiveHours = 1200000000n / utcCalendarWeek = 3000000000n / paidPeriod = 6000000000n`（= $12 / $30 / $60），且其换算函数为 `/1e8`。
- **bundle**：一次刷新并发取回的多份响应拼成的 JSON 信封；原生路径与 WebView 兜底路径产出**同一形状**。

## 3. 必须先修的两个既有缺陷

### 3.1 金额换算差 100 倍

`OpenCodeGoUsageParser.dollarsText` 现在按 `/1e6` 换算（把 microcents 当 microdollars）。按 §2 的证据，console 的单位是 1e-8 美元，
现路径会把 $12 的额度显示成 $1200。修法：

- `dollarsText`：除数改为 `1_000_000_000` 量级即 `1e8`（实现为 `1e8`）。
- `apiLimitMicroCents`：常量从 `12/30/60 × 1_000_000` 改为 `× 100_000_000`。API key 路径的**显示值因此逐字不变**（百分比 × 新常量 ÷ 新除数 == 旧值），只有内部标度变。
- 既有测试 `formatsDollarsFromMicroCents`、`parsesRealAPIUsageShape` 的期望值按新标度更新（后者断言的是显示字符串，应当**保持不变**，正好验证这一点）。

### 3.2 网页会话取数路径解析不了现在的响应，也缺 workspace 作用域

现在 console 的 `GET /api/go/status` 返回新形状（旧形状 `{subscriptionStatus, currentPeriod, meters: [{kind, settledMicroCents, …}]}` 已不再对应线上）：

```json
{
  "access": {
    "startsAt": "…", "endsAt": "…",
    "meters": {
      "fiveHour": { "limitMicroCents": …, "usedMicroCents": …, "resetsAt": "…" },
      "week":     { "limitMicroCents": …, "usedMicroCents": …, "resetsAt": "…" },
      "month":    { "limitMicroCents": …, "usedMicroCents": … }
    }
  },
  "cancelAtPeriodEnd": false,
  "renewalPending": false
}
```

（来源：console 的 Go 页面代码直接读 `data.access.meters.fiveHour/week/month`、`data.access.endsAt`、`data.cancelAtPeriodEnd`、`data.renewalPending`。）

同时该接口**要求 `x-org-id` 头**（缺了 400），而 workspace id 需要先查 `GET /api/me/orgs`（无作用域，返回 `[{id, name}]`）。
现有代码两者都没有，因此登录后也会解析出空。

修法（本节全部落在 `OpenCodeGoUsageParser.parseBundle` 与 provider 的取数流程里）：

1. 新形状解析：`access.meters.fiveHour/week/month` → `TokenUsage(window: .fiveHours/.week/.month, used: usedMicroCents, limit: limitMicroCents, resetDate: resetsAt ?? access.endsAt, displayValue: "$used / $limit")`。月窗口没有 `resetsAt`，用 `access.endsAt`。`access` 缺失或为 null → 视为未订阅（沿用既有文案）。
2. 旧形状保留为兜底（解析顺序：新形状 → 旧形状），行为不变。
3. 取数时先 `GET /api/me/orgs` 拿 workspace 列表；逐个（上限 5 个）带 `x-org-id` 请求 `/api/go/status`，取**第一个 `access` 非空**的 workspace 作为本次卡片的 workspace；若都没有订阅，用第一个 workspace 的响应走"未订阅"分支。后续用量请求用同一个 workspace id。

## 4. 数据来源与请求序列

登录模式下每次刷新按顺序取（原生路径并发执行无关顺序的请求；脚本路径 XHR 为同步，按序执行）：

| # | 请求 | 作用域 | 用途 |
| --- | --- | --- | --- |
| 1 | `GET /api/me/orgs` | 无 | workspace 列表 |
| 2 | `GET /api/go/status`（逐个 workspace，直到有 `access`） | `x-org-id` | 三额度 + 订阅信息（现有） |
| 3 | `GET /api/usage/summary?range=30d` | `x-org-id` | 30 天合计：请求数、输入/输出/缓存读/缓存写 tokens、总花费 |
| 4 | `GET /api/usage/cost-by-day?range=30d&bucket=day` | `x-org-id` | 每日 `{date, totalCostMicroCents, totalTokens, totalRequests}`，`date` 为 `"YYYY-MM-DD"` |
| 5 | `GET /api/usage/models?range=30d&pageSize=100&costOrder=desc` | `x-org-id` | `{items: [{model, provider, totalRequests, total…Tokens, totalCostMicroCents}], pageInfo}` |

- 3–5 任一失败（非 2xx / 解析不了）→ 该区块的数据在 bundle 里缺席，卡片少画那一段，**不影响额度**。
- 金额字段线上可能是数字或字符串（console 用 BigInt schema），解析一律两种都收。
- 时间口径：`range=30d` 指 `[今天-29, 今天]`（UTC 自然日），与 console 用量页一致。

## 5. bundle 与两条路径

原生路径（`fetchUsageBundle(session:)`）与 WebView 脚本（`OpenCodeGoWebSessionDescriptor.usageFetchScript`）产出同一信封：

```json
{
  "ok": true, "status": 200, "text": "", "hasSession": true,
  "goStatus": { … },          // 选中的 /api/go/status 响应原文
  "session": { … },           // 仅脚本路径带；原生省略
  "orgs": [ { "id": "wrk_…", "name": "…" } ],
  "workspaceId": "wrk_…",     // 选中的 workspace
  "usageSummary": { … } | null,
  "usageByDay": [ … ] | null,
  "usageModels": { … } | null
}
```

- 信封拼装抽成纯函数（如 `OpenCodeGoUsageEnvelope.make(goStatus:orgs:workspaceId:summary:byDay:models:)`），便于测试。
- `parseBundle` 对新旧两种 `goStatus` 都能解析（§3.2），信封缺 `goStatus` 时维持现有行为。
- 脚本路径：`request()` 辅助函数扩展为可带额外请求头（`x-org-id`）；先取 `/api/me/orgs`，再按 §3.2 选 workspace、取状态与三份用量。`hasSession`/`session` 字段维持现状。

## 6. 触发

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

与 DeepSeek 同规则、同注意事项（判断只看 config，看不到 Keychain）：一个配成 API 模式但 Keychain 里留着网页会话的 Go 账号，实际会取回控制台数据，而这里回报 false——无害，注释里别把话说死。

**注意**：登录模式下没有导入过会话的账号，点钉住项会弹浮层并显示错误行（`Login with OpenCode Go`），而不是原来的 Unpin / Settings / Quit 小菜单；浮层底部本来就带这三个按钮。

## 7. 详情填充规则

新增 `Sources/TokenHealth/OpenCodeGoUsageDetail.swift`：

```swift
enum OpenCodeGoUsageDetail {
    static func make(bundle: Data, usages: [TokenUsage]) -> UsageDetail?
}
```

不抛错：解析不出来就返回 nil（浮层退回错误行）；区块级数据缺失只让该区块缺席。信封里额度与用量都拿不到时返回 nil。

### 7.1 headline（三额度）

按 `.fiveHours / .week / .month` 顺序取传入的 `[TokenUsage]`（与面板同源，保证两处数字一致），
`label` 用 `5 hours` / `Week` / `Month`，`value` 直接用 `displayValue`（`$0.32 / $1.20`）。缺失的窗口不占行。

### 7.2 groups（今天 / 7 天 / 30 天）

来自 `usageByDay`：按 `date` 前 10 个字符解析（UTC `yyyy-MM-dd`），落在 `[今天-29, 今天]` 之外的行**整条忽略**；同一天出现多次按天求和。
三个区间的合计各一行，三列依次 `Requests` / `Tokens` / `Cost`：

- 今天 = 日期等于今天那一行（没有就是全 0）。
- 7 天 = `[今天-6, 今天]` 的行合计；30 天 = 全部行合计。
- 次数与 tokens 用 `UsageAmountFormatter.compactAmount`；花费按 microcents ÷ 1e8 用 `dollarsText`（`$19.86`）。

`usageByDay` 缺席（调用失败）时整段不画；是空数组（成功但 30 天没用量）时照画全 0 行。

### 7.3 series（每日花费）

- 覆盖 `[今天-29, 今天]`（UTC）逐日一点，**没有数据的日期补 0**；同一天多条求和。
- 点的值 = 当日花费（美元，Double）。
- `title` = `Cost · last 30 days`；`axisStart` / `axisEnd` = 起止日 `M/d`；`emptyText` = `No usage in the last 30 days`。
- `usageByDay` 缺席时整段不画；全 0 照常产出，由视图显示 `emptyText`（与 DeepSeek 同一约定）。

### 7.4 breakdown（token 构成）

来自 `usageSummary`：`Input` / `Output` / `Cache read` / `Cache write`（缓存写 = `totalCacheWrite5mTokens + totalCacheWrite1hTokens`），用 `compactAmount`。
`usageSummary` 缺席时整段不画。

### 7.5 table（按模型）

来自 `usageModels.items`：

- **按模型名合并**（不同 provider 的同名模型求和）——`DetailTableRow.id` 取模型名，集合内必须唯一。
- 模型名为空或缺失 → 合并进 `Unknown model` 一行。
- **tokens 与花费都为 0 的行不成行**。
- 排序：花费降序，相同则模型名升序。**只列前 6 行**，其余进 `footnote`（`+N more models`），被截断的行不参与任何合计（合计在 §7.2/§7.4 里按全量算）。
- `title` = `By model · last 30 days`，列 `Model` / `Requests` / `Tokens` / `Cost`。
- `usageModels` 缺席或没有可成行的模型时整段不画。

## 8. 文案表

| 位置 | 文案 |
| --- | --- |
| headline 三窗口 | `5 hours` / `Week` / `Month` |
| 分组列与行 | `Requests` / `Tokens` / `Cost`；`Today` / `7 days` / `30 days` |
| 趋势图 | `Cost · last 30 days`；无数据 `No usage in the last 30 days` |
| token 构成 | `Input` / `Output` / `Cache read` / `Cache write` |
| 表格 | `By model · last 30 days`；表头 `Model` `Requests` `Tokens` `Cost`；`+N more models`；未知模型 `Unknown model` |

## 9. 顺带的改动

`DetailSeries` 增加 `emptyText: String`（浮层现在把 `No usage this month` 写死在视图里）。`DeepSeekUsageDetail` 传入同一句 `No usage this month`，
`DetailPopoverView` 改读 `series.emptyText`——DeepSeek 的显示逐字不变，由既有 `DeepSeekUsageDetailTests` / 渲染冒烟兜底。

## 10. 错误与边界

| 情况 | 表现 |
| --- | --- |
| `/api/me/orgs` 失败或返回空 | 取数整体失败 → 快照 unavailable（文案沿用现有错误路径） |
| 所有 workspace 都无 Go 订阅 | 沿用"未订阅"文案；不产卡片数据 |
| 某个用量接口失败 | 对应区块缺席，其余照常；卡片仍弹 |
| `usageByDay` 为空数组（30 天没用量） | 汇总全 0、趋势图走 `emptyText` |
| `date` 解析失败的行 | 整条忽略 |
| 日期落在 30 天之外 | 不进任何合计 |
| 同名模型跨 provider | 合并成一行 |
| 模型名缺失 | 合并进 `Unknown model` |
| 用量接口金额是字符串 | 正常解析 |
| 快照失败但有旧 detail | 沿用既有"保留上次 detail"机制，浮层不清空 |
| API 模式 / 未登录的 Go 账号 | 行为不变：小菜单或错误行（§6） |

## 11. 测试策略

跑测试一律 `bash scripts/test.sh`。

| 测试 | 覆盖 |
| --- | --- |
| `OpenCodeGoUsageDetailTests`（新） | headline 三行与顺序；今天/7 天/30 天汇总（含补 0、越界日期、同日求和）；趋势 30 点与轴标签；构成（5m+1h 合并）；模型表（合并、丢空行、排序、6 行截断 + footnote、Unknown model）；用量键缺席 → 对应区块不在且不抛错；额度与用量全空 → nil |
| `OpenCodeGoUsageProviderTests`（扩充） | 新形状 `access.meters` 解析（含月窗口用 `endsAt` 兜底重置时间）；旧形状兜底不变；`dollarsText` 新标度；API key 路径显示值逐字不变；信封拼装纯函数 |
| `ProviderDetailCapabilityTests`（扩充） | `.openCodeGo` + `.browserLogin` 为真；`.api` 为假 |
| `OpenCodeGoWebSessionDescriptorTests`（扩充） | 脚本包含 5 个端点、`x-org-id` 与 workspace 选择逻辑 |
| 既有测试 | 全绿（`DetailSeries` 加字段的影响面） |

## 12. 已知取舍

- **金额标度以 console 自身的常量为准**（§2），既有 `/1e6` 是笔误。验收时用"已用 ÷ 上限 == console 百分比"复核。
- **固定 30 天滚动**：不跟随 console 的 24h/7d/30d 选择器（浮层不可交互）。要别的范围请回控制台。
- **选第一个有订阅的 workspace**：多 workspace 账号不提供选择器；上限 5 个，避免异常账号拖慢刷新。
- **每次刷新多 3–5 个请求**：跟随现有刷新节奏（含浮层打开时的 5 分钟新鲜度刷新），不做懒加载。

## 13. 验收

1. `bash scripts/test.sh` 全绿。
2. `bash scripts/build-app.sh` 通过并装到 `/Applications` 核对版本号。
3. 手动：把一个 Go 账号切到 Login 模式并登录导入 → 钉住它 → 点菜单栏项弹浮层：三额度、今天/7 天/30 天、趋势图、token 构成、模型表齐全。
4. 手动：三额度的 `已用/上限` 与 console Go 页面的百分比一致；30 天合计与控制台用量页对得上（同口径：滚动 30 天，UTC）。
5. 手动：API 模式的 Go 账号点钉住项仍是 Unpin / Settings / Quit 小菜单。
6. 手动：断网刷新 → 保留上次数字 + 红色错误行，不退回小菜单。
