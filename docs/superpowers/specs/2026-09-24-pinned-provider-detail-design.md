# 钉住项的用量详情浮层 设计

日期：2026-09-24
状态：已批准，待实现

## 1. 背景与目标

钉住的账号现在只显示一个「一眼就知道大概」的菜单栏项。想看得细一点，就得回厂商的控制台网页。

本次让**钉住的菜单栏项点下去弹一个详情浮层**，把该账号的用量明细铺开。第一个做 DeepSeek。

**目标**

- 点钉住的 DeepSeek 项 → 弹出浮层，展示余额、今日/本月合计、本月按天趋势、tokens 构成、按模型拆分。
- 数据全部来自**已经抓回来的**接口响应，不新增任何网络请求。
- 详情模型做成通用的，后续 Provider 填空即可，视图不用重写。
- 不支持详情的 Provider 行为不变，仍然弹原来的 Unpin / Settings / Quit 小菜单。

**非目标**

- **不试图替代厂商的控制台网页。** 这是一个「抬眼扫一下」的展示，不是分析工具。
- 不做任何交互：趋势图不可悬停、不可缩放、不可选日期范围；没有筛选、没有导出。
- 不做自定义时间范围，只展示「当月 1 号至今」。
- 不做跨账号汇总，一个浮层只讲一个账号。
- 不引入 Charts 或任何第三方绘图依赖。
- 本期只做 DeepSeek，其余 Provider 只留好接口。

## 2. 术语

- **详情**：`UsageDetail`，一个与 Provider 无关的值类型，描述浮层要画的内容。
- **bundle**：DeepSeek 一次刷新并发取回的三份响应（summary / amount / cost）拼成的 JSON。
  网页会话兜底路径产出的 bundle 形状完全相同，两条路径共用同一份详情解析。
- **当月**：按 UTC 计算的当前自然月。
- **支持详情**：某个 config 是否会产出 detail。见 §7。

## 3. 数据来源

`DeepSeekUsageProvider.fetchUsageBundle` 已经并发取了三个端点，当前只解析了其中一小部分：

| 端点 | 现有用途 | 本次新增用途 |
| --- | --- | --- |
| `/api/v0/users/get_user_summary` | 各币种余额 | 同左（直接复用已解析的 `[TokenUsage]`） |
| `/api/v0/usage/amount?month=&year=` | 只有**今天**一天的总量 | 整月每一天、每个模型，按四种 `type` 拆开 |
| `/api/v0/usage/cost?month=&year=` | 只有今天 | 整月每一天、每个模型的费用 |

`amount` 的 `type` 有四种：`REQUEST`、`RESPONSE_TOKEN`、`PROMPT_CACHE_HIT_TOKEN`、`PROMPT_CACHE_MISS_TOKEN`。
tokens = 后三者之和。`REQUEST` 单独计数。

两个端点的形状**不对称**，解析时必须分别处理（既有代码已经如此）：

- `amount`：`{code, data:{biz_data:{days:[{date, data:[{model, usage:[{type, amount}]}]}]}}}`
- `cost`：`{data:[{currency, days:[{date, data:[{model, usage:[{amount}]}]}]}]}` —— 顶层是**币种数组**，每个币种各自带一套 `days`。

**因此本次不新增任何请求**，只是把已经躺在内存里的数据解析出来并带进快照。

## 4. 通用详情模型

新增 `Sources/TokenHealth/UsageDetail.swift`：

```swift
/// 详情浮层要展示的内容。与 Provider 无关，浮层只认这个类型。
struct UsageDetail: Equatable, Sendable {
    var headline: [DetailStat] = []
    var groups: [DetailGroup] = []
    var series: DetailSeries? = nil
    var breakdown: [DetailStat] = []
    var table: DetailTable? = nil
}

struct DetailStat: Equatable, Sendable, Identifiable {
    var id: String { label }
    var label: String        // "Output" / "CNY"
    var value: String        // "8.1M" / "1,284.60 CNY"
}

struct DetailGroup: Equatable, Sendable, Identifiable {
    var id: String { title }
    var title: String        // "Today"
    var values: [DetailStat] // 依次横排：次数、tokens、花费
}

struct DetailSeries: Equatable, Sendable {
    var title: String               // "Tokens this month"
    var points: [DetailSeriesPoint] // 按日期升序
    var axisStart: String           // "9/1"
    var axisEnd: String             // "9/24"
}

struct DetailSeriesPoint: Equatable, Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var value: Double
}

struct DetailTable: Equatable, Sendable {
    var title: String          // "By model · this month"
    var columns: [String]      // ["Model", "Requests", "Tokens", "Cost"]
    var rows: [DetailTableRow]
    var footnote: String?      // "+3 more models"
}

struct DetailTableRow: Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var cells: [String]        // 对应 columns 去掉首列后的其余列，即 count == columns.count - 1
}
```

