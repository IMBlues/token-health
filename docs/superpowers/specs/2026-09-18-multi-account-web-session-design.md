# 多账号登录会话（Web Session）设计

日期：2026-09-18
状态：已批准，待实现

## 1. 背景与根因

需要浏览器登录的 Provider（Kimi Code、Zhipu Coding、DeepSeek、MiniMax、Volcengine Ark、OpenCode Go）
目前每个 `ServiceConfig` 只能容纳一个账号，且**切换账号会把上一个账号弄失效**。

根因有三条，缺一不可：

1. **共享的 WebKit 存储**。六个 `*WebLoginController` 都是单例，都用
   `WKWebsiteDataStore.default()`，也就是整个 App 共用一份 cookie / localStorage。
   在同一个 WebView 里登录第二个账号，必须先把第一个账号登出；站点会因此作废第一个账号的会话。
2. **共享的登录窗口**。`startLogin` 复用同一个 `windowController`，第二个账号的登录窗口
   就是第一个账号那个窗口，天然带着上一个账号的登录态。
3. **兜底路径取错账号**。主请求失败时走 `fetchUsageBundleFromActiveSession()`，
   用的是"当前活跃窗口"的会话，也就是"最后一个登录的账号"。
   于是账号 A 的卡片可能静默显示账号 B 的数字。

另有一处结构性成本：六个 controller（合计约 2250 行）是逐字复制出来的，
同一份窗口 / 导入 / 抽取 / evaluate 逻辑存在六份。本次改动必须落到六个 Provider，
若不先消除重复，就要把同一处修改抄六遍。

## 2. 目标与非目标

**目标**

- 同一个 Provider 的多个账号可以同时存在，各自登录、各自刷新，互不影响。
- 修复兜底路径串号：任何账号的任何请求都只使用该账号自己的浏览器会话。
- 消除六个 controller 的重复实现，后续会话机制的改动只改一处。
- 账号切换不再破坏既有账号的登录态。

**非目标**

- 不引入"账号"实体，不改 `ServiceConfig` 的存储格式。
- 不改主请求路径（URLSession + Keychain 凭据）的行为。
- 不做跨设备同步、不做账号自动发现。
- 不并行化 `refreshAll`（仍保持串行）。

## 3. 术语

- **账号卡片**：菜单和设置里的一张 `ServiceConfig`。一个 config 等于一个账号。
- **profile**：一个 `WKWebsiteDataStore` 实例，承载某账号在站点上的 cookie 与 localStorage。
- **内核**：本次抽出的共享会话实现（`WebSessionController` 及其配套类型）。
- **描述符**：每个 Provider 提供的、只包含差异部分的小结构体。

## 4. 架构总览

```
SettingsView ──┐
               ├─→ WebSessionRegistry ──→ WebSessionController(configID)
UsageProvider ─┘            │                      │
                            │                      ├─→ 登录窗口 WKWebView ─┐
                            ↓                      └─→ 无头 WKWebView    ─┤
                   WebSessionDescriptorFactory                            │
                            │                                             ↓
                            ↓                              WKWebsiteDataStore(forIdentifier: configID)
             DeepSeekSessionDescriptor / Kimi… / …
```

边界约定：

- 内核不认识任何具体 Provider，只认识字符串（存进 Keychain 的凭据串）和 JSON（脚本返回值）。
- 描述符不认识窗口、窗口生命周期、cookie store、profile——它只产出脚本、解析脚本结果。
- Provider 实现只依赖注册表，拿到内核后调用两个方法。

## 5. 组件规格

### 5.1 `WebSessionCredential` 协议

`Sources/TokenHealth/WebSessionCredential.swift`

现有六个凭据结构体（`DeepSeekWebSessionCredential` 等）字段形状一致，把重复的编解码提成协议默认实现：

```swift
protocol WebSessionCredential: Codable, Equatable, Sendable {
    static var storagePrefix: String { get }   // 例："deepseek-web-session:"
    static var empty: Self { get }
    var accessToken: String? { get set }
    var cookieHeader: String? { get set }
    var accountName: String? { get set }
    var isEmpty: Bool { get }
    var debugSummary: String { get }
}

extension WebSessionCredential {
    func encodedForStorage() -> String
    static func decode(from value: String) -> Self?
}
```

