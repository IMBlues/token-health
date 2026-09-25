# Codex 用量详情浮层 设计

日期：2026-09-26
状态：已批准，待实现
版本：随 1.0.3 一起发布（与 OpenCode Go 详情同一批，不单独推版本号）

## 1. 背景与目标

钉住项的详情浮层（`UsageDetail` + `DetailPopoverView`）已有 DeepSeek 与 OpenCode Go 两个填充方。本次让 **Codex** 也产出详情卡片：
点钉住的 Codex 项弹浮层，展示额度百分比、今天 / 7 天 / 30 天的 token 汇总、30 天每日 token 趋势与账号级累计统计。

数据全部来自**现有的 Codex 本地登录路径**：`CodexUsageProvider` 已经在跑 `codex app-server --stdio`，本次只在同一个会话里多发一条 `account/usage/read`。
**不新增登录流程、不碰凭据、不读 `~/.codex/auth.json`、不引入网页会话。**

**目标**

- 点钉住的 Codex 项 → 浮层展示：额度（与菜单栏同源）、今天 / 7 天 / 30 天 tokens、30 天每日 tokens 趋势、Lifetime / Peak day / Streak / Longest turn。
- 与 DeepSeek / OpenCode Go 同一路数：视图层零改动版式，数据来自已取回的响应，不新增第三方依赖。
- 额度是必需项、用量是可选区块：用量那条 RPC **报错或解不出**不得影响额度与菜单栏数字。注意「完全无应答」不属于这条 —— 那是会话超时，整次刷新失败（§4、§11）。

**非目标**

- 不做表格（不画「最忙的几天」），不做额度重置行（`rateLimitResetCredits` 与 `credits` 本次不解码、不展示）。
- 不做交互：趋势图不可悬停，没有筛选、日期范围选择、下钻。时间范围固定为**最近 30 天（滚动，UTC）**。
- 不改 Cursor（同为 `usesLocalLogin`，但本次不做），不改其它 provider，不改 API key / 通用 HTTP 路径。
- 不改 `DetailPopoverView` 与 `UsageDetail` 模型：四个区块语义都已够用。
- 不新增设置项，不改凭据格式，不改刷新节奏与缓存时长。

## 2. 术语

- **app-server**：`codex app-server --stdio` 起的 JSON-RPC over stdio 会话，本 app 已用它读额度。
- **RPC 会话**：一次进程生命周期 —— initialize → initialized → 若干请求 → 收到响应后杀掉进程。**一次往返的实测成本约 1.2–5.5 秒，几乎全是进程启动**，所以「一次会话发多条请求」远优于「起两次进程」。
- **额度**：`account/rateLimits/read` 的响应，即今天已有的那份数据。
- **账号用量**：`account/usage/read` 的响应，本次新增。
- **bucket**：`dailyUsageBuckets` 的一条，`{startDate: "YYYY-MM-DD", tokens}`。

## 3. 数据来源（2026-09-26 在本机实测）

本机 codex-cli 0.144.4，用与 `CodexAppServerClient.arguments` **逐字相同**的参数起会话。

`account/rateLimits/read`（已在用，本次不改解码）：

```json
{
  "rateLimits": {
    "limitId": "codex", "limitName": null, "planType": "plus",
    "primary":   { "usedPercent": 12, "windowDurationMins": 300,   "resetsAt": 1790337941 },
    "secondary": { "usedPercent": 58, "windowDurationMins": 10080, "resetsAt": 1790754811 }
  },
  "rateLimitsByLimitId": { "codex": { … 同上 … } },
  "rateLimitResetCredits": { "availableCount": 0, "credits": [] }
}
```

`account/usage/read`（本次新增，**请求无需 params**）：

```json
{
  "summary": {
    "lifetimeTokens": 172532345, "peakDailyTokens": 117865819,
    "longestRunningTurnSec": 2550, "currentStreakDays": 3, "longestStreakDays": 3
  },
  "dailyUsageBuckets": [
    { "startDate": "2026-06-17", "tokens": 283242 },
    { "startDate": "2026-09-22", "tokens": 18510426 },
    { "startDate": "2026-09-23", "tokens": 117865819 },
    { "startDate": "2026-09-24", "tokens": 35872858 }
  ]
}
```

两个必须写进实现的性质：