**不变量**：`DetailStat.id` 取 `label`、`DetailTableRow.id` 取 `name`，所以同一个集合内 `label` / `name` 必须唯一 —— 否则 `ForEach` 会出问题。各 Provider 在填充时必须先聚合去重。

模型里**只放已经成型的展示文本**，不放原始数值 —— 与既有的 `TokenUsage.displayValue` 同一路数。
唯一的例外是 `DetailSeriesPoint.value`：柱高要按最大值归一化，那是视图必须做的算术。

`ProviderUsageSnapshot` 增加 `var detail: UsageDetail? = nil`（附带默认值，既有构造点全部不受影响；快照不持久化，无迁移问题）。

## 5. DeepSeek 的填充规则

新增 `Sources/TokenHealth/DeepSeekUsageDetail.swift`。

### 5.1 共用解析规则

- **按日期聚合**：`days` 里同一天出现多次时**按天求和**，不是取第一条。这样既不丢数据也不会重复计数。所有「今日」「本月」「每日序列」都走同一个聚合结果。
- **日期解析**：取 `date` 字符串的**前 10 个字符**按 `yyyy-MM-dd` 解析（UTC，与 `DeepSeekUsagePeriod.currentUTC()` 同一口径）—— 取前缀而不是整串匹配，是为了容忍 `"2026-09-24T00:00:00Z"` 这类带后缀的写法，与既有解析器的 `hasPrefix` 同样宽容。再格式化成 `M/d` 给坐标轴。
- **日期解析失败的天整条跳过**（不进任何合计），不猜。
- **只统计日期落在 [当月 1 号, 今天] 区间内的天**：接口理论上只返回当月，但万一返回了上月或未来的日期，让它只进「本月」不进「趋势图」会让两处数字打架。
- **今日**：聚合结果里等于今天的那一天；**没有这一天就是全 0**（正常情况：今天还没产生用量）。
- **本月**：聚合结果里所有天求和，即当月 1 号至今。
- 每个模型的 `usage` 数组可能为空或缺字段，缺失一律当 0，不抛错。

### 5.2 余额（headline）

直接取已解析出的 `[TokenUsage]` 里 `window == .balance` 的那些（`amount` + `unit` 都在），每个币种一行：
`label` 是币种代码，`value` 是金额 + 币种代码，例如 `1,284.60 CNY`。币种顺序沿用既有的币种名升序。

**不做换算** —— 换算只作用于菜单栏那一项。

### 5.3 今日与本月（groups）

各一组，三个值依次是「请求次数」「tokens」「花费」。

- 次数用 `REQUEST` 求和，tokens 用三种 token type 求和。
- 次数与 tokens 用既有的紧凑数字格式（K/M/B）。
- 花费来自 cost 响应，**按币种分组**：单币种就是 `41.80 CNY`；多币种用 ` · ` 连接（`41.80 CNY · 0.30 USD`），币种顺序同样按币种名升序。
- **「没有 cost 数据」的判定**：响应里**一个币种条目都没有**时花费显示 `—`；币种条目存在但金额为 0，正常显示 `0.00 CNY`。两种情况不混为一谈。

**金额格式统一用既有的 `moneyText`**（两位小数、千位分隔、不带单位）再追加币种代码。不发明 `¥` / `$` 符号表 —— 代码库里既有的约定就是币种代码，面板与菜单栏都是这样。求和的**口径**与既有解析器一致（把一个 item 的 `usage` 数组全部相加）。

**不要声称两处数字逐位相同**：面板的今日花费是 4 位小数、且同一天出现两次时只取第一条；浮层是 2 位小数、且按天求和。同一个响应下两者可能不同。能保证的是**同源、同月同口径**（当月 1 号至今，UTC）。

### 5.4 按天趋势（series）

- 覆盖**当月 1 号到今天**（UTC），逐日一个点；**没有数据的日期补 0**，这样横轴等距、峰值位置可信。
- 每个点的值 = 该日三种 token type 之和。
- `axisStart` = 1 号，`axisEnd` = 今天。
- 整月全为 0 时 `series` 仍照常产出（当月 1 号到今天的每一个点都是 0），由视图显示 `No usage this month`；不让解析层去猜视图要不要画。

### 5.5 tokens 构成（breakdown）

