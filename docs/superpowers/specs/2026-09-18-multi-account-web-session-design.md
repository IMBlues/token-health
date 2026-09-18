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
3. **兜底路径取错账号**。主请求失败时走 `fetchUsageBundleFromActiveSession()` 一类的调用，
   用的是"当前活跃窗口"的会话，也就是"最后一个登录的账号"。
   于是账号 A 的卡片可能静默显示账号 B 的数字。

另有一处结构性成本：六个 controller（合计 2253 行）是逐字复制出来的，
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
- 不改主请求路径（URLSession + Keychain 凭据）的行为与凭据格式。
- 不做跨设备同步、不做账号自动发现。
- 不并行化 `refreshAll`（仍保持串行）。
- 不清理历史遗留的 `default()` 存储。

## 3. 术语

- **账号卡片**：菜单和设置里的一张 `ServiceConfig`。一个 config 等于一个账号。
- **profile**：一个 `WKWebsiteDataStore` 实例，承载某账号在站点上的 cookie 与 localStorage。
- **内核**：本次抽出的共享会话实现（`WebSessionController` 及其配套类型）。
- **描述符**：每个 Provider 提供的、只包含差异部分的小结构体。
- **脚本信封**：六个 Provider 的用量脚本都返回同一个 JSON 形状
  `{ "ok": Bool, "status": Int, "text": String, ... }`，其中 `text` 是站点响应体。

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

- 内核不认识任何具体 Provider，只处理字符串（存进 Keychain 的凭据串）与脚本信封。
- 描述符不认识窗口、窗口生命周期、cookie store、profile——它只产出脚本、解析脚本结果。
- Provider 实现只依赖注册表，拿到内核后调用两个方法。

## 5. 组件规格

### 5.1 `WebSessionCredential` 协议

`Sources/TokenHealth/WebSessionCredential.swift`

六个凭据结构体的字段并不一致，协议因此只覆盖**编解码**与两处展示信息，不强行统一字段：

```swift
protocol WebSessionCredential: Codable, Equatable, Sendable {
    static var storagePrefix: String { get }   // 例："deepseek-web-session:"
    static var empty: Self { get }
    var isEmpty: Bool { get }
    var debugSummary: String { get }
    /// 用于设置页展示与错误文案的账号标识；没有该信息的 Provider 返回 nil
    var accountLabel: String? { get }
}

extension WebSessionCredential {
    func encodedForStorage() -> String
    static func decode(from value: String) -> Self?
}
```

现状与对应改法（各结构体保留自己的字段，只删除重复的编解码实现）：

| 结构体 | 现有字段 | `accountLabel` 映射自 |
| --- | --- | --- |
| `DeepSeekWebSessionCredential` | accessToken, cookieHeader, accountName | `accountName` |
| `KimiWebSessionCredential` | accessToken, cookieHeader, trafficID, deviceID, sessionID, planName | `nil` |
| `ZhipuWebSessionCredential` | accessToken, cookieHeader, organizationID, projectID, planName | `nil` |
| `MiniMaxWebSessionCredential` | accessToken, cookieHeader, groupID, accountName | `accountName` |
| `VolcengineArkWebSessionCredential` | cookieHeader, csrfToken, accountName | `accountName` |
| `OpenCodeGoWebSessionCredential` | cookieHeader, accountName | `accountName` |

协议不要求 `accessToken` / `accountName`（Kimi、Zhipu 没有 accountName，Volcengine Ark 与
OpenCode Go 没有 accessToken）。`debugSummary` 与 `isEmpty` 的现有实现语义保持不变。
**存储格式与现有字符串完全兼容**（前缀与 JSON 键名不变），已存凭据无需迁移。

### 5.2 `WebSessionDescriptor` 协议与工厂

`Sources/TokenHealth/WebSessionDescriptor.swift`