1. **buckets 稀疏**：只有有量的那几天，不是连续 30 天。上面的四条之和恰好等于 `lifetimeTokens`，可见它是「按日的全量历史」（本机最早一条在 100 天前），不是只给 30 天。**图表与区间汇总必须自己补齐缺失的日期。**
2. **处处可缺**：协议里只有 bucket 的 `startDate` / `tokens` 标了 required，`summary` 本身 required 但它的各字段可 null；但我们一律按可缺解码（§4.1）。缺失的降级是「不画那一段」，不是报错。
3. 响应里还有一个可 null 的 `threadUsage` 字段：本次不解码，无影响。

> 上面这份示例是 2026-09-26 某刻的真实抓包，**只用来固定形状**，不是验收时的预期值（bucket 会随用量增长）。

协议来源：`codex app-server generate-json-schema --experimental --out <dir>` 生成的 `GetAccountTokenUsageResponse` / `AccountTokenUsageSummary` / `AccountTokenUsageDailyBucket`。

## 4. 取数：一次会话、两条请求

`CodexQuotaRPC` 的报文从三条变成四条（其余不变）：

```
{"method":"initialize","id":0,"params":{…}}
{"method":"initialized"}
{"method":"account/rateLimits/read","id":1}
{"method":"account/usage/read","id":2}
```

- `CodexQuotaRPC` 增加常量 `usageResponseID = 2`，`outboundMethods` 变为四元素（既有测试逐字断言它，一并更新）。
- `CodexAppServerSession.run` 从「等一个 `responseID`」改成「等一组 `responseIDs: Set<Int>`」，返回 `[Int: Data]`；**收齐全部 id 才 complete**，超时 / 进程退出 / 超长响应三条终点不变。会话的其余机制（锁、超时 work item、kill 兜底、行缓冲与体积上限）逐字不动。
- `CodexAppServerError` 不新增 case。

`CodexAppServerClient` 增加：

```swift
struct CodexQuotaBundle: Sendable {
    var rateLimits: CodexRateLimitsResponse
    /// nil = 用量那条 RPC 报错或解不出来。详情少画用量区块，不影响快照。
    var accountUsage: CodexAccountUsageResponse?
}

func fetchQuotaBundle() async throws -> CodexQuotaBundle
```

规则（**「无应答」和「有应答但报错」是两回事，别混**）：

- **id=1（额度）是必需项**：响应缺席、是 JSON-RPC error、或解不出 `CodexRateLimitsResponse` → 抛错，整次刷新按今天的方式失败。
- **id=2（用量）有应答但不是成功结果** —— 是 error（不支持该方法的 Codex 会回 `-32601`），或 result 解不出 `CodexAccountUsageResponse` → `accountUsage = nil`，**不抛错**，额度照常。
- **id=2 完全无应答** → 会话等不到那个 id，走超时（30 秒）→ 整次刷新失败，与今天会话超时的表现一致。这不是降级路径，是失败路径（§11 说明为何接受）。
- 两条响应在同一个进程里发出、同一个超时窗口内收齐，不串行。

`CodexAppServerClient.fetchRateLimits()` **删除**：生产路径只有批量这一条，留一个单独取额度的入口就是死代码。
两个依赖它的测试助手（`CodexTestSupport.fetchFromFakeAppServer()`、`fetchLiveCodexQuota()`）改用 `fetchQuotaBundle()` 并读 `.rateLimits`（§10）。

**快照构造抽成纯函数**（对齐 `OpenCodeGoUsageProvider.consoleSnapshot` 的既有做法）：

```swift
/// 内部而非 private：测试拿合成 bundle 与固定 today 直接测这一层，不必起进程、不碰 UTC 午夜。
func snapshot(config: ServiceConfig, bundle: CodexQuotaBundle, fetchedAt: Date, today: Date) -> ProviderUsageSnapshot
```

`fetchUsage` 只负责缓存与进程这层管道，最后调它（`today` 传 `Date()`）。额度窗口为空时它返回 `.unavailable`，不产 detail。

### 4.1 解码形状

```swift
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

struct CodexAccountUsageDay: Decodable, Sendable {
    let startDate: String?
    let tokens: Int64?
}
```

- **每个字段都宽容**：`decodeIfPresent`，数字走文件里已有的 `decodeFlexibleInt64IfPresent`（容忍数字写成字符串）。协议里 `summary` 是 required、`dailyUsageBuckets` 可 null，但这里一律当可缺 —— 缺了只是少画一段，不必让整份响应作废。
- 信封本身解不出（比如 `dailyUsageBuckets` 不是数组）→ `accountUsage = nil`。**`summary` 类型不对不属于这一类**：它解成四个字段全 nil，只少画 breakdown，buckets 照常。
- bucket 的 `startDate` 为 nil / 解析不出，或 `tokens` 为 nil → 该条**整条忽略**（不当 0：0 是「那天没用」，缺字段是「不知道」）。
- `longestStreakDays` 不解码：没有任何区块用它（§7.4）。

