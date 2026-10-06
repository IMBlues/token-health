# DeepSeek 详情浮层·按 API key 维度 设计

日期：2026-10-06
状态：已批准（设计阶段），待实现
版本：随 1.0.7 发布

## 1. 背景与目标

钉住项的详情浮层（`UsageDetail` + `DetailPopoverView`）已有 DeepSeek、OpenCode Go、Codex、Cursor 四个填充方。
DeepSeek 那份的末段是 `By model · this month` 的按模型拆分（`DeepSeekUsageDetail.table(_:)`），
而它的数据源（`usage/amount`、`usage/cost`）每一行只有 `date` 与 `model` 两个字段 —— **拿不到 key**。

本次给 DeepSeek 浮层再加一段 **`By API key · this month`** 的按 key 拆分，与 `By model` 表同构、并列排在它下面。

**目标**

- 点钉住的 DeepSeek 项 → 浮层在 `By model · this month` 之后多出一张 `By API key · this month` 表：
  `API key` / `Requests` / `Tokens` / `Cost` 四列，tokens 降序，最多 6 行，超出加脚注。
- 与既有四个详情同一路数：数据在刷新时一并取回，详情构建器仍是**纯函数**（只吃 bundle，不碰网络、不看时钟）。
- 新取数是**可选**的：报错、解不出、端点不存在，都只让这张表不出现，**不影响**余额、`Today` / `This month` 汇总、
  趋势、缓存构成、`By model` 表，也不影响菜单栏数字与卡片。

**非目标**

- 不改菜单栏、不改卡片、不改刷新节奏、不改凭据读取方式。
- 不做交互：没有按 key 的筛选、没有日期范围、不能下钻。
- **不替换**现有的 `amount?month&year` / `cost?month&year`。它们继续供 `DeepSeekUsageParser` 与其余区块使用，
  本次一行不动。
- 不做今日口径的按 key 拆分（表口径与 `By model` 一致，都是本月至今日）。
- 不给 API key 模式（`user/balance` 那条路）加这张表 —— 私有端点不接受 API key 认证（§2.2）。

## 2. 数据来源

### 2.1 现有三个端点（本次不动）

```
GET /api/v0/users/get_user_summary          → 余额（summary）
GET /api/v0/usage/amount?month=&year=       → 按天 / 按模型 tokens（amount）
GET /api/v0/usage/cost?month=&year=         → 按天 / 按模型 / 按币种花费（cost）
```

三者由 `DeepSeekUsageProvider.fetchUsageBundle` 并发取回，合成 bundle `{summary, amount, cost}`
（`bundle(summary:amount:cost:)`）。`DeepSeekUsageParser.parsePlatformBundle` 与 `DeepSeekUsageDetail.make`
都只认这个 bundle。

### 2.2 新增两个端点

```
GET /api/v0/usage/by_api_key/amount?start=<unix>&end=<unix>&tz=<秒>
GET /api/v0/usage/by_api_key/cost?start=<unix>&end=<unix>&tz=<秒>
```

平台用量页自己加载的就是这份按 key 的日桶数据。**参数语义**：

| 参数 | 含义 |
| --- | --- |
| `start` | 起始日的自然日零点，unix 秒 |
| `end` | 截止日的**次日**零点，unix 秒（上界排他，覆盖到今天整天） |
| `tz` | 切「日」用的固定 UTC 偏移，单位是**秒**（不是小时） |

**鉴权**：只认 Platform 登录会话（`Bearer <userToken>` + cookie），**API key 认证不了**。
所以这条路径只存在于 `browserLogin` 模式；走 API key 查 `api.deepseek.com/user/balance` 的公开路径没有 bundle，
本来也不产详情。请求头沿用既有 `fetchPlatformData` 的四项（`Accept` / `Accept-Language` /
`Authorization` / `Cookie`），不额外引入 `x-client-platform` —— 若实测被拒再补（§11 验收 1）。

### 2.3 响应形状

下面是**据 §2.4 的来源核出的形状**：字段名与嵌套取自第三方实现的解码器，示例值是照该形状编的，
**不是抓包原文**。实测结论出来前，这一节是待验证的假设。

**amount**