六个结构体改为声明遵循该协议并删除各自重复的 `encodedForStorage` / `decode` / `debugSummary` 实现。
**存储格式与现有字符串完全兼容**（前缀与 JSON 键名不变），已存的凭据不需要迁移。
Provider 特有的字段（如 Kimi 的 `planName`）保留在各自结构体里，不进入协议。

### 5.2 `WebSessionDescriptor` 协议与工厂

`Sources/TokenHealth/WebSessionDescriptor.swift`

```swift
struct WebSessionFetchContext {
    let year: Int
    let month: Int
    let day: String     // "yyyy-MM-dd"，UTC
}

@MainActor
protocol WebSessionDescriptor {
    /// 窗口标题与错误文案用的 Provider 名，例如 "DeepSeek"
    var providerTitle: String { get }

    /// 登录窗口加载的地址
    var loginURL: URL { get }

    /// cookie 过滤用的域名子串，例如 "deepseek"
    var cookieDomainFilter: String { get }

    /// 在登录页执行，返回 JSON 字符串；内核不解析它
    var extractionScript: String { get }

    /// 由抽取结果、cookie、页面标题组装 Keychain 凭据串；无法组装时返回 nil
    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String?

    /// 在已认证的页面里执行，返回用量数据；period 供按月查询的 Provider 使用
    func usageFetchScript(context: WebSessionFetchContext) -> String

    /// 站点返回未认证时判定为 true，用于把"会话过期"与"网络/服务错误"区分开
    func isAuthenticationFailure(usageResponseJSON: String) -> Bool
}
```

`WebSessionDescriptorFactory.descriptor(for: ProviderKind) -> WebSessionDescriptor?`
用 `switch` 覆盖六个 Provider，与现有 `ProviderFactory` 的风格一致；其余 kind 返回 `nil`。

描述符实现放在各自现有的 `*WebLoginController.swift` 文件里（文件内容替换为描述符，
文件名与路径不变，以缩小 diff 便于 review）。每个 Provider 的抽取脚本、用量请求脚本
**从现有实现原样搬运**，不重写。

### 5.3 `WebSessionController`

`Sources/TokenHealth/WebSessionController.swift`

```swift
@MainActor
final class WebSessionController: NSObject {
    let configID: UUID

    init(configID: UUID, descriptor: WebSessionDescriptor)

    /// 打开登录窗口；同一 config 重复调用复用同一窗口与 profile
    func startLogin(completion: @escaping (Result<String, Error>) -> Void)

    /// 用该账号自己的 profile 取用量（无头，不依赖窗口是否打开）
    func fetchUsage(context: WebSessionFetchContext) async throws -> Data

    /// 删除账号时调用：关窗口、释放 WebView、移除 profile
    func teardown() async
}
```

持有资源：

- `dataStore: WKWebsiteDataStore`，由 `WKWebsiteDataStore(forIdentifier: configID)` 得到；
  同一 identifier 重复获取返回同一实例，登录窗口与无头 WebView 共用它。
- `loginWindow: WebSessionLoginWindowController?`，仅在窗口打开期间存在。
- `headlessWebView: WKWebView?`，懒创建，创建后常驻；`configuration.websiteDataStore` 指向同一个 `dataStore`。

无头取用量的流程（沿用 `KimiWebUsageBridge` 已验证过的做法）：

1. 若 `headlessWebView.url` 的 host 已属于目标域名，直接进入下一步；否则 load `loginURL` 并等待
   `didFinish`，超时 20 秒。
2. `evaluateJavaScript(descriptor.usageFetchScript(context:))`。
3. 解析返回的 JSON 字符串，取用量数据；若 `descriptor.isAuthenticationFailure` 为 true，
   抛 `WebSessionError.sessionExpired`；否则抛 `WebSessionError.requestFailed(message)`。

### 5.4 `WebSessionRegistry`

`Sources/TokenHealth/WebSessionRegistry.swift`

```swift
@MainActor
final class WebSessionRegistry {
    static let shared: WebSessionRegistry

    /// 取该 config 的内核，不存在则创建；Provider 不支持 Web 登录时返回 nil
    func controller(for config: ServiceConfig) -> WebSessionController?

    /// 删除账号：淘汰内核并移除其 profile
    func evict(configID: UUID) async
}
```

- 内部 `[UUID: WebSessionController]`；键是 config id。
- `evict` 顺序：`controller.teardown()` → 从字典移除 → `WKWebsiteDataStore.remove(forIdentifier:)`。
  移除 profile 是异步回调 API，失败只记 `debugLog`，不向调用方抛错。