> 备选方案「起两次 app-server」被否掉：实测每次往返 1.2–5.5 秒且几乎全是进程启动，等于每次刷新白烧两秒；而它换来的只是「可选请求永不回应」这一种协议违规场景的容错（见 §11）。

## 5. 缓存

`CodexRateLimitsCache` 改名为 `CodexQuotaCache`（private，文件内），缓存值由 `CodexRateLimitsResponse` 换成 `CodexQuotaBundle`。
键（可执行文件路径 + `CODEX_HOME`）、`maxAge: 60`、`minimumRequestInterval: 60`、失败缓存与节流语义**全部不变** —— 一次刷新仍然只起一个 Codex 进程。

## 6. 触发

```swift
static func producesUsageDetail(for config: ServiceConfig) -> Bool {
    switch config.providerKind {
    case .deepSeek, .openCodeGo:
        config.authMode == .browserLogin
    case .codex:
        true
    default:
        false
    }
}
```

`.codex` 是**唯一不看 authMode 的分支**：Codex 走 `usesLocalLogin`，`AppState.saveConfigs()` 会把它的 `authMode` 强制写成 `.api`，
照 DeepSeek / OpenCode Go 那条 `authMode == .browserLogin` 写就永远不会为真。注释要把这点写清楚，免得后人「统一」成同一条规则。

**行为变化**（与 OpenCode Go 上线时同款，需在验收里确认）：钉住的 Codex 项点开变成浮层，不再是 Unpin / Settings / Quit 小菜单。
没装 Codex、没登录、或额度取数失败的账号看到的是浮层里的错误行，底部三个按钮仍在。

## 7. 详情填充规则

新增 `Sources/TokenHealth/CodexUsageDetail.swift`：

```swift
enum CodexUsageDetail {
    static func make(
        usage: CodexAccountUsageResponse?,
        usages: [TokenUsage],
        today: Date
    ) -> UsageDetail?
}
```

不抛错；四个区块都填不出来就返回 nil（浮层退回错误行）。**时间锚点显式注入**（与 `DeepSeekUsageDetail.make` / `OpenCodeGoUsageDetail.make` 同一约定）：
「今天」与所有日期窗口都按传入 `today` 的 UTC 自然日推导，构建器内部不取 `Date()`；provider 传 `Date()`，测试传固定时刻，避免 UTC 午夜 flake。

### 7.1 headline（额度，与菜单栏同源）

直接取 `UsageMetricSelection.pinnedMetrics(from: usages, kind: .codex)` —— 就是钉住菜单栏项画进度条用的那一组（Codex 只算账号级，自动排除 `gpt-5 · 5h` 这类模型桶）。逐条：

- `label` = `MenuBarMetrics.shortLabel(for:)` → `5h` / `Week`
- `value` = `UsageAmountFormatter.exactAmountText(_)` → `12%`

**不要自己写窗口列表或百分比格式**：这两处复用是为了让浮层与菜单栏 tooltip 永远同源。`usages` 为空时 headline 为空。
label 撞车（两个非标准时长的桶都折出 `1h`）时**只留第一条**：`DetailStat.id == label`，同一集合内必须唯一（`UsageDetail.swift` 顶部的不变量），否则 `ForEach` 会出错。

### 7.2 groups（今天 / 7 天 / 30 天）

来自 `dailyUsageBuckets`，UTC 自然日，窗口 `[今天-29, 今天]`：

- 每条的 `startDate` 取**前 10 个字符**解析（容忍 `"2026-09-24T00:00:00Z"` 一类写法）；解析失败的行与落在窗口外的行**整条忽略**；同一天出现多条按天求和。
- 三行 × 一列 `Tokens`（`UsageAmountFormatter.compactAmount`），行标题依次 `Today` / `7 days` / `30 days`。
  - 今天 = 日期等于今天那一行；7 天 = `[今天-6, 今天]` 合计；30 天 = 窗口内全部合计。没有 bucket 的日期就是 0，行照画。
- 求和用**饱和加法**（`addingReportingOverflow`），与 `OpenCodeGoUsageDetail.Totals` 同一条不变量：畸形或敌意的远端数字必须降级，不许 trap。
- `dailyUsageBuckets == nil`（老后端）→ **整段不画**；是空数组（确实没用量）→ 照画三行 0。

### 7.3 series（每日 tokens）