```swift
struct WebSessionFetchContext {
    let year: Int
    let month: Int
}

@MainActor
protocol WebSessionDescriptor {
    /// 窗口标题、错误文案与日志前缀用的 Provider 名，例如 "DeepSeek"
    var providerTitle: String { get }

    /// 登录窗口加载的地址，同时定义无头 WebView 需要处于的 origin
    var loginURL: URL { get }

    /// 无头 WebView 认为"已经在正确站点上"时用于比对的 host，例如 "platform.deepseek.com"
    var originHost: String { get }

    /// cookie 是否属于本 Provider。各 Provider 现有判定不同，逐字搬运：
    /// Kimi `contains("kimi") || contains("moonshot")`、
    /// MiniMax `contains("minimaxi.com") || contains("minimax.io")`、
    /// OpenCode Go `== "opencode.ai" || hasSuffix(".opencode.ai")`、
    /// Volcengine Ark / DeepSeek / Zhipu 为各自的 `contains(...)`
    func shouldIncludeCookie(domain: String) -> Bool

    /// 在登录页执行，返回 JSON 字符串；内核不解析它
    var extractionScript: String { get }

    /// 由抽取结果、cookie、页面标题组装 Keychain 凭据串；无法组装时返回 nil
    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String?

    /// 在已认证的页面里执行，返回脚本信封
    func usageFetchScript(context: WebSessionFetchContext) -> String

    /// 从脚本信封里取出 Provider 解析器需要的字节。逐字搬运现有解包逻辑：
    /// DeepSeek / MiniMax / OpenCode Go 返回整个信封；Kimi / Zhipu / Volcengine Ark 返回 `text`
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data
}

extension WebSessionDescriptor {
    /// 默认判定：信封里 `ok == false` 且 `status` 为 401 / 403
    func isAuthenticationFailure(scriptResultJSON: String) -> Bool
}
```

`WebSessionDescriptorFactory.descriptor(for: ProviderKind) -> WebSessionDescriptor?`
用 `switch` 覆盖六个 Provider，与现有 `ProviderFactory` 风格一致；其余 kind 返回 `nil`。

描述符实现放在各自现有的 `*WebLoginController.swift` 文件里（文件内容替换为描述符，
文件名与路径不变，以缩小 diff 便于 review）。所有脚本字符串**从现有实现原样搬运**，不重写。

`WebSessionFetchContext` 不含 `day`：目前没有任何脚本按天查询；DeepSeek 的解析器需要
`yyyy-MM-dd` 形式的当天日期，它已有自己的 `DeepSeekUsagePeriod`，不经过内核。

### 5.3 `WebSessionController`

`Sources/TokenHealth/WebSessionController.swift`

```swift
@MainActor
final class WebSessionController: NSObject {
    let configID: UUID

    init(configID: UUID, descriptor: WebSessionDescriptor, dataStore: WKWebsiteDataStore)

    /// 打开登录窗口；同一 config 重复调用复用同一窗口与 profile
    func startLogin(completion: @escaping (Result<String, Error>) -> Void)

    /// 用该账号自己的 profile 取用量（无头，不依赖窗口是否打开）
    func fetchUsage(context: WebSessionFetchContext) async throws -> Data

    /// 删除账号时调用：关窗口、释放 WebView、移除 profile
    func teardown() async
}

enum WebSessionError: LocalizedError {
    case sessionExpired(providerTitle: String)
    case loadTimeout(providerTitle: String, seconds: Int)
    case invalidResponse(providerTitle: String)
    case requestFailed(providerTitle: String, message: String)
    case unsupportedProvider
}
```

`dataStore` 由调用方注入（默认 `WKWebsiteDataStore(forIdentifier: configID)`），
既是生产的唯一来源，也让单元测试能传 `.nonPersistent()` 而不碰磁盘。

持有资源：

- `dataStore`：登录窗口与无头 WebView 共用同一实例。
- `loginWindow: WebSessionLoginWindowController?`，仅在窗口打开期间存在。
- `headlessWebView: WKWebView?`，懒创建，创建后常驻；`configuration.websiteDataStore` 指向 `dataStore`。

无头取用量的流程（沿用 `KimiWebUsageBridge` 已验证过的做法）：

1. 若 `headlessWebView.url?.host` 等于 `descriptor.originHost`，直接进入下一步；
   否则 load `descriptor.loginURL` 并等待 `didFinish`/`didFail`，超时 20 秒抛 `loadTimeout`。
2. `evaluateJavaScript(descriptor.usageFetchScript(context:))`；JS 异常按
   `requestFailed` 抛出，保留原始错误文本。
3. 解析信封：`ok == false` 时，`descriptor.isAuthenticationFailure` 为真则抛
   `sessionExpired`，否则抛 `requestFailed`（消息沿用现有
   `"<Provider> Web fetch HTTP <status>: <text 前 160 字>"` 的格式）。
4. `ok == true` 时把信封原文交给 `descriptor.usageData(fromScriptResult:)`，返回其字节。

登录窗口内容不变：同样的窗口尺寸、"Login with <Provider>" 标题、
"Log in with … wait for Usage to load, then import." 状态文案与 "Import Session" 按钮，
只把 `WKWebViewConfiguration.websiteDataStore` 换成注入的 `dataStore`。
导入流程也不变：跑 `extractionScript` → 按 `shouldIncludeCookie` 过滤该 profile 的 cookie →
`encodeCredential` → 成功回调凭据串，失败沿用现有
"No session found. Make sure <Provider> is logged in." 提示并保持窗口打开。