```json
{
  "code": 0,
  "data": {
    "biz_code": 0,
    "biz_data": {
      "series": [
        {
          "api_key": { "name": "prod", "tracking_id": "sk-…8f2a" },
          "model": "deepseek-chat",
          "buckets": [
            {
              "time": 1790208000,
              "usage": {
                "REQUEST": "128",
                "RESPONSE_TOKEN": "40211",
                "PROMPT_CACHE_HIT_TOKEN": "91304",
                "PROMPT_CACHE_MISS_TOKEN": "12087"
              }
            }
          ]
        }
      ]
    }
  }
}
```

**cost**

```json
{
  "code": 0,
  "data": {
    "biz_code": 0,
    "biz_data": {
      "data": [
        {
          "currency": "CNY",
          "series": [
            {
              "api_key": "prod",
              "model": "deepseek-chat",
              "buckets": [ { "time": 1790208000, "cost": "1.2843" } ]
            }
          ]
        }
      ]
    }
  }
}
```

必须写进实现的五条：

1. **`api_key` 有两种形态**：对象 `{name, tracking_id}`，或**裸字符串**（见上面 cost 的例子）。
   两种都要认。`name` 是用户给 key 起的名字，`tracking_id` 是密钥前缀。
2. **bucket 里的标量可能是字符串、数字或 `null`**（proto3 省略 0 时会缺席）。一律走宽松解码，取不到算 0。
3. **amount 的 `usage` 是字典** `{TYPE: 值}`；而 `DeepSeekPayload.intAmount(in:type:)` 处理的是
   数组形态 `[{type, amount}]`（现有 `amount?month` 端点用的那个）。两者形状不同，要各走一条。
4. **cost 的 `series` 嵌在币种里**（`data.biz_data.data[] = {currency, series[]}`），
   而现有 cost 端点是 `data[] = {currency, days[]}`。同样要各走一条。
5. **`time` 是时间戳**，不是日期字符串。要转成 UTC 自然日后再与本月日列表比对（§5.1）。

### 2.4 形状知识来源与置信度

上面两份示例是**按第三方实现核出的形状**，不是本机实测：

- 端点路径、`start`/`end`/`tz` 语义、`x-client-platform` 头：来自 CodexBar 的
  `docs/deepseek.md` 与其 `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageFetcher.swift`
  （2026-10-06 读，`usageWindow(now:calendar:)` 给出 `end = today + 1 天`）。
- JSON 字段名与嵌套（`biz_data.series[].api_key/model/buckets[]`、`buckets[].usage[].time`、
  cost 侧的币种层、`api_key` 的两种形态、标量的宽松解码）：来自同一仓库的
  `DeepSeekUsageCostParser.swift` 里 `ByAPIKeyAmountSeries` / `ByAPIKeyCostSeries` /
  `ByAPIKeyIdentity` / `ByAPIKeyScalar` 几个 Decodable 定义。

因此**实现的第一步是实测**：用本机已登录的 DeepSeek 会话打一次真实请求，把返回的原始 JSON 落到
debug log，确认形状与 §2.3 一致、且 `amount`/`cost` 的汇总能对上 `By model` 表的合计。
对不上时按 §5.4 处置。这一步的结论要写回本文件（照 Cursor spec §2「在本机实测」的体例）。

## 3. 取数

### 3.1 窗口参数

按**本月至今日**切，与 `By model` 表同口径。`tz = 0`，与 `DeepSeekUsageDetail` 用的
`UsageDetailSupport.utcCalendar()` 一致 —— 这是这张表能和 `By model` 表放在一起的前提：
两张表按同一个自然日边界切分，合计才对得上。

```
start = 本月 1 日 00:00:00 UTC 的 unix 秒
end   = 明日 00:00:00 UTC 的 unix 秒
tz    = 0
```

窗口计算放在 **`UsageDetailSupport`**（它已经有 `utcCalendar()` 与 `monthToDateDayList(day:calendar:)`，
正是同一类日期 helper），纯函数、可测：

```swift
/// 本月至今日的 unix 秒窗口：本月 1 日 00:00 UTC 起、明日 00:00 UTC 止（上界排他）。
static func monthToDateWindow(now: Date, calendar: Calendar) -> (start: Int, end: Int)
```