- 覆盖 `[今天-29, 今天]`（UTC）**逐日一点**，没有 bucket 的日期补 0；同一天多条求和。
- 点的值 = 当日 tokens（`Double`）。
- `title` = `Tokens · last 30 days`；`axisStart` / `axisEnd` = 起止日 `M/d`；`emptyText` = `No usage in the last 30 days`。
- 与 §7.2 同一条规则：`dailyUsageBuckets == nil` 时整段不画；空数组时照常产出，由视图显示 `emptyText`（`DetailSeriesChart.maximum == 0` 那条既有分支）。

### 7.4 breakdown（账号累计）

四项，**各自的源为 nil 就不占位**；四项都缺 → 整段不画：

| label | 来源 | 呈现 |
| --- | --- | --- |
| `Lifetime` | `summary.lifetimeTokens` | `compactAmount` → `172.53M` |
| `Peak day` | `summary.peakDailyTokens` | `compactAmount` → `117.87M` |
| `Streak` | `summary.currentStreakDays` | `"\(n)d"` → `3d`（0 也照画） |
| `Longest turn` | `summary.longestRunningTurnSec` | 时长文案，见下 |

时长文案：`s < 60` → `42s`；`s < 3600` → `42m`（向下取整分钟）；否则 `1h` / `1h 5m`（整点去掉分钟）。
**四项一律「值为 nil 或负数就不占位」**：`-3d` 一类的数字不是「用了一点」，是坏数据（与 §7.2 的饱和加法同一条口径）。

`longestStreakDays` 本次不解码：没有任何区块用它，需要时再加一个字段即可。

### 7.5 不做的区块

`table` 不填（`UsageDetail.table` 留 nil，浮层不画表格）。`credits` / `rateLimitResetCredits` 不解码、不展示。

## 8. 文案表

| 位置 | 文案 |
| --- | --- |
| headline | label 取自 `MenuBarMetrics.shortLabel`（`5h` / `Week`）；value 取自 `exactAmountText`（`12%`） |
| 分组 | 列 `Tokens`；行 `Today` / `7 days` / `30 days` |
| 趋势图 | `Tokens · last 30 days`；无数据 `No usage in the last 30 days` |
| 累计行 | `Lifetime` / `Peak day` / `Streak` / `Longest turn` |

## 9. 错误与边界

| 情况 | 表现 |
| --- | --- |
| 没装 Codex / 没登录 | 与今天一致：`.needsConfiguration`（`executableNotFound` / `requestRejected` 的既有文案）+ 浮层错误行 |
| 会话超时 / 进程退出 / 响应超长 | 整次刷新失败（与今天一致：额度也拿不到） |
| id=1 缺席 / 是 error / 解不出 | 整次刷新失败（与今天一致） |
| id=2 是 error（如老版本 Codex 回 -32601）/ 解不出 | `accountUsage = nil`：详情只剩 headline，额度与菜单栏数字照常 ready |
| id=2 完全无应答 | 会话超时 → 整次刷新失败（与今天超时同路，见 §11） |
| `summary` 缺失或某字段为 null | 对应 breakdown 项不占位；`dailyUsageBuckets` 不受影响 |
| `dailyUsageBuckets` 缺失 | groups 与 series 不画，headline 与 breakdown 照常 |
| `dailyUsageBuckets` 为空数组 | 三行全 0、趋势图走 `emptyText` |
| bucket 的 `startDate` 解析失败 / 落在 30 天外 / `tokens` 缺失 | 该条忽略 |
| 额度窗口为空（`usages.isEmpty`） | 与今天一致 unavailable，不产详情 |
| 刷新失败但有旧 detail | 沿用 `AppState.storeSnapshot` 的「非 ready 且无新 detail 时保留上次 detail」 |

## 10. 测试策略

跑测试一律 `bash scripts/test.sh`（本机只有 CommandLineTools，直接 `swift test` 会因 `no such module 'Testing'` 假失败）。

