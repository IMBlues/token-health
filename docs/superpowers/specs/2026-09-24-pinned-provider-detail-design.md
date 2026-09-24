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
- 没有详情的 Provider 行为不变，仍然弹原来的 Unpin / Settings / Quit 小菜单。

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
- **当月**：按 UTC 计算的当前自然月，1 号到「今天」。

## 3. 数据来源

`DeepSeekUsageProvider.fetchUsageBundle` 已经并发取了三个端点，当前只解析了其中一小部分：

| 端点 | 现有用途 | 本次新增用途 |
| --- | --- | --- |
| `/api/v0/users/get_user_summary` | 各币种余额 | 同左（复用同一份解析结果） |
| `/api/v0/usage/amount?month=&year=` | 只有**今天**一天的总量 | 整月每一天、每个模型，按四种 `type` 拆开 |
| `/api/v0/usage/cost?month=&year=` | 只有今天 | 整月每一天、每个模型的费用 |

`amount` 的 `type` 有四种：`REQUEST`、`RESPONSE_TOKEN`、`PROMPT_CACHE_HIT_TOKEN`、`PROMPT_CACHE_MISS_TOKEN`。
tokens = 后三者之和。

**因此本次不新增任何请求**，只是把已经躺在内存里的数据解析出来并带进快照。

## 4. 通用详情模型

新增 `Sources/TokenHealth/UsageDetail.swift`：

```swift
/// 详情浮层要展示的内容。与 Provider 无关，浮层只认这个类型。
struct UsageDetail: Equatable, Sendable {
    /// 顶部大字，例如各币种余额。多币种就是多行。
    var headline: [DetailStat] = []
    /// 分组统计，例如「今日」「本月」。
    var groups: [DetailGroup] = []
    /// 按天序列，画出迷你柱状图。
    var series: DetailSeries? = nil
    /// 构成拆分，例如 tokens 的输出 / 缓存命中 / 缓存未命中。
    var breakdown: [DetailStat] = []
    /// 明细表，例如按模型。
    var table: DetailTable? = nil
}

struct DetailStat: Equatable, Sendable, Identifiable {
    var id: String { label }
    var label: String        // "输出" / "CNY"
    var value: String        // "8.1M" / "1,284.60"
}

struct DetailGroup: Equatable, Sendable, Identifiable {
    var id: String { title }
    var title: String        // "今日"
    var values: [DetailStat] // 依次横排，最后一个靠右（"12 次" "184K tokens" "¥0.42"）
}

struct DetailSeries: Equatable, Sendable {
    var title: String              // "本月 tokens"
    var points: [DetailSeriesPoint] // 按日期升序，最多 31 个
    var axisStart: String          // "9/1"
    var axisEnd: String            // "9/24"
}

struct DetailSeriesPoint: Equatable, Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var value: Double
}

struct DetailTable: Equatable, Sendable {
    var title: String          // "按模型 · 本月"
    var columns: [String]      // ["模型", "次数", "Tokens", "花费"]
    var rows: [DetailTableRow]
    var footnote: String?      // "另有 3 个模型未列出"
}

struct DetailTableRow: Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var cells: [String]        // 与 columns 一一对应，不含 name
}
```

模型里**只放已经成型的展示文本**，不放原始数值 —— 与既有的 `TokenUsage.displayValue` 同一路数。
唯一的例外是 `DetailSeriesPoint.value`：柱高需要按最大值归一化，那是视图必须做的算术。

`ProviderUsageSnapshot` 增加 `var detail: UsageDetail? = nil`。**有 detail 才弹浮层。**

## 5. DeepSeek 的填充规则

新增 `Sources/TokenHealth/DeepSeekUsageDetail.swift`，从同一份 bundle 产出 `UsageDetail`。

**余额（headline）**：复用现有的按币种合并逻辑（normal + bonus 钱包），每个币种一行，`label` 是币种、`value` 是金额（两位小数，千位分隔）。不做换算 —— 换算只作用于菜单栏那一项。

**今日与本月（groups）**：各一组，三个值依次是「请求次数」「tokens」「花费」。

- 今日 = `days` 里 date 前缀等于今天的那一天。
- 本月 = 所有 day 的合计。
- 次数用 `REQUEST`，tokens 用三种 token type 之和。
- 花费来自 cost 响应。**按币种分组**：单币种时就是一个数字（`¥0.42`），多币种时用 ` · ` 连接（`¥0.42 · $0.06`）。币种顺序按币种名升序，与余额的取法一致。

**按天趋势（series）**：`amount` 的每一天一个点，值为该日 tokens 合计（三种 token type 之和）。序列覆盖当月 1 号到有数据的最后一天；中间没有数据的日期**补 0**，这样柱状图的横轴是等距的。`axisStart` / `axisEnd` 用 `M/d` 格式。

**tokens 构成（breakdown）**：本月三个 token type 各自的合计，label 为「输出」「缓存命中」「缓存未命中」。

**按模型（table）**：按模型聚合本月的次数、tokens、花费，按 tokens 降序。**只列前 6 行**，其余聚合进 `footnote`（「另有 N 个模型未列出」）—— 浮层不是表格工具，超出部分不给它加高度。模型名为空或缺失时归到「未知模型」一行，不丢数据。