`DeepSeekUsagePeriod.day` 只有 `yyyy-MM-dd`，没有时刻，窗口推不出来。
`fetchPlatformUsage` 里改成先取**一次** `let now = Date()`，`period` 与窗口都由这同一个 `now` 算出 ——
两处各自 `Date()` 会在 UTC 午夜前后落到不同的日子，查询窗口就会和 `period` 指向的那天错开。
脚本路径由 `WebSessionFetchContext` 带（§3.3）。两处调用同一个函数，窗口逻辑只有一份。

### 3.2 native 路径

`fetchUsageBundle(session:period:)` 从三个 `async let` 变成五个：

```swift
async let summary = fetchPlatformData(session: session, path: "/api/v0/users/get_user_summary", query: [:])
async let amount  = fetchPlatformData(session: session, path: "/api/v0/usage/amount", query: [...])
async let cost    = fetchPlatformData(session: session, path: "/api/v0/usage/cost", query: [...])
async let byKeyAmount = fetchPlatformDataOptional(session: session, path: "/api/v0/usage/by_api_key/amount", query: windowQuery)
async let byKeyCost   = fetchPlatformDataOptional(session: session, path: "/api/v0/usage/by_api_key/cost", query: windowQuery)
```

`fetchPlatformDataOptional` 是新增的一层薄包装：`do { return try await fetchPlatformData(...) } catch { return nil }`，
**吞掉所有错误**（含非 2xx 与网络错），只把结果记进 `WebSessionLog.debugLog`。
这是本次唯一的行为性设计：私有端点随时可能变，不该为它拖垮整次刷新。

bundle 构造函数扩成五项，后两项是 `Data?`，`nil` 写成 JSON `null`：

```swift
private func bundle(summary: Data, amount: Data, cost: Data, byKeyAmount: Data?, byKeyCost: Data?) throws -> Data
// → { "summary": …, "amount": …, "cost": …, "byKeyAmount": …, "byKeyCost": … }
```

现有三个端点维持原样：任一失败仍照今天的方式抛出并触发 web-session 回落。

### 3.3 web-session 路径

`DeepSeekWebSessionDescriptor.usageFetchScript` 里，现有的 `request(path)` 闭包已经处理了 token 与 cookie，
直接复用再加两条：

```js
const byKeyAmount = request('/api/v0/usage/by_api_key/amount?start=…&end=…&tz=0');
const byKeyCost   = request('/api/v0/usage/by_api_key/cost?start=…&end=…&tz=0');
```

**这两条不进 `firstFailure`** —— 现有那三行

```js
const firstFailure = [summary, amount, cost].find(item => !item.ok);
```

保持只审这三个。返回体加两个字段 `byKeyAmount` / `byKeyCost`，失败时为 `null`。
`usageData(fromScriptResult:)` 原样透传整份 JSON，不需要改。

`WebSessionFetchContext` 目前只有 `year` / `month` 两个字段（`WebSessionDescriptor.swift:3`），
脚本里要用 `start` / `end`，得给它补两个 **unix 秒** 字段。

**这是共享类型**：六个 provider 的脚本都收它。构造点只有两处 ——
`DeepSeekUsageProvider.swift:43`（真值来自 §3.1 的窗口）与 `WebSessionDescriptor.swift:149` 的
`currentUTC(now:)`（其余 provider 的占位值，让它顺带算出本月窗口，语义仍然自洽）。
两个字段**不给默认值** —— 默认值会让「忘了填」静默变成一个错窗口。测试里另有 3 处构造
（`WebSessionDescriptorTests:82`、`OpenCodeGoWebSessionScriptTests:90`、`OpenCodeGoWebSessionDescriptorTests:71`），
机械补两个参数即可。

## 4. 解析

`DeepSeekPayload` 增补 by_api_key 的形状走查，与解析器共享一份（照它现有的分工：形状知识只有一处）：

```swift
/// 一把 API key 的身份。name 是用户起的名字，trackingID 是密钥前缀。
struct APIKeyIdentity: Equatable {
    var name: String?
    var trackingID: String?
}

struct APIKeyAmountSeries {
    var apiKey: APIKeyIdentity?
    var model: String?
    var buckets: [[String: Any]]
}

struct APIKeyCostSeries {
    var apiKey: APIKeyIdentity?
    var model: String?
    var buckets: [[String: Any]]   // 每项 {time, cost}
}

struct APIKeyCostCurrency {
    var currency: String
    var series: [APIKeyCostSeries]
}

static func apiKeyAmountSeries(fromAmount root: [String: Any]) -> [APIKeyAmountSeries]
static func apiKeyCostCurrencies(fromCost root: [String: Any]) -> [APIKeyCostCurrency]

/// 字典形态的 usage（by_api_key 的 bucket），与数组形态的 intAmount 各走一条。
static func intAmount(inUsageDict dict: [String: Any], type: String) -> Int
static func costAmount(inBucket bucket: [String: Any]) -> Decimal
/// 解析 api_key 字段的两种形态。
static func apiKeyIdentity(from value: Any?) -> APIKeyIdentity?
```

