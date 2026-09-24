# 钉住 Provider 的独立菜单栏项 设计

日期：2026-09-24
状态：已批准，待实现

## 1. 背景与目标

现在整个 App 只有**一个**菜单栏图标（`MenuBarExtra` + `bolt.circle`），点开是一块管理面板。
想看某个账号的额度，必须点开面板再扫一遍卡片。

本次新增一条正交的展示通道：**把某一个账号钉到菜单栏**，用一个独立的菜单栏项常驻显示它的额度，
图标本身就能读懂，不需要点开。

**目标**

- 菜单栏多一个独立的状态项，内容为「官方 logo + 若干根细竖条」，不显示项目名、不显示数值。
- 竖条的数量与顺序由 Provider 提供的额度窗口决定，一个窗口一根条，独立着色。
- DeepSeek 没有额度比例，该位置显示换算后的金额（不带单位）。
- DeepSeek 账号可选显示币种，汇率联网自动获取，换算只作用于这一个菜单栏项。
- 全局图标与全局面板的行为完全不变。

**非目标**

- 不做多个 pin（同一时间只钉一个账号）。
- 不做悬停展开、点击展开详细内容 —— 只留好入口，后续单独做。
- 不改全局图标、不改菜单面板里卡片的信息层级与布局。
- 不做竖条颜色、宽度、位置的自定义。
- 不改任何 Provider 的主请求路径与凭据格式。

## 2. 术语

- **pin**：被钉住的账号，记录形式是该 `ServiceConfig` 的 id。
- **指标（metric）**：菜单栏项上要画的一个额度窗口，对应一根竖条（或 DeepSeek 的一个金额）。
- **额度窗口**：`UsageWindow` 中带 `limit` 的滚动额度，即 `fiveHours / week / month / mcpMonth / videoGift`。
- **状态项**：AppKit 的 `NSStatusItem`，即菜单栏上的一块区域。

## 3. 架构总览

```
AppState.refreshAll() ──→ snapshots[configID]
        │                          │
        │ pinnedConfigID           │
        ↓                          ↓
PinnedStatusItemController ──→ MenuBarMetrics ──→ [MenuBarMetric]
        │                          ↑                    │
        │                  ExchangeRateStore ──────────┘ (仅 DeepSeek）
        ↓
MenuBarItemLayout → MenuBarItemRenderer → NSImage → statusItem.button
```

新增单元一览：

| 单元 | 职责 | 依赖 |
| --- | --- | --- |
| `ProviderIcon` | ProviderKind → 内嵌矢量 logo / SF Symbol 兜底 | Bundle.module |
| `UsageMetricSelection` | 额度窗口的判定、排序（卡片与菜单栏项共用） | Models |
| `MenuBarMetrics` | 快照 → 有序指标列表（含 DS 金额换算） | UsageMetricSelection、ExchangeRateTable |
| `ExchangeRateTable` | 纯值类型：汇率表 + 换算数学 | 无 |
| `ExchangeRateStore` | 拉取、缓存、失败回退、发布当前汇率 | ExchangeRateTable、ConfigStore |
| `MenuBarItemLayout` | 纯计算：图标与各竖条的位置与高度 | 无 |
| `MenuBarItemRenderer` | 依布局把 NSImage 画出来 | MenuBarItemLayout、ProviderIcon |
| `PinnedStatusItemController` | 拥有 NSStatusItem，订阅状态、驱动重绘、弹菜单 | 以上全部、AppState |

拆分原则：**凡是能纯计算的一律不碰 AppKit**（`MenuBarMetrics`、`ExchangeRateTable`、`MenuBarItemLayout`），
这样大部分行为可以在没有窗口服务器的测试进程里直接验证。

## 4. 各单元设计

### 4.1 ProviderIcon

```swift
enum ProviderIcon {
    /// 内嵌资源名；nil 表示该 Provider 没有品牌 logo，用 SF Symbol。
    static func assetName(for kind: ProviderKind) -> String?
    /// 兜底图标，同时是设置界面现在用的那一套。
    static func symbolName(for kind: ProviderKind) -> String
    /// 按尺寸与颜色取出可直接绘制的位图。资源缺失时自动退化成 symbolName。
    static func image(for kind: ProviderKind, size: CGFloat, tint: NSColor) -> NSImage
}
```

设置侧边栏现在有一份私有的 `SettingsView.iconName(for:)`，本次把它移进这里，
让「哪个 Provider 长什么样」只有一个出处，设置列表与菜单栏项拿到同一张图。