- `WKWebsiteDataStore` 的两个类方法（枚举 identifier 与按 identifier 移除）是 macOS 14 API，
  与本 App 的部署目标一致；实现时以 SDK 头文件里的准确签名为准，编译通过即可确认。

### 5.5 Provider 侧改动

- `DeepSeekUsageProvider.fetchPlatformUsage`：兜底调用从
  `DeepSeekWebLoginController.shared.fetchUsageBundleFromActiveSession(month:year:)`
  改为 `WebSessionRegistry.shared.controller(for: config)?.fetchUsage(context:)`。
- 其余五个 Provider 的兜底调用点做同样的替换（Zhipu、Kimi、MiniMax、Volcengine Ark、OpenCode Go）。
- `KimiWebUsageBridge` 在阶段二删除：它的职责（隐藏 WebView + 加载 origin + 在页面里取用量）
  已由内核的无头路径承担。
- 三个 `.shared` 单例访问点（`SettingsView.startWebLogin`、各 Provider 的兜底）全部改为经过注册表。

### 5.6 设置页与菜单

设置页（`SettingsView`）：

- 登录按钮改为 `WebSessionRegistry.shared.controller(for: config)?.startLogin`，
  仍然写入当前选中的那个 config（沿用现在的 `selectedID` 语义）。
- 连接状态文案带上账号标识：已连接时显示"已连接：<账号>"，未连接显示"未连接"。
- 新增入口：Provider 列表里的"添加账号"可以直接以某个 Provider 为模板新建 config
  （`AppState.addConfig(providerKind:)`），免去"先加一个 Kimi 再把 Provider 改成 DeepSeek"。
  新建时若同名已存在，`displayName` 自动加序号（"DeepSeek 2"）。

菜单（`StatusMenuView`）：

- 卡片标题沿用 `<Provider> · <planName>`，其中 `planName` 来自快照；
- 快照 `planName` 为空时回退到 `config.displayName`，保证同 Provider 的多张卡片标题可区分。
- 账号标识的来源：描述符在导入时尽量取站点的账号字段（DeepSeek 的
  `/api/v0/users/get_user_summary` 响应里通常带邮箱或手机号），取不到则回退到页面标题，
  再取不到就留空由菜单回退到 config 名。**验收要求是两张卡片标题能区分**，
  不要求一定拿到邮箱。

## 6. 数据流

### 6.1 登录与导入

1. 用户在设置里选中账号卡片，点"Login with <Provider>"。
2. 注册表返回该 config 的内核（已存在则复用），打开窗口加载 `descriptor.loginURL`，
   窗口里的 WebView 使用该 config 自己的 profile。
3. 用户在这个窗口里登录。因为 profile 独立，此操作不会影响其他账号的登录态；
   不同账号的登录窗口也可以同时打开。
4. 点 Import：跑 `extractionScript` → 读该 profile 的 cookie store（按
   `cookieDomainFilter` 过滤）→ `encodeCredential` → 回调凭据串。
5. 设置页把凭据串写入该 config 的 Keychain（现有流程不变），随后触发 `refreshAll()`。
6. 关窗口不销毁内核，profile 保留在磁盘上。

### 6.2 正常刷新

不变：`AppState.refreshAll` 串行遍历 config，Provider 用 Keychain 里的凭据发 URLSession 请求。

### 6.3 兜底

1. Provider 主请求失败，调用 `registry.controller(for: config)?.fetchUsage(context:)`。
2. 内核用**该 config 自己的**无头 WebView 与 profile 取用量。
3. 成功则返回数据；站点判定未认证则抛 `sessionExpired`。

因为 profile 持久化，只要该账号在本机登录过且站点会话未过期，兜底无需窗口打开即可完成。

### 6.4 删除账号

`AppState.deleteConfig` 在现有流程（删 Keychain 凭据、从 `configs` 移除、存盘）之外，
追加 `await WebSessionRegistry.shared.evict(configID:)`。

## 7. 错误处理