### 5.4 `WebSessionRegistry`

`Sources/TokenHealth/WebSessionRegistry.swift`

```swift
@MainActor
final class WebSessionRegistry {
    static let shared: WebSessionRegistry

    init(
        makeDataStore: @escaping (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        removeProfile: @escaping (UUID) async -> Void = { await WebSessionRegistry.removePersistentProfile($0) }
    )

    /// 取该 config 的内核，不存在则创建；Provider 不支持 Web 登录时返回 nil
    func controller(for config: ServiceConfig) -> WebSessionController?

    /// 删除账号：淘汰内核并移除其 profile
    func evict(configID: UUID) async
}
```

- 内部 `[UUID: WebSessionController]`，键是 config id；创建时用
  `WebSessionDescriptorFactory.descriptor(for: config.providerKind)`，取不到则返回 `nil`。
- `evict` 顺序：`controller.teardown()` → 从字典移除 → `removeProfile(configID)`。
  **顺序是硬约束**：SDK 要求使用某个 store 的 `WKWebView` 全部释放之后才能移除该 store。
  `WKWebsiteDataStore.remove(forIdentifier:completionHandler:)` 是异步回调 API，
  失败只记 `debugLog`，不向调用方抛错（包在 `removePersistentProfile` 里）。
- `WKWebsiteDataStore(forIdentifier:)`、`remove(forIdentifier:completionHandler:)` 均为
  macOS 14.0+ API，与本 App 部署目标一致；不使用 `allDataStoreIdentifiers()`。

### 5.5 Provider 侧改动

- 兜底调用点共 6 处，分布在 5 个文件：
  `Providers.swift`（Zhipu 约 55 行、Kimi 约 665 与 668 行）、`DeepSeekUsageProvider.swift`（约 29 行），
  以及 MiniMax、Volcengine Ark、OpenCode Go 各自的 Provider。
  统一改为经注册表取该 config 的内核：
  `guard let data = try await WebSessionRegistry.shared.controller(for: config)?.fetchUsage(context:) else { throw … }`，
  即必须显式处理 `controller(for:)` 返回 `nil`（Provider 不支持登录）的情况。
- `SettingsView.startWebLogin` 里的 6 个 `case`（Kimi、Zhipu、DeepSeek、MiniMax、Volcengine Ark、
  OpenCode Go）全部替换为一次 `WebSessionRegistry.shared.controller(for: config)?.startLogin`。
- **`KimiWebUsageBridge` 的删除范围**（阶段二）：它的取用量职责由内核承担，但它同时是
  Kimi 的日志工具——`KimiWebUsageBridge.debugLog` 在 `Providers.swift` 的 Kimi 原生路径里被调用 9 次，
  `javascriptAuthSummary` 也被 Kimi 路径引用。做法：把这两个静态方法先移到内核里通用的
  `WebSessionLog`（`debugLog(_:providerTitle:)` / `javascriptAuthSummary(from:)`），
  同步更新那 9 处调用点，再删除 `KimiWebUsageBridge.swift`。

### 5.6 设置页与菜单

设置页（`SettingsView`，文案沿用现有英文 UI 风格）：

- 登录按钮改为 `WebSessionRegistry.shared.controller(for: config)?.startLogin`，
  凭据仍然写入当前选中的那个 config（沿用现在的 `selectedID` 语义）。
- 连接状态文案带账号标识：已连接且能取到账号时显示
  `"<Provider> web session connected: <account>"`，否则沿用现有的
  `"<Provider> web session not connected"` / `"<Provider> web session stored locally"`。
  账号标识的来源是描述符侧的解码：设置页拿到的密文串交给
  `WebSessionDescriptorFactory.descriptor(for:)?.decodeAccountLabel(fromCredential:)`
  （协议扩展方法，默认实现对每个凭据类型调用其 `decode(from:)` 后取 `accountLabel`）。
- 新增入口：Provider 列表里的"添加账号"可以直接以某个 Provider 为模板新建 config
  （`AppState.addConfig(providerKind:)`），免去"先加一个 Kimi 再把 Provider 改成 DeepSeek"。
  新建时若同名已存在，`displayName` 自动加序号（"DeepSeek 2"）。

菜单（`StatusMenuView`）：

- 卡片第一行是 `config.displayName`，副标题是 `"<Provider> · <planName>"`（现状不变）。
- **多账号可区分性的保障落在 `displayName`**：新建同 Provider 账号时自动加序号，
  用户也可以自己改名。副标题里的 `planName` 不承担区分职责——
  Kimi 的 `planName` 会回退成 "Allegretto"、Volcengine Ark 回退成 "Agent Plan"，
  这类默认值反而会掩盖差异。