资源文件为**矢量 PDF**，理由是 `NSImage` 解码 SVG 只在较新的 macOS 上可用（本机 macOS 26 可以，
但部署目标是 macOS 14），PDF 则在任何版本上都按矢量渲染、任意尺寸都清晰。

命名映射：

| ProviderKind | 资源 | 来源 |
| --- | --- | --- |
| openAI | `openai.pdf` | lobehub `openai` |
| anthropic | `anthropic.pdf` | lobehub `anthropic` |
| cursor | `cursor.pdf` | lobehub `cursor` |
| codex | `codex.pdf` | lobehub `codex` |
| kimiCode | `kimi.pdf` | lobehub `kimi` |
| zhipuCode | `zhipu.pdf` | lobehub `zhipu` |
| deepSeek | `deepseek.pdf` | lobehub `deepseek` |
| miniMax | `minimax.pdf` | lobehub `minimax` |
| volcengineArk | `volcengine.pdf` | lobehub `volcengine` |
| openCodeGo | `opencode.pdf` | lobehub `opencode` |
| genericHTTP | 无 | SF Symbol `network` |
| demo | 无 | SF Symbol `chart.bar` |

`ProviderIcon.image(for:size:tint:)` 把单色 logo 按 `tint` 上色：在离屏 context 里以
`.sourceIn` 合成，得到一张该颜色的位图。菜单栏项与设置列表都走这条路径。

### 4.2 UsageMetricSelection

把 `UsageCard` 里私有的判定与排序提取出来，卡片与菜单栏项共用；**卡片的结果必须与今天逐字节一致**。

```swift
enum UsageMetricSelection {
    /// Codex 的模型额度桶 label 形如 "gpt-5 · 5h"，不算账号级指标。
    static func isAccountLevel(_ usage: TokenUsage) -> Bool
    /// 滚动额度窗口（不含 balance / today* / 7d*）。
    static func isRollingQuota(_ usage: TokenUsage) -> Bool
    static func rank(_ usage: TokenUsage, kind: ProviderKind) -> Int
    /// 卡片与菜单栏项共用的稳定排序。
    static func sorted(_ usages: [TokenUsage], kind: ProviderKind) -> [TokenUsage]

    /// 本次新增：钉住项要画的全部额度指标，按 rank 升序。
    static func pinnedMetrics(from usages: [TokenUsage], kind: ProviderKind) -> [TokenUsage]
}
```

`pinnedMetrics` 的规则：

1. 取 `isRollingQuota` 的项；Codex 额外要求 `isAccountLevel`。
2. Cursor 的 `.month` 三个池（Auto + Composer / API / Grokbot）天然满足 1。
3. 按 `rank` 升序（5h → 周 → 月 → MCP 月 → 视频赠送）。
4. 全部落空时返回空数组 —— 由调用方决定退化成什么（DeepSeek 走金额分支，其余走空槽分支）。

预期结果：Kimi 2 根、Zhipu 3 根、Ark 3 根、OpenCode Go 3 根、Cursor 3 根、Codex 2 根。

`UsageCard.usageSort` / `usageRank` / `isAccountLevel` 的调用点改为走这里，`compactUsages` 的行为不变。

### 4.3 MenuBarMetrics

```swift
struct MenuBarMetric: Equatable {
    enum Shape: Equatable {
        case ratio(Double)      // 0...1，已 clamp
        case amount(String)     // 已格式化、不带单位
    }
    var label: String           // tooltip 用："5h" / "Week" / "Month" / "MCP" / "Video"
    var shape: Shape
    var severity: Double?       // 用于选色，nil = 中性
}

enum MenuBarMetrics {
    static func metrics(
        for snapshot: ProviderUsageSnapshot,
        kind: ProviderKind,
        displayCurrency: String?,
        rateTable: ExchangeRateTable
    ) -> [MenuBarMetric]
}
```

- 常规 Provider：`pinnedMetrics` 的每一项 → `.ratio(usage.ratio ?? 0)`，`severity` 取 ratio。
- DeepSeek：取 `window == .balance` 的全部项（可能有多币种），**换算到 `displayCurrency` 后求和**，
  格式化为两位小数，不附加单位。`displayCurrency` 为 nil 时不做换算，若存在多个币种余额，
  取 rank 最高的那一个的原值（与卡片折叠态今日行为一致），不求和。