**没有 cost 数据时**（例如该月还没有产生费用）：花费那一个值显示 `—`，其余照常。不因此让整个详情失败。

## 6. 浮层

新增 `Sources/TokenHealth/DetailPopoverView.swift`：一个纯展示的 SwiftUI 视图，输入是 `UsageDetail` 加上账号名、更新时间、错误信息，以及三个回调（刷新 / unpin / 打开设置）。

版式自上而下：标题行（账号名 · 更新时间 · ⟳ 文字按钮）→ headline → groups → series → breakdown → table → 分隔线 → `Unpin` `Settings…` `Quit` 三个**文字按钮**。

- 宽度固定 320，高度自适应，上限 520；超出滚动。
- 柱状图是自己画的：每根柱子是一个按最大值归一化的矩形，不引入 Charts。
- 按钮用文字而不是 SF Symbol —— 图标按钮在无窗口渲染里画不出来，用手写渲染做视觉验证时看不见。
- 没有任何交互：柱子不可悬停、不可点击。

## 7. 控制器改动

`PinnedStatusItemController`：

- 算出该账号的 `snapshot?.detail`。**有 detail** → 不设 `item.menu`，改为设 `button.target/action`，点击弹 `NSPopover`（`behavior = .transient`，点外面自动关）。**没有 detail** → 维持现状，设 `item.menu`。
- 按钮到账号的映射靠 `button.identifier`（存 `config.id.uuidString`），因为 `NSStatusBarButton` 没有 `representedObject`。
- 同一个浮层只允许存在一个：弹出新的之前先关掉旧的。
- 浮层打开期间数据刷新完成 → 内容就地更新，不关闭浮层。
- `stop()` 时一并关掉浮层。

## 8. 刷新策略

`AppState` 新增单账号刷新：

```swift
func refresh(configID: UUID) async
```

只重取这一个账号并只写它的快照。与 `refreshAll()` 共用 `isRefreshing` 互斥 —— 整体刷新进行中时单账号刷新直接返回（面板表头已经在显示刷新中，不会让人困惑）。

浮层打开时：若 `snapshot?.updatedAt` 距今超过 **5 分钟**，自动调用上面这个方法；否则直接用现有数据。右上角始终有一个 ⟳ 文字按钮可手动触发。

## 9. 错误与边界

| 情况 | 表现 |
| --- | --- |
| 还没有快照（首次刷新未回） | 浮层显示「正在获取…」，并自动触发一次单账号刷新 |
| 刷新失败 | 保留上一次的数据，顶部一行红字写明错误，不清空已有内容 |
| 当月无任何数据 | 趋势图位置显示「本月暂无数据」，其余区块照常展示 |
| 缺少 cost 数据 | 花费显示 `—`，其余照常 |
| 模型名缺失或为空 | 归入「未知模型」一行 |
| 余额多币种 | 逐币种列出，不换算 |
| 详情区块为空（例如只有余额） | 空区块整个不渲染，不留空标题 |
| 钉住项被 unpin / 账号被删 / 被禁用 | 浮层随状态项一起收掉 |

## 10. 测试策略

| 测试 | 覆盖 |
| --- | --- |
| `DeepSeekUsageDetailTests` | 用合成 bundle 断言 headline / 今日 / 本月 / 每日序列 / tokens 构成 / 模型表；空 days；缺 cost；模型名为空；多币种花费；超过 6 个模型时的 footnote |
| `AppStateRefreshTests` | 单账号刷新只改那一个快照、别的快照不动；与 `refreshAll` 互斥；对禁用账号直接返回 |
| `DetailSeriesChartTests` | 柱高归一化的纯函数：最大值、全零、只有一个点、中间补 0 |
| `CompactAmountTests` | 提取出来的紧凑数字格式（K/M/B）与既有行为逐字一致 |
| 既有测试 | 全绿，尤其 `UsageMetricSelectionTests` 与面板渲染冒烟 |

视图层不做像素断言。这一次视图可以**完整地**手工渲染出来看：文字按钮规避了图标按钮的渲染限制，柱子是自己画的矩形，所以整块浮层能在无窗口环境里光栅化。

## 11. 顺带的清理

`UsageAmountFormatter` 里有一个私有的 `formatAmount`（K/M/B 缩写）。详情里要显示同类数字，把它提成 internal 的 `compactAmount(_:)` 供两处共用，实现逐字不动 —— 面板的显示必须不变，由既有测试兜底。

## 12. 已知取舍

- **只读、不可交互**：这是刻意的。详情浮层的定位是「抬眼扫一下」，任何筛选、日期范围、下钻都属于厂商控制台，不该在这里重做一遍。
- **当月至今**：官方页面可以选时间范围，这里固定当月。要跨月分析请回控制台。
- **模型表截断到 6 行**：浮层不是表格工具，超出部分只给一个计数。
- **趋势图补 0**：没有数据的日期补 0 而不是跳过，这样横轴等距、峰值位置可信。