- 走查路径复用既有的 `bizData(from:)` / `costCurrencyItems(from:)` 一路的风格：`data.biz_data` 缺席时退回上一层。
- 标量一律走既有 `decimalValue(_:)`（它已处理字符串 / 数字 / 带千分位的字符串），再 `max(0, …)` 取整。
- `api_keyIdentity(from:)`：字符串 → `APIKeyIdentity(name: s, trackingID: s)`；
  对象 → 取 `name` / `tracking_id`；两者都空 → `nil`。

## 5. 详情填充

`DeepSeekUsageDetail.make` 里新增一路聚合，现有五段（headline / groups / series / breakdown / table）一行不动。

### 5.1 byKey 聚合

复用现成的私有 `Totals`（已有 requests / output / cacheHit / cacheMiss / costByCurrency 与合并逻辑）。

1. **amount 侧**：遍历 `apiKeyAmountSeries`，对每条 series 的每个 bucket：
   `time` → `Date(timeIntervalSince1970:)` → UTC `startOfDay` → **只收进 `daysInRange` 里的**（越界丢弃，
   与现有 `dayTotals` 的 `allowed` 过滤同一条规矩）。
   按 `apiKey` 的身份聚合 requests / outputTokens / cacheHitTokens / cacheMissTokens。
2. **cost 侧**：遍历 `apiKeyCostCurrencies`，同样过滤，按币种累加 `costByCurrency`。
3. 两路结果合并进同一张 `[keyID: Totals]`（照现有 `merge(_:into:)` 的写法加一个重载）。

聚合键 `keyID`：`trackingID` 非空则用它，否则用 `name`，都没有则 `"unknown"`。
分开聚合、最后合并，是为了让同一个 key 跨多个 model 的行能归到一行。

### 5.2 表

```swift
/// byKey 的值是「聚合合计 + 这把 key 的候选展示名」；排序与去重（§5.3）都在本函数里做。
private static func keyTable(_ byKey: [String: (totals: Totals, candidateName: String)]) -> DetailTable?
```

与 `table(_ byModel:)` 逐条对齐：

| 项 | 值 |
| --- | --- |
| 过滤 | `totals.hasAnything` 为假的行不画（0 请求、0 token、0 花费） |
| 排序 | tokens 降序，其次展示名升序（稳定、可断言） |
| 上限 | `tableRowLimit` = 6，截断时 `footnote = "+N more API keys"` |
| title | `By API key · this month` |
| columns | `["API key", "Requests", "Tokens", "Cost"]` |
| cells | `compactAmount(requests)` / `compactAmount(tokens)` / `costText(costByCurrency)`（多币种 ` · ` 串，空则 `—`） |

一个 key 都没有 → 返回 `nil`，浮层不画这段。

### 5.3 展示名与去重

展示名：`name` 非空用 `name`，否则 `trackingID`，都没有则 `Unknown key`。

**必须去重**：`DetailTableRow.id` 取 `name`（`UsageDetail.swift` 顶部写明的不变量），同表内重名会让
`ForEach` 出错。而用户完全可能给两把 key 起同一个名字。

规则（可断言）：按 §5.2 的排序定好行序后，先算出每行的候选展示名；若某个候选名在表内出现 ≥2 次，
**这些行**一律改成 `"\(候选名) · \(keyID 前 8 位)"`；若 `keyID` 与候选名相同（即两者都来自裸字符串形态），
退化为 `"\(候选名) #\(该名组内按行序的 1 起序号)"`。只改冲突的那些行，不冲突的行保持原样。
去重作用在**截断前**的全部行上 —— 否则第 7 行被截掉后，前 6 行里那对重名反而逃过了改名。

### 5.4 与 `By model` 对不上时

`by_api_key` 覆盖的是不是账户全量、能否与 `By model` 的合计对齐，要等实测（§2.4）。