- 换算后结果无法得出（汇率缺失、币种未知）时，回退显示原币种金额，并在 `label` 上标注
  「rate unavailable」，由 tooltip 呈现。
- `snapshot.state != .ready` 或指标为空：返回空数组，调用方画空槽。

### 4.4 ExchangeRateTable（纯值类型）

```swift
struct ExchangeRateTable: Codable, Equatable {
    var base: String                 // 固定 "USD"
    var rates: [String: Double]      // 相对 base，例如 ["CNY": 6.7074]
    var fetchedAt: Date
    var origin: Origin               // .live / .cache / .fallback
    static let fallback: ExchangeRateTable   // ["CNY": 7.2]，origin = .fallback

    func convert(_ amount: Decimal, from: String, to: String) -> Decimal?
    func rate(from: String, to: String) -> Double?
}
```

换算规则：同币种恒等返回；否则经 base 中转 `rate(X→Y) = rates[Y] / rates[X]`；
任一汇率缺失或非有限正数时返回 nil。金额进出用 `Decimal`，只在算比率时转 `Double`。

### 4.5 ExchangeRateStore

```swift
@MainActor
final class ExchangeRateStore: ObservableObject {
    static let ttl: TimeInterval = 12 * 60 * 60
    @Published private(set) var table: ExchangeRateTable

    init(configStore: ConfigStore, session: URLSession = .shared)

    /// 缓存超过 TTL 才发请求。启动与每次刷新后各调用一次。
    func refreshIfStale() async
    /// 设置里的手动刷新按钮。
    func refreshNow() async
}
```

- 接口：`https://api.frankfurter.app/latest?from=USD&to=CNY`（ECB 数据，无需 key，实测返回
  `{"amount":1.0,"base":"USD","date":"2026-09-23","rates":{"CNY":6.7074}}`）。
- 成功 → `origin = .live`，写缓存。失败 → 沿用已有缓存（`origin = .cache`）；无缓存 → `.fallback`。
- 缓存键 `exchange-rate.config.v1`，读写落在 `ConfigStore`，与其他配置项一致。
- 失败不写 `AppState.lastError`（这是展示层的降级，不该污染全局错误条），只在设置里那一行体现。

### 4.6 MenuBarItemLayout / MenuBarItemRenderer

```swift
struct MenuBarItemLayout: Equatable {
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1.5
    static let maxBarHeight: CGFloat = 13
    static let iconSize: CGFloat = 12
    static let iconGap: CGFloat = 4
    static let verticalPadding: CGFloat = 1
    static let minimumVisibleHeight: CGFloat = 1.5

    var size: CGSize
    var iconRect: CGRect?          // 无 logo 时为 nil
    var barRects: [CGRect]         // 每条对应的填充矩形，从底部起算
    var trackRects: [CGRect]       // 每条对应的空槽，满高

    static func make(metrics: [MenuBarMetric], hasIcon: Bool) -> MenuBarItemLayout
}
```

- 总宽 = 图标（可选）+ 间隙 + 条数 × 条宽 + (条数 − 1) × 条间距。
- 高度 = 2 × verticalPadding + maxBarHeight。
- 空槽为满高；填充高度 = `max(minimumVisibleHeight, ratio × maxBarHeight)`，保证 2% 也看得见。
- 没有图标时左边距不留空。

`MenuBarItemRenderer` 把布局画进 `NSImage`：

- 整张图**非 template**（`isTemplate = false`）—— 单色模板图会把彩色竖条一并染成单色。
- logo 用调用方传入的 `iconColor`（见 4.7）绘制；竖条按 `severity` 上色，
  阈值与卡片一致：`>= 0.9` 红、`>= 0.7` 橙、其余绿。
- 空槽用 `iconColor` 的 18% 透明度。
- `size` 与像素尺寸按当前屏幕 `backingScaleFactor` 生成位图，保证 Retina 下不虚。

### 4.7 PinnedStatusItemController

```swift
@MainActor
final class PinnedStatusItemController: NSObject {
    init(appState: AppState, rateStore: ExchangeRateStore)
    func start()   // 建 status item、订阅 appState.objectWillChange 与外观变化
    func stop()
}
```

- 用 AppKit 的 `NSStatusItem`，**不用第二个 `MenuBarExtra`**：SwiftUI 的场景系统无法按状态增删菜单栏项，
  且 `MenuBarExtra` 的 label 只支持简单视图，画不了自定义的图形。