本月三个 token type 各自的合计，label 用 §7.3 文案表里的 `Output` / `Cache hit` / `Cache miss`，
外加一个 `Hit rate`：**命中 /（命中 + 未命中）**，一位小数。

输出 tokens 不进这个分母 —— 输出本来就不过缓存，混进去会把命中率压低，看着像缓存坏了。
命中 + 未命中为 0 时显示 `—`，不拿一个除零出来的数字糊弄人。

### 5.6 按模型（table）

- **取 amount 与 cost 两个响应的模型名并集**，逐模型聚合本月的次数、tokens、花费。
- **关联规则**：
  - 只在 amount 里的模型：花费格显示 `—`。
  - 只在 cost 里的模型：次数与 tokens 为 0，**仍然成行**（它确实花了钱）。
  - 模型名为空或缺失：两个响应里的这类行**合并成同一行** `Unknown model`（见 §7.3 文案表）。
- **花费列**用与 groups 相同的币种规则：单币种就是金额 + 代码，多币种用 ` · ` 连接。
- **排序**：tokens 降序，相同时模型名升序（沿用既有解析器的约定）。
- **tokens 与花费都为 0 的模型不成行** —— 沿用既有解析器的做法（它也会丢掉空模型），否则它们会白占掉 6 行里的位置、还把 footnote 的计数撑大。
- **只列前 6 行**，其余聚合进 `footnote`（`+N more models`）；被截断的行不参与任何总计 —— 总计在 §5.3 里按全量算。

## 6. 趋势图的几何

新增 `Sources/TokenHealth/DetailSeriesChart.swift`，**纯计算，不碰 AppKit**（与 `MenuBarItemLayout` 同一路数）：

```swift
enum DetailSeriesChart {
    /// 归一化后的柱高，与 points 一一对应。
    static func heights(points: [DetailSeriesPoint], maxHeight: CGFloat, minimumVisibleHeight: CGFloat) -> [CGFloat]
    /// 归一化基准：所有点的最大值；全 0 或空序列返回 0。
    static func maximum(of points: [DetailSeriesPoint]) -> Double
}
```

- `maximum` 为 0 时所有柱高为 0（由视图显示 `No usage this month`）。
- 值为 0 的日期柱高为 0；非 0 但极小的值托到 `minimumVisibleHeight`，避免看不见。
- 日期补 0 是**解析层**（§5.4）的职责，几何层不造点。

`DetailPopoverView` 只负责把算好的高度画成矩形。

## 7. 浮层与触发

### 7.1 什么时候弹浮层

**按 Provider 能力判断，不是按快照内容判断。**

```swift
extension ProviderFactory {
    /// 这个 config 会不会产出详情。目前只有配置成登录模式的 DeepSeek 会。
    ///
    /// 这个判断只看得到 config，看不到已存的凭据 —— 而 Provider 取数时是先看凭据里有没有
    /// 网页会话、再看 `authMode` 的。所以一个配成 API 模式、但 Keychain 里还留着网页会话的
    /// DeepSeek 账号，实际上会取回带明细的平台数据，而这里回报 false。无害（只是不给它弹浮层），
    /// 但注释里别把「API 模式一定走公开余额接口」说死。
    static func producesUsageDetail(for config: ServiceConfig) -> Bool
}
```

这样「首次刷新还没回来」时点下去也能弹浮层（显示 `Loading…`），而不是先弹旧菜单、等快照回来再改行为。

### 7.2 控制器改动

`PinnedStatusItemController`：

- `producesUsageDetail` 为真 → **`item.menu = nil`**，设 `button.target/action`，点击弹 `NSPopover`
  （`behavior = .transient`，点外面自动关；`show(relativeTo:of:preferredEdge:)` 挂在该按钮上）。
- 为假 → **`item.menu = makeMenu(...)`**，并清掉 `button.target/action`。
- 两个分支都要**显式赋值**：`menu` 非空时按钮点击根本不会触发 action，只在需要时跳过赋值会留下过期的菜单。切换方向（支持 → 不支持，例如账号改成 API key 模式）同样要清干净。
- 按钮到账号的映射靠 `button.identifier = NSUserInterfaceItemIdentifier(config.id.uuidString)`，**在创建状态项时设置一次**（它在重绘间不变），因为 `NSStatusBarButton` 没有 `representedObject`。
- 同一个浮层只允许存在一个：弹新的之前先关掉旧的。
- 浮层打开期间数据刷新完成 → **把新的 `UsageDetail` 重新赋给 `hostingController.rootView`**，内容就地更新，浮层不关闭。
- 状态项被移除（unpin / 禁用 / 删除）→ 一并关掉浮层。
- `stop()` 时一并关掉浮层。