- `planName` 为空时回退到 `config.displayName`（新增，避免空副标题）。
- 导入成功时，描述符尽量把站点账号标识写进凭据的 `accountName`
  （DeepSeek 取 `/api/v0/users/get_user_summary` 响应里的邮箱或手机号），
  取不到则回退到页面标题；该 XHR 失败**不得**让导入失败，只是拿不到标识。
  **验收只要求同 Provider 的两张卡片可区分**，不要求一定拿到邮箱。

## 6. 数据流

### 6.1 登录与导入

1. 用户在设置里选中账号卡片，点 "Login with <Provider>"。
2. 注册表返回该 config 的内核（已存在则复用），打开窗口加载 `descriptor.loginURL`，
   窗口里的 WebView 使用该 config 自己的 profile。
3. 用户在这个窗口里登录。因为 profile 独立，此操作不会影响其他账号的登录态；
   不同账号的登录窗口也可以同时打开。
4. 点 Import：跑 `extractionScript` → 按 `shouldIncludeCookie` 读该 profile 的 cookie →
   `encodeCredential` → 回调凭据串。
5. 设置页把凭据串写入该 config 的 Keychain（现有流程不变），随后触发 `refreshAll()`。
6. 关窗口不销毁内核，profile 保留在磁盘上。

### 6.2 正常刷新

不变：`AppState.refreshAll` 串行遍历 config，Provider 用 Keychain 里的凭据发 URLSession 请求。

### 6.3 兜底

1. Provider 主请求失败，经注册表取该 config 的内核并调用 `fetchUsage(context:)`。
2. 内核用**该 config 自己的**无头 WebView 与 profile 取用量。
3. 成功则返回 `descriptor.usageData(fromScriptResult:)` 的字节；
   站点判定未认证则抛 `sessionExpired`。

因为 profile 持久化，只要该账号在本机登录过且站点会话未过期，兜底无需窗口打开即可完成。

### 6.4 删除账号

`AppState.deleteConfig` 保持现有同步签名与返回值（`SettingsView.swift:72` 依赖它），
在删 Keychain 凭据、从 `configs` 移除、存盘之后，追加一个 fire-and-forget 的
`Task { await WebSessionRegistry.shared.evict(configID: configID) }`。
profile 清理属于后台收尾，不阻塞、也不影响删除操作的返回值。

## 7. 错误处理

`WebSessionError` 的每个 case 都带 `providerTitle`，文案沿用英文 UI：

| 场景 | 行为 |
| --- | --- |
| 站点会话过期（信封判定未认证） | 抛 `.sessionExpired`，卡片显示 `"<Provider> session expired. Log in again for this account."`，`state = .unavailable` |
| profile 从未登录过（升级后首次兜底） | 同 `.sessionExpired`（此时就是需要登录一次） |
| 无头 WebView 加载 origin 超时（20 秒）或 `didFail`/`didFailProvisionalNavigation` | 抛 `.loadTimeout` / `.requestFailed`，保留原始错误文本 |
| `evaluateJavaScript` 报错 | 抛 `.requestFailed`，`message` 为 JS 原始错误 |
| 信封 `ok == false` 且非未认证 | 抛 `.requestFailed`，消息格式沿用现有 `"<Provider> Web fetch HTTP <status>: <text 前 160 字>"` |
| 信封 JSON 解析失败 / `text` 缺失 | 抛 `.invalidResponse` |
| 抽取脚本执行失败 / 组装不出凭据 | 登录窗口保持打开，状态栏沿用现有 `"No session found. Make sure <Provider> is logged in."`，沿用现有 `onImportFailed` 语义 |
| 用户在同一窗口里登出并换别的账号再 Import | 该 config 的凭据被替换为新账号（这是"这张卡片换账号"的预期行为）；新账号标识会反映到设置页与菜单，不会静默 |
| 删除账号时 profile 移除失败 | 只记 `debugLog`，不影响 config 删除结果 |
| 同一 config 重复打开登录窗口 | 复用同一窗口与 profile |
| `controller(for:)` 返回 nil（Provider 不支持登录） | Provider 按 `.unsupportedProvider` 处理，卡片显示原有配置提示 |

## 8. 升级与迁移

- Keychain 凭据格式不变，主请求路径不受影响，老账号升级后照常刷新。
- 新建的 profile 是空的，因此**升级后第一次触发兜底**会失败并提示重新登录一次。
- 明确不做 cookie 迁移：从旧的 `default()` 存储复制 cookie 而不复制 localStorage 是半吊子状态，
  会造出"看起来登录了其实没有"的假象，比直接提示重新登录更糟。