- `length` 用 `NSStatusItem.variableLength`，按布局宽度自适应。
- 重绘时机：`appState.objectWillChange`（去抖 50ms）、系统外观变化、屏幕 `backingScaleFactor` 变化。
- 图标颜色在绘制时从**当前有效外观**解析（`NSApp.effectiveAppearance.bestMatch(from:)`），
  深色菜单栏取白、浅色取黑，并在外观变化时重绘 —— 这是「单色模板」想要的效果，
  只是必须由我们自己承担自动反色。
- 无 pin、pin 指向的账号不存在或被禁用时：移除 status item（保留 pin 记录，重新启用即恢复）。
- 点击：弹 `NSMenu`，含 `Unpin <名字>`（清 pin）、`Settings…`（`openSettings` 等价路径）、`Quit`。
- tooltip：`Kimi · 5h 62% · Week 34% · MCP 8%`；未就绪时放 `statusMessage`。

### 4.8 DeepSeek 币种设置与模型改动

- `ServiceConfig` 新增 `var displayCurrency: String?`（默认 nil）。解码用 `decodeIfPresent`，
  旧数据默认 nil，编码时 nil 也要写出去以保证 round-trip 稳定。
- `TokenUsage` 新增 `var amount: Decimal? = nil`，承载金额型窗口的**数值**（`unit` 已经是币种代码）。
  `DeepSeekUsageParser` 在产出 `balance` / `todayCost` 时一并填上 `amount`，
  `displayValue` 的现有格式不变，卡片渲染不受影响。
- 金额→显示文本的格式化收在 `MenuBarMetrics` 内部（两位小数、`en_US_POSIX`、千位分隔），
  与解析层的 `moneyText` 分开，避免展示策略渗进解析层。

### 4.9 设置界面

provider 详情表单新增一个 `Menu Bar` 分区：

- `Pin to menu bar` 开关 —— 打开即钉住并顶掉原来的 pin。
- 仅当 `providerKind == .deepSeek` 时追加：
  - `Display currency` 选择器：`Original` / `CNY` / `USD`（`Original` = nil）。
  - 一行汇率状态：`USD → CNY 6.7074 · live · updated 3h ago`；`.fallback` 时写明用的是内置默认值。
  - `Refresh rate` 按钮，触发 `rateStore.refreshNow()`。

### 4.10 AppState 与配置存储

- `@Published var pinnedConfigID: UUID?`，初始化时从 `ConfigStore.loadPinnedConfigID()` 读入。
- `setPinnedConfigID(_:)`：写内存 + 落盘。
- `deleteConfig(id:)` 成功且 id 等于当前 pin 时，清空 pin。
- `refreshAll()` 结束后调用 `rateStore.refreshIfStale()`。
- `ConfigStore` 新增 `loadPinnedConfigID()` / `savePinnedConfigID(_:)` 与
  `loadExchangeRate()` / `saveExchangeRate(_:)`，键分别为 `pinned-provider.config.v1`、`exchange-rate.config.v1`。
- 键名用意：与 `service.configs.v2` 一样带版本后缀，将来换形状时可再加 `v2` 而不破坏旧版读取。

### 4.11 图标资源脚本

`scripts/fetch-provider-icons.sh`：

- 固定版本 `@lobehub/icons-static-svg@1.95.1`（不用 `@latest`，保证可重跑、可复现）。
- 逐个下载到临时目录，用本机 `rsvg-convert -f pdf` 转成 PDF，写入
  `Sources/TokenHealth/Resources/ProviderIcons/`。
- 每个文件校验非空且以 `%PDF` 开头，任一失败即以非零码退出并打印是哪一个。
- 已存在且非空的文件默认跳过，`--force` 才重下。
- 幂等：重复执行结果一致，产物进版本库。

`Package.swift` 的可执行 target 加 `resources: [.process("Resources")]`。

## 5. 数据流

1. `AppState.init` → `rateStore.refreshIfStale()`（冷启动若缓存过期就补一次）。
2. `AppState.refreshAll()` 串行刷新各账号 → 写 `snapshots`。
3. 刷新结束 → `rateStore.refreshIfStale()`。
4. `appState.objectWillChange` → 控制器去抖后重算：
   找到 `pinnedConfigID` 对应的 `ServiceConfig` → 读它的 `snapshot` →
   `MenuBarMetrics.metrics(for:kind:displayCurrency:rateTable:)` →
   `MenuBarItemLayout.make` → `MenuBarItemRenderer` → `statusItem.button.image` 与 tooltip。