- 对得上 → 标题保持 `By API key · this month`，两张表并排天然自洽。
- 对不上（例如它只覆盖「有 key 记录的调用」）→ 标题改成 `By API key · this month` 保留，
  但**脚注位**补一句口径说明（形如 `Excludes usage without an API key`），避免读者拿两张表的合计互推。
  具体文案以实测结论为准，写回本文件。

## 6. 视图接口改动

本次动到**两个共享类型**：`UsageDetail`（浮层内容模型）与 `WebSessionFetchContext`（§3.3）。
两处的改法都在下面，其余文件零改动。

### 6.1 `UsageDetail`

它现在只放得下一张表：

```swift
var table: DetailTable? = nil
```

改成数组，浮层可以有多个表格区块：

```swift
var tables: [DetailTable] = []
```

`isEmpty` 的判据跟着从 `table == nil` 改成 `tables.isEmpty`。

改动点清单：

| 位置 | 改法 |
| --- | --- |
| `Sources/TokenHealth/UsageDetail.swift` | 字段与 `isEmpty` |
| `Sources/TokenHealth/DetailPopoverView.swift:154-190` | 抽成 `tableSection(_ table: DetailTable)`，用 `ForEach(detail.tables)` 调用 |
| `Sources/TokenHealth/CodexUsageDetail.swift:32` | `detail.table = …` → `detail.tables = [ … ]` |
| `Sources/TokenHealth/CursorUsageDetail.swift:103` | 同上 |
| `Sources/TokenHealth/OpenCodeGoUsageDetail.swift:54` | 同上 |
| `Sources/TokenHealth/DeepSeekUsageDetail.swift:57` | 改成 `[modelTable, keyTable].compactMap { $0 }` |
| 测试约 30 处 `.table` | `detail.table` → `detail.tables.first`；`== nil` → `.isEmpty` |

渲染顺序就是数组顺序：DeepSeek 是 `By model` 在前、`By API key` 在后。

### 6.2 `WebSessionFetchContext`

补 `start` / `end` 两个 unix 秒字段，改法与影响面见 §3.3 —— 定义一处、构造点两处、测试三处，
其余 provider 的脚本不读它们。

## 7. 文案表

| 位置 | 文案 |
| --- | --- |
| 表标题 | `By API key · this month` |
| 列 | `API key` / `Requests` / `Tokens` / `Cost` |
| 脚注 | `+N more API keys` |
| 无身份的 key | `Unknown key` |
| 表名冲突时的后缀 | `名 · <id 前 8 位>`，退化 `名 #N` |

表标题里的 `· this month` 与 `By model · this month` 保持同一种写法（中点前后各一个空格）。

## 8. 错误与边界

| 情况 | 表现 |
| --- | --- |
| `by_api_key` 任一端点 404 / 超时 / 非 2xx | 对应键为 `null`：不画 key 表，其余区块与菜单栏数字照常 |
| `by_api_key` 响应解不出（形状变了） | 同上 |
| cost 到位、amount 缺失（或反之） | 已有的那一半照画（cost 表头为 `—` 时也一样） |
| `api_key` 对象里 `name` / `tracking_id` 都空 | 归到 `Unknown key` 一行 |
| 某 bucket 的 `time` 落在本月之外 | 丢弃该 bucket |
| bucket 的标量为 `null` / 负数 | 当 0 / 取 `max(0, …)` |
| 两把 key 展示名相同 | 按 §5.3 加后缀 |
| 一个 key 都没有 | `tables` 里只有 `By model` 那张 |
| 表内某 key 全是 0 | `hasAnything` 为假，不占行 |
| 刷新失败但有旧 detail | 沿用 `AppState.storeSnapshot` 的「非 ready 且无新 detail 时保留上次 detail」 |

## 9. 测试策略

跑测试一律 `bash scripts/test.sh`（本机只有 CommandLineTools，直接 `swift test` 会报
`no such module 'Testing'`）。