| 场景 | 行为 |
| --- | --- |
| 站点会话过期（兜底时被判定未认证） | 抛 `sessionExpired`，卡片显示"会话已过期，请在设置里重新登录该账号"，`state = .unavailable` |
| profile 从未登录过（升级后首次兜底） | 同 `sessionExpired`（此时就是需要登录一次） |
| 无头 WebView 加载 origin 超时（20 秒） | 抛 `loadTimeout`，卡片显示原始错误信息 |
| 抽取脚本执行失败 / 组装不出凭据 | 登录窗口保持打开，状态栏提示"No session found. Make sure <Provider> is logged in."，沿用现有 `onImportFailed` 语义 |
| 用户在同一窗口里登出并换了别的账号再 Import | 该 config 的凭据被替换为新账号（这是"这张卡片换账号"的预期行为）；新账号标识会反映到菜单，不会静默 |
| 删除账号时 profile 移除失败 | 只记 `debugLog`，不影响 config 删除结果 |
| 同一 config 重复打开登录窗口 | 复用同一窗口与 profile |

## 8. 升级与迁移

- Keychain 里的凭据格式不变，主请求路径不受影响，老账号升级后照常刷新。
- 新建的 profile 是空的，因此**升级后第一次触发兜底**会失败并提示重新登录一次。
- 明确不做 cookie 迁移：从旧的 `default()` 存储复制 cookie 而不复制 localStorage 是半吊子状态，
  会造出"看起来登录了其实没有"的假象，比直接提示重新登录更糟。
- 旧的 `default()` 存储不再被任何代码使用，不主动删除（保留一个版本以便回滚）。

## 9. 落地顺序

**阶段一：DeepSeek 打通**

产出 `WebSessionCredential` 协议、内核、注册表、描述符工厂与 `DeepSeekSessionDescriptor`；
`DeepSeekUsageProvider` 与设置页接上；用两个真实 DeepSeek 账号完成第 11 节的全部验收项。

**阶段二：其余五个 Provider + 收编 Kimi 桥**

把 Kimi、Zhipu、MiniMax、Volcengine Ark、OpenCode Go 的描述符补齐，删除各自的窗口实现
与 `KimiWebUsageBridge`，逐个人工验证登录与刷新。

## 10. 测试

**单元测试**（`Tests/TokenHealthTests/`，沿用现有 fixture 风格）

- `WebSessionCredential` 默认编解码：六个结构体各自的往返，以及"前缀不匹配返回 nil"、
  "JSON 损坏返回 nil"。
- 描述符的 `encodeCredential`：给固定的抽取 JSON + cookie + 标题，断言产出的字符串能被
  对应的凭据类型解码回来，且 `accountName` 的取名优先级正确。
- 注册表生命周期：同一 config 两次取到同一实例；不同 config 取到不同实例；
  不支持的 kind 返回 nil；`evict` 后再取是新实例。
- profile 移除用一个可注入的 `removeProfile: (UUID) async -> Void` 闭包替身断言被调用，
  避免单元测试里真的触碰 WebKit。

**人工验收（无法自动化，必须做）**

见第 11 节。

## 11. 验收标准

用两个真实 DeepSeek 账号：

1. 加账号 A → 登录 → Import → 菜单出现 A 的卡片。
2. 加账号 B → 登录 → Import → 菜单同时有 A 和 B，**且 A 的数字与第 1 步一致**
   （本次修复的核心验收点）。
3. 两张卡片标题可区分。
4. A 与 B 的登录窗口可同时打开，互不干扰（B 的窗口里看不到 A 的登录态）。
5. 重启 App，A 与 B 都还在，刷新都正常。
6. 触发一次兜底（临时把端点改成不可用，或等 token 过期）：确认取到的是该账号自己的数据，
   而不是另一个账号的数字。
7. 删除账号 A：菜单里 A 消失，磁盘上对应的 profile 目录同步消失。
8. 阶段二完成后，五个 Provider 各自重复第 1、2 步。

## 12. 风险与未决项

- **无头 WebView 在 App 未激活时的行为**：`KimiWebUsageBridge` 已证明"隐藏 WebView + 加载 origin + XHR"
  可行，但需要实测 DeepSeek 站点在窗口不可见时是否照常返回。
- **平台风控**：每个账号一份独立 profile，从站点视角更接近多个独立浏览器，不比现状更差；
  但如果出现验证码/人机校验页面，兜底只能报错并把用户引到登录窗口。
- **磁盘占用**：每个账号一份 profile，量级是几百 KB 到几 MB。
- **未决**：DeepSeek 账号标识的具体响应字段，需拿到真实 `get_user_summary` 响应后确定；
  取不到时的回退链已在上文定义，不影响验收（验收只要求卡片可区分）。