### 7.3 浮层视图

新增 `Sources/TokenHealth/DetailPopoverView.swift`。输入全部是值，**没有可变状态**：

```swift
struct DetailPopoverView: View {
    let serviceName: String
    let detail: UsageDetail?        // nil = 还没有详情
    let statusMessage: String?      // 非 nil 且 detail 有内容时，顶部显示错误行
    let updatedAt: Date?            // nil = 还没有快照
    let onRefresh: () -> Void
    let onUnpin: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void          // 底部四个按钮，别漏掉 Quit
}
```

**「还没有快照」与「快照不可用」要能区分开**：`updatedAt == nil` 表示前者（显示 `Loading…`）；`statusMessage` 非 nil 表示后者（有旧数据时显示旧数据 + 错误行，没有旧数据时只显示错误行）。

**文案与 App 其余部分一致，全部用英文**（§5 里那些中文名是在描述内容，不是字面量）：

| 位置 | 文案 |
| --- | --- |
| 分组标题 | `Today` / `This month` |
| 分组与表格里的三个值 | `Requests` / `Tokens` / `Cost` |
| tokens 构成 | `Output` / `Cache hit` / `Cache miss` / `Hit rate` |
| 表格标题与表头 | `By model · this month` / `Model` `Requests` `Tokens` `Cost` |
| 趋势图标题 | `Tokens this month` |
| 没有模型名 | `Unknown model` |
| 本月无数据 | `No usage this month` |
| 没有花费数据 | `—` |
| 还没有快照 | `Loading…` |
| 被截断的模型 | `+N more models` |
| 底部按钮 | `Unpin` / `Settings` / `Quit` |

版式自上而下：标题行（账号名 · 更新时间 · ⟳）→ headline → groups → series → breakdown → table → 分隔线 → `Unpin` `Settings` `Quit`。

- 宽度固定 320，高度自适应，上限 520，超出滚动。
- 空区块整个不渲染，不留空标题。
- 按钮用文字（按已批准的版式）。顺带的好处是这样整块浮层能在无窗口环境里完整光栅化，便于做视觉确认 —— 离屏渲染里 `Button` 包着的 SF Symbol 会变成占位符。
- 没有任何交互：柱子不可悬停、不可点击。

## 8. 刷新与「上次的好数据」

`AppState` 新增单账号刷新：

```swift
func refresh(configID: UUID) async
```

只重取这一个账号、只写它的快照。与 `refreshAll()` 共用 `isRefreshing` 互斥；整体刷新进行中时直接返回。对禁用或不存在的账号直接返回。

**取数失败时保留上次的详情**：现在失败会返回 `.unavailable` 快照，而写快照的代码会无条件覆盖 —— 那会把 detail 抹掉，浮层清空、菜单栏项还会被打回旧菜单。所以：

> 快照的写入收口到一个共用方法 `AppState.storeSnapshot(_:for:)`（`performRefresh` 与单账号刷新都走它，别只改一处）。写入时，若新状态不是 `.ready`、而该账号原快照**有** detail，则把旧 detail 与**旧的 `updatedAt`** 一起带到新快照上。

- 保留旧 `updatedAt` 而不是用失败那刻的时间：`updatedAt` 在这个 App 里一直表示「这些数字是什么时候取到的」。用失败时间会让浮层表头显示「刚刚」，而数字其实是十分钟前的。
- 副作用是 5 分钟的新鲜度检查会因此在下一次打开时重试 —— 这是想要的：上次失败了，本来就该再试。
- 第一次失败（原快照没有 detail）时没有可保留的东西，走 §9 的「只显示错误行」。
- 浮层继续显示上次的数字，同时顶部用 `statusMessage` 显示错误（红字）。面板卡片只看 `state == .ready`，所以这个合并**不会改变面板的行为**。

浮层打开时：若 `snapshot?.updatedAt` 距今超过 **5 分钟**，自动调用单账号刷新；否则直接用现有数据。右上角始终有 ⟳ 可手动触发。

## 9. 错误与边界