| 测试 | 覆盖 |
| --- | --- |
| `DeepSeekPayloadTests`（扩） | `api_key` 的两种形态（对象 / 裸字符串）；`biz_data` 缺席时的退回；字典形态 `usage` 的取值（字符串 / 数字 / `null` / 负数）；cost 的币种层嵌套；空 `series` 与空 `buckets` |
| `DeepSeekUsageDetailTests`（扩） | 按 key 聚合：同一 key 跨多模型合成一行；两个 key 分开；`tokens` 降序 + 名字升序的稳定排序；6 行截断与 `+N more API keys`；越界 `time` 丢弃；`hasAnything` 为假的 key 不占行；成本列多币种 ` · ` 串与空串 `—`；**同名去重**（含裸字符串形态退化成 `#N` 的分支）；`Unknown key` 归并；amount 或 cost 单侧缺失时的降级 |
| `DeepSeekDetailWiringTests`（扩） | bundle 带 `byKeyAmount` / `byKeyCost` 时 `detail.tables.count == 2`；两者为 `null` 时只有 `By model` 一张；`By API key` 表的内容与注入数据一致 |
| `UsageDetailSupportTests`（新） | `monthToDateWindow`：`start` 是本月 1 日 00:00 UTC、`end` 是明日 00:00 UTC；跨月边界（1 号当天）、跨年（12 月 → 1 月）、月末（1 月 31 日 → 2 月 1 日） |
| `WebSessionDescriptorTests`（扩；DeepSeek 的脚本用例在这个文件里，`private let descriptor = DeepSeekWebSessionDescriptor()`） | 脚本里出现两条 `by_api_key` 路径与 `start`/`end`/`tz` 参数；`firstFailure` 数组**不含**它们；失败时返回体里两个字段为 `null` |
| `DetailPopoverRenderTests`（扩） | `tables` 有两张时两段都渲染，顺序=数组顺序 |
| 既有测试 | 全绿；`.table` → `.tables` 的机械改动不改变任何断言语义 |

## 10. 已知取舍

- **多两个请求**：DeepSeek 每次刷新 3 → 5 个请求。最短刷新间隔 30 秒，两个请求都是小响应（一个月、按 key 的日桶）。
  不加缓存 —— 详情本来就是「跟这次刷新同一批」的东西，为一张可选表引入缓存会成为新的状态。
- **不替换现有端点**：by_api_key 的 `series` 同时带 `api_key` 和 `model`，理论上一次就能切出两个维度、
  请求数不增。但现有 `parseTodayAmounts` / `parseTodayCosts` 依赖 `amount?month` 的 `days` 形状，
  换源要重写解析与它的一整套测试；更关键的是没有实测证据说明 by_api_key 的汇总等于账户总量
  （CodexBar 只用它算「今日 / 近 30 天」，不含账户级对照）。先用最小改动落地，换源留给有实测数据之后。
- **单 key 账户也画这张表**：只有一把 key 时，表的内容与 `This month` 汇总高度重合。仍然画 ——
  多一个「这张表什么时候出现」的条件，比多画一张小表更容易让人困惑。
- **口径只做本月至今日**：与 `By model` 一致。`by_api_key` 的start/end 本来支持任意窗口，
  但两张表口径不同会让人误以为数字对不上。
- **`tz` 固定 0**：平台默认按浏览器时区切日，本项目其余部分（`UsageDetailSupport.utcCalendar()`）一律 UTC。
  跟着面板走，不跟浏览器走。
- **只展示，不排序不筛选**：与浮层「不可交互」的定位一致。

## 11. 验收

1. **实测先行**：本机登录会话打一次 `by_api_key/amount` 与 `by_api_key/cost`（本月窗口），
   原始 JSON 落 debug log，确认 §2.3 的形状；核对汇总能否与 `By model` 表的合计对齐。
   结论（含被拒时的请求头调整）写回本文件 §2.3 / §2.4 / §5.4。
2. `bash scripts/test.sh` 全绿。
3. `bash scripts/build-app.sh` 通过，装到 `/Applications/Token Health.app`，用
   `plutil -extract CFBundleShortVersionString raw` 核对是 **1.0.7**。
4. 手动：点钉住的 DeepSeek 项 → 浮层在 `By model · this month` 下面出现 `By API key · this month`，
   列与排序正确，行数与自己的平台用量页对得上。
5. 手动：把 `by_api_key` 请求打断（断网 / 改路径）→ key 表消失，其余区块与菜单栏数字完全不变。
6. 回归：钉住的 Codex / Cursor / OpenCode Go 浮层不变（`tables` 数组改造后各只有一张表）。
7. 手动：两把 key 起同一个名字时，表里两行都带 id 后缀、不串行。