| 测试 | 覆盖 |
| --- | --- |
| `CodexUsageDetailTests`（新） | headline 取自 `pinnedMetrics` 的顺序与文案（含模型桶被排除、label 撞车只留第一条）；三行汇总（补 0、越界忽略、同日求和、空数组、nil 不画）；趋势 30 点与轴文案；breakdown 四项与各自缺失时的降级、时长格式四档（`42s` / `42m` / `1h` / `1h 5m`、负数不占位）；`summary` 缺失但 buckets 在 → 只少 breakdown；全空返回 nil；`today` 注入固定时刻 |
| `CodexUsageProviderTests`（扩） | `snapshot(config:bundle:fetchedAt:today:)` 的纯函数层：带 usage 的 bundle → `ready` 且 detail 齐全；usage 为 nil → detail 只有 headline；无额度窗口 → `unavailable` 且无 detail。会话层仍走假 app-server（`timeout: 3`）：`fetchQuotaBundle()` 两条都回 → bundle 两半都在；id=2 回 error（`-32601`）/ 回坏 JSON → `accountUsage == nil` 且不抛；id=1 回坏 → 抛错；**id=2 完全无应答**（脚本回完 id=1 后 `sleep` 住不退出）→ 抛 `CodexAppServerError.timeout`；缓存命中不重起进程 |
| `CodexTestSupport`（改） | 假 app-server 脚本读满四条请求、补 id=2 的响应（保留既有「先发一条无关通知」的行为）；`fetchFromFakeAppServer()` 与 `fetchLiveCodexQuota()` 的返回类型都改成 `CodexQuotaBundle`、内部改调 `fetchQuotaBundle()`，两处调用点（`testAppServerClientIgnoresNotificationsAndReadsExpectedResponse`、`testLiveCodexQuotaWhenExplicitlyEnabled`）相应读 `.rateLimits`；`rpcSummary` 断言四条报文 |
| `CodexUsageProviderTests.testQuotaRPCUsesOnlyTheReadOnlyAllowlist`（改，**唯一一处安全姿态断言，别顺手删**） | 方法名断言补上 `account/usage/read`；`keySets.count` 3 → 4（`keySets[3] == ["id", "method"]`）；`forbiddenMethod` 列表**只删 `"account/usage/read"` 一项，其余 11 项（含 `capabilities`、`experimentalApi`）逐字保留** —— 删掉的那项与 `account/rateLimits/read` 同属只读账号方法，是本次有意放行的唯一一个 |
| `ProviderDetailCapabilityTests`（扩） | `.codex` 在两种 authMode 下都为真；`everyOtherProviderIsUnsupported` 的例外集合加上 `.codex` |
| 既有测试 | 全绿（`fetchRateLimits()` 删除后其两个调用点按上表迁移） |

## 11. 已知取舍

- **一次会话两条请求**：省掉一次进程启动（实测每次 1.2–5.5 秒）。代价是新引入一种「某个 id 永不回应 → 整次刷新超时失败」的可能。JSON-RPC 要求对每个带 id 的请求都应答（未知方法回 `-32601`），实测 0.144.4 两条都应答，所以接受；若线上真的遇到「静默丢请求」的 Codex 版本，再加「必需 id 到齐后宽限 N 秒」的兜底即可。
- **`rateLimitResetCredits` / `credits` 不解码**：本次面板不展示它们，先不引入字段。
- **`longestStreakDays` 不解码**：没有区块用它。
- **`Longest turn` 是个趣味指标**（最长单次 turn 时长），不是用量决策依据；放在 breakdown 第四项。
- **bucket 是稀疏全量历史**：30 天以外的 bucket 会被忽略。本机实测最早一条在 100 天前，说明后端不是因为范围而截断；但若某个后端只回最近 N 条，最老的几天会静默缺失 —— 表现为「30 天合计偏小」，无告警。接受。
- **每次刷新仍只起一个 Codex 进程**，多出来的只是一条 RPC 的响应体积（本机约 200 字节）。

## 12. 验收

1. `bash scripts/test.sh` 全绿。
2. `bash scripts/build-app.sh` 通过，装到 `/Applications/Token Health.app`，用 `plutil -extract CFBundleShortVersionString raw` 核对仍是 **1.0.3**（本次不推版本号）。
3. 手动：点钉住的 Codex 项 → 浮层出现 `5h` / `Week` 百分比、Today / 7 days / 30 days tokens、30 天柱状图、Lifetime / Peak day / Streak / Longest turn。
4. 手动：headline 的百分比与菜单栏项 tooltip 逐字一致。
5. 手动：30 天合计、Lifetime / Peak day / Streak 与 Codex 自己的用量界面核对 —— TUI 里 `/usage`（Token activity）读的就是同一条 `account/usage/read`。**不要拿 `/status` 对**：那个讲的是当前会话的 token，不是账号级历史。日期口径同为 UTC 自然日。
6. 回归：钉住的 DeepSeek / OpenCode Go 浮层不变；钉住的 Cursor 仍是 Unpin / Settings / Quit 小菜单。
7. 手动：断网（或让 Codex 退出登录）刷新 → 保留上次数字 + 红色错误行，不退回小菜单。