| 情况 | 表现 |
| --- | --- |
| 快照还没回来（首次刷新中） | 浮层显示 `Loading…`（判别方式：`updatedAt == nil`），并自动触发一次单账号刷新 |
| 快照不可用且没有旧 detail | 浮层显示 `statusMessage` 的错误行，无数据区块 |
| 快照不可用但有旧 detail | 显示旧数字 + 顶部红色错误行（§8 的合并规则） |
| 当月全无数据 | 趋势图位置显示 `No usage this month`，其余区块照常 |
| 缺少 cost 数据 | 花费显示 `—`，其余照常 |
| 模型名缺失或为空 | 合并进 `Unknown model` 一行（§5.6） |
| 哪天没有数据 | 补 0，不跳过 |
| 同一天出现两次 | 按天求和（§5.1） |
| `date` 解析失败 | 该天整条跳过，不进任何合计（§5.1） |
| 日期落在当月之外 | 不进任何合计（§5.1） |
| 余额多币种 | 逐币种列出，不换算 |
| 详情区块为空 | 该区块整个不渲染 |
| 账号被 unpin / 删除 / 禁用 | 浮层随状态项一起收掉 |

## 10. 测试策略

跑测试一律用 `bash scripts/test.sh`（本机没有 Xcode）。凡是构造 `AppState` 的测试**必须**注入 `InMemorySecretStore` 与桩汇率源 —— 真实钥匙串会弹授权框并无限期卡住，兜底汇率永远是「过期」的。

| 测试 | 覆盖 |
| --- | --- |
| `DeepSeekUsageDetailTests` | headline / 今日 / 本月 / 每日序列（含补 0 与当月全 0）/ tokens 构成 / 模型表；重复日期求和；缺 cost；模型名为空合并；多币种花费；只在 cost 里出现的模型；超过 6 行时的 footnote 与排序 |
| `DetailSeriesChartTests` | 归一化：最大值、全 0、单点、极小值托底 |
| `AppStateRefreshTests` | 单账号刷新只改那一个快照；与 `refreshAll` 互斥；对禁用账号返回；**失败时保留旧 detail** |
| `ProviderDetailCapabilityTests` | 只有登录模式的 DeepSeek 支持详情；API key 模式与其他 Provider 不支持 |
| `CompactAmountTests` | 提取出来的紧凑数字格式与既有行为逐字一致，**补上 K 与 B 分支**（既有测试只覆盖 M 与精确值） |
| 既有测试 | 全绿，尤其 `UsageMetricSelectionTests` 与面板渲染冒烟 |

视图层不做像素断言，但补一条**浮层的无窗口渲染冒烟**（与 `StatusMenuPanelRenderTests` 同一路数）：给定一个完整的 `UsageDetail`，浮层能光栅化出非零高度；给空的 `UsageDetail` 也不崩。

## 11. 顺带的清理

`UsageAmountFormatter` 里有一个私有的 `formatAmount`（K/M/B 缩写）。详情要显示同类数字，把它提成 `UsageAmountFormatter.compactAmount(_:)` 供两处共用，实现逐字不动 —— 面板的显示必须不变，由既有测试兜底。

同理，`MenuBarMetrics.moneyText` 提成 `UsageAmountFormatter.moneyText(_:)`：它是一个通用的金额格式（两位小数、千位分隔、不带单位），菜单栏与浮层都要用，不该挂在 `MenuBarMetrics` 名下。调用点各自按需追加单位。

## 12. 已知取舍

- **只读、不可交互**：这是刻意的。详情浮层的定位是「抬眼扫一下」，任何筛选、日期范围、下钻都属于厂商控制台，不该在这里重做一遍。
- **当月至今**：官方页面可以选时间范围，这里固定当月。要跨月分析请回控制台。
- **模型表截断到 6 行**：浮层不是表格工具，超出部分只给一个计数，且不参与总计。
- **趋势图补 0**：没有数据的日期补 0 而不是跳过，这样横轴等距、峰值位置可信。

## 13. 验收

1. `bash scripts/test.sh` 全绿。
2. `bash scripts/build-app.sh` 通过，并按仓库惯例装到 `/Applications` 核对版本号。
3. 手动：钉住一个**登录模式**的 DeepSeek 账号，点它的菜单栏项 → 弹出浮层，余额 / 今日 / 本月 / 趋势图 / tokens 构成 / 模型表齐全，底部三个按钮可用。
4. 手动：点浮层外面 → 浮层关闭。
5. 手动：浮层的数字与厂商控制台的当月数据对得上（同一口径：当月 1 号至今，UTC）。
6. 手动：断网后点刷新 → 浮层保留上次数字并显示红色错误行，菜单栏项**不**变回旧菜单。
7. 手动：点一个非 DeepSeek 的钉住项 → 仍然是原来的 Unpin / Settings / Quit 小菜单。
8. 手动：unpin 掉那个 DeepSeek 账号 → 浮层与菜单栏项一起消失。