5. 用户在设置里改币种或开关 pin → `AppState` 发布变化 → 回到第 4 步。

## 6. 错误处理

| 情况 | 表现 |
| --- | --- |
| 尚无快照（首次刷新未回） | logo + 一根空槽；tooltip「Waiting for refresh」 |
| `snapshot.state == .unavailable` | logo + 一根空槽；tooltip 放 `statusMessage` |
| `snapshot.state == .needsConfiguration` | 同上，tooltip 提示去登录/填 key |
| 指标为空但状态 ready | logo + 一根空槽；tooltip 放 `statusMessage` |
| 汇率拉取失败且有缓存 | 用缓存，`origin = .cache`，设置里标注 |
| 汇率拉取失败且无缓存 | 用内置 7.2，`origin = .fallback`，设置里明确标注 |
| 换算所需币种不在表里 | 该指标退回原币种金额，tooltip 标注「rate unavailable」 |
| pin 指向的账号被禁用 | 移除 status item，保留 pin |
| pin 指向的账号被删除 | 清空 pin，移除 status item |
| 资源 PDF 缺失 | `ProviderIcon` 退化成 SF Symbol，不崩 |

## 7. 测试策略

全部新增测试用 swift-testing，与现有测试风格一致。**本机没有 Xcode**，跑测试必须带上
CommandLineTools 的 Testing.framework 路径：

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```

| 测试 | 覆盖 |
| --- | --- |
| `MenuBarMetricsTests` | 逐 Provider 的指标数量与顺序；Codex 排除模型桶；Cursor 三个池；DS 单币种/多币种求和/未设目标币种；换算缺币种的回退 |
| `UsageMetricSelectionTests` | `rank` 的排序稳定性；`isAccountLevel` 对 " · " 的判定；`compactUsages` 行为未变（用既有卡片选择结果做回归断言） |
| `ExchangeRateTests` | `convert` 恒等 / 经 base 中转 / 缺币种返回 nil；0 与负汇率被拒；`fallback` 表内容；TTL 判定；HTTP 失败沿用缓存；无缓存退默认值 |
| `PinnedProviderConfigTests` | pin 的读写 round-trip；`deleteConfig` 后 pin 清空；`displayCurrency` 的编解码兼容（旧 JSON 无该字段可解） |
| `MenuBarItemLayoutTests` | 各指标数下的宽度与条位；空数组；`minimumVisibleHeight` 下限；有无图标两种布局 |
| `ProviderIconTests` | 每个 ProviderKind 都有 `assetName` 或 `symbolName`；声明的资源都能在 bundle 里加载到 |
| 既有测试 | 全部保持通过（尤其 `StatusMenuSummaryTests` 与 `RefreshIntervalTests`） |

渲染层（`MenuBarItemRenderer`、`PinnedStatusItemController`）不做像素级断言 —— 把可验证的部分
全部推到 `MenuBarItemLayout` 与 `MenuBarMetrics` 这两个纯计算单元里，渲染只保留「按布局画」这一步。

## 8. 验收

1. `bash scripts/fetch-provider-icons.sh` 产出 10 个 PDF，重复执行结果一致。
2. `bash scripts/build-app.sh` 通过。
3. 上述 `swift test` 命令全绿。
4. 手动：钉住 Kimi → 菜单栏出现月亮 logo + 2 根条，颜色随用量变化；钉住 Zhipu → 3 根条。
5. 手动：钉住 DeepSeek → 显示换算后的金额；切到 USD 后数字变化；断开网络重启 → 仍显示数字，
   设置里标注为内置默认值。
6. 手动：删除被钉的账号 → 菜单栏项消失；禁用 → 消失，重新启用 → 回来。
7. 手动：全局 `bolt.circle` 图标与面板行为与改动前无差别。

## 9. 已知取舍

- **同屏两个图标**是本次的明确选择：全局项继续承担管理入口，钉住项只承担展示，
  后续要在钉住项上做详细内容时不会挤到管理入口。
- **整图非 template** 是彩色竖条的直接代价：单色模板与分色两者不可兼得。取分色，
  由我们自己按外观解析 logo 颜色并重绘。
- **汇率表只存 USD 基**：当前只需要 USD↔CNY，用 base 中转足以覆盖任意两币种，
  不必为更多币种改结构。
- **换算只作用于菜单栏项**：卡片与设置继续显示原币种原值，信息不丢失。