- 旧的 `default()` 存储不再被任何代码使用，不主动删除（保留一个版本以便回滚）。

## 9. 落地顺序

**阶段一：DeepSeek 打通**

产出 `WebSessionCredential` 协议、`WebSessionDescriptor` 协议与工厂、内核、注册表、
`DeepSeekSessionDescriptor`；`DeepSeekUsageProvider` 与设置页接上；
用两个真实 DeepSeek 账号完成第 11 节的全部验收项。

**阶段二：其余五个 Provider + 收编 Kimi 桥**

补齐 Kimi、Zhipu、MiniMax、Volcengine Ark、OpenCode Go 的描述符，
删除各自的窗口实现与 `KimiWebUsageBridge`（含第 5.5 节的日志迁移），逐个人工验证登录与刷新。

## 10. 测试

**单元测试**（`Tests/TokenHealthTests/`，沿用现有 fixture 风格）

- `WebSessionCredential` 默认编解码：六个结构体各自的往返，以及"前缀不匹配返回 nil"、
  "JSON 损坏返回 nil"；存储兼容性：用现有格式的字符串解码，断言字段与前缀不变。
- `accountLabel`：六个结构体各自的取值（Kimi / Zhipu 断言为 `nil`）。
- 描述符的 `shouldIncludeCookie`：用真实域名 fixture（`kimi.com`、`moonshot.cn`、
  `minimaxi.com`、`minimax.io`、`opencode.ai`、`api.opencode.ai`、`evil-opencode.ai`）
  断言各 Provider 的过滤结果，重点覆盖 OpenCode Go 的精确/后缀匹配不误收 `evil-opencode.ai`。
- 描述符的 `encodeCredential`：固定抽取 JSON + cookie + 标题，断言产出的字符串能被对应凭据类型
  解码回来，且 `accountName` 取名优先级正确。
- 描述符的 `usageData(fromScriptResult:)`：用固定的信封 JSON，断言 DeepSeek 得到整段信封、
  Kimi / Zhipu 得到 `text` 体。
- `isAuthenticationFailure` 默认实现：401/403 → true，500 → false，`ok == true` → false。
- 注册表：同一 config 两次取到同一实例；不同 config 取到不同实例；不支持的 kind 返回 nil；
  `evict` 后再取是新实例；`evict` 调用注入的 `removeProfile`（用闭包替身断言被调用一次）。
  测试用注入的 `makeDataStore = { _ in .nonPersistent() }`，不触碰磁盘。

**人工验收（无法自动化，必须做）**：见第 11 节。

## 11. 验收标准

用两个真实 DeepSeek 账号：

1. 加账号 A → 登录 → Import → 菜单出现 A 的卡片。
2. 加账号 B → 登录 → Import → 菜单同时有 A 和 B，**且 A 的数字与第 1 步一致**
   （本次修复的核心验收点）。
3. 两张卡片标题可区分（第一行 `displayName` 不同）。
4. A 与 B 的登录窗口可同时打开，互不干扰（B 的窗口里看不到 A 的登录态）。
5. 重启 App，A 与 B 都还在，刷新都正常。
6. 触发一次兜底并确认取到的是该账号自己的数据、不是另一个账号的数字。
   触发方式：临时加一个调试分支让 DeepSeek 主请求直接抛错（`apiEndpoint` 对
   browserLogin 的 DeepSeek 会被 `saveConfigs` 清空、主机名也是硬编码的，改配置触发不了）。
7. 删除账号 A：菜单里 A 消失，磁盘上对应的 profile 目录同步消失。
8. 阶段二完成后，其余五个 Provider 各自重复第 1、2 步。

## 12. 风险与未决项

- **无头 WebView 在 App 未激活时的行为**：`KimiWebUsageBridge` 已证明"隐藏 WebView + 加载 origin + XHR"
  可行，但需要实测 DeepSeek 站点在窗口不可见时是否照常返回。
- **平台风控**：每个账号一份独立 profile，从站点视角更接近多个独立浏览器，不比现状更差；
  但如果出现验证码/人机校验页面，兜底只能报错并把用户引到登录窗口。
- **磁盘占用**：每个账号一份 profile，量级是几百 KB 到几 MB。
- **未决**：DeepSeek 账号标识的具体响应字段，需拿到真实 `get_user_summary` 响应后确定。
  取不到时的回退链已定义（账号字段 → 页面标题 → nil），且导入流程对该 XHR 失败容错，
  不影响第 11 节的验收。
