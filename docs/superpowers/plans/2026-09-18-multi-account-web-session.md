# DeepSeek 多账号会话隔离 实现计划（阶段一）

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 DeepSeek 这类网页登录 Provider 的每个账号拥有独立的持久化 WebKit profile，使多个账号可以同时登录、互不顶掉会话，并修掉兜底路径串号的问题。

**Architecture:** 把六个重复的 `*WebLoginController` 里属于"会话内核"的部分（窗口、导入、cookie 抽取、脚本执行、无头取用量）抽成一个共享的 `WebSessionController`；每个 Provider 只提供一个描述符（`WebSessionDescriptor`），装差异部分（登录页、cookie 过滤、两个脚本、信封解包）。内核按 config id 持有 `WKWebsiteDataStore(forIdentifier:)`，登录窗口与无头 WebView 共用它。阶段一只接 DeepSeek，其余五个 Provider 保持原样，最后删除 DeepSeek 的旧 controller。

**Tech Stack:** Swift 6 / swift-tools 6.0、SwiftUI（macOS 14+）、WebKit（`WKWebsiteDataStore(forIdentifier:)`，macOS 14.0+）、swift-testing（`import Testing` + `@Suite` / `@Test` / `#expect`）、无第三方依赖。

**Spec:** `docs/superpowers/specs/2026-09-18-multi-account-web-session-design.md`

## 开始前的两件事

1. **分支**：当前在 `main`。先 `git switch -c feature/multi-account-web-session`。
2. **工作区已有两处未提交改动**（`AppSupport/Info.plist` 版本号 0.8.2、`Sources/TokenHealth/StatusMenuView.swift` 去掉 `onAppear` 刷新）。它们不属于本功能：**本计划所有 `git add` 都用显式文件路径**，不要用 `git add -A` / `git add .`，避免把它们卷进功能提交。

## 代码约定

- **注释一律用英文**。仓库 40 个 Swift 文件里只有 1 行中文注释（既有代码），其余全是英文；计划里下面的代码块若出现中文注释，落盘时翻成英文。这是唯一允许偏离"逐字粘贴"的地方——**行为代码本身必须逐字一致**。
- **协议扩展方法是静态派发**。`WebSessionCredential` 的编解码、`WebSessionDescriptor.isAuthenticationFailure` 都只作为协议扩展存在；通过 `any` 存在类型调用会拿到默认实现而不是具体类型的实现，且不报错。调用一律走具体类型。这个坑本项目已经踩过一次（见偏差 6）。
- **提交尾注固定为** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`，与分支上的既有提交一致。

## 跑测试与基线（重要）

本机只装了 CommandLineTools、没有 Xcode，`swift test` 会以 `no such module 'Testing'` 失败——
**这是既有环境问题，不是本次改动造成的**。swift-testing 的模块在
`/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework`，
SwiftPM 默认不搜这个路径，必须显式传进去。本计划里所有测试命令都是这个两行形式：

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```

要过滤用例时把 `--filter <SuiteName>` 放在 `swift test` 后面。`swift build` 不受影响，正常可用。

**基线失败（改动前就存在）**：全量跑是 `52 tests in 5 suites` 带 8 个 issue，分布在
`CursorUsageProviderTests` 的两个用例上：`mapsMonthlyAutoAndAPIPools`（7 个）与
`acceptsFlexiblePercentagesAndFormatsPlanName`（1 个，`:85`）。同一个根因——commit `a7ce4ee` 改了
Cursor 解析器，让 Grokbot 显示在 Auto 桶里，但没同步更新这两个更早的用例；行为是有意的
（README 明确写了 Grokbot 合并进 Auto 时的显示方式），是测试过时而非解析器 bug。
修复已单独提交在分支 `dev_bluesyu/strange-jemison-f47458`（commit `db262d0`），**不在 main 上**。

因此：**本计划里说的"测试全绿"一律指"除这两个基线失败外全绿"**。每次跑全量后确认失败集合与
基线相同即可，不要为了让数字变绿去改 Cursor 的测试。如果开工前先把 `db262d0` 合进 main，
基线就变成全绿，按更严的标准验收即可。

（另注：`Task { @MainActor in … }` 闭包里隐式 `self` 是允许的；只有普通 escaping 闭包
——例如 `evaluateJavaScript` 的 completion——才必须写 `self.`。）

## 与 spec 的六处在意偏差（有意为之）

1. **spec §5.2 说"描述符放在现有 `*WebLoginController.swift` 里、文件名不变"**。本计划改为：新建 `DeepSeekWebSessionDescriptor.swift`，旧文件 `DeepSeekWebLoginController.swift` 保留到 Task 8 再删。原因是这样每个 commit 都能编译通过；旧文件内容整体被替换，改名不省 diff。
2. **spec §5.4 的 `evict(configID:)` 改为 `evict(config:)`**。真正的理由是：注册表需要 `config.providerKind` 才能判断这个配置"是否可能有 profile"，从而决定要不要走清理；只拿到一个 UUID 就无法在"App 重启后、没打开过登录窗口就删除账号"这种情况下清掉磁盘上的 profile（此时注册表里根本没有 controller）。
3. **spec §5.6 说"`planName` 为空时副标题回退到 `config.displayName`"**。实际菜单卡片第一行已经是 `config.displayName`（`StatusMenuView.swift:129`），再加这个回退会变成 `DeepSeek 2` / `DeepSeek · DeepSeek 2` 的重复。多账号可区分性由 `displayName` 承担即可，副标题保持现状（`StatusMenuView.swift:258-264` 不动）。
4. **spec §5.1 协议里的 `static var empty: Self` 去掉**。阶段一的代码路径里没有任何地方用它（旧代码的 `?? DeepSeekWebSessionCredential()` 用法已由描述符显式构造取代），属于 YAGNI。
5. **`WebSessionError` 多一个 `case cancelled(providerTitle: String)`**（spec §5.3 没列）。它承接旧 `DeepSeekWebLoginController.LoginError.cancelled`，保住 "DeepSeek login cancelled" 这条文案。
6. **`accountLabel(fromCredential:)` 提升为协议要求（带 nil 默认实现），而不是 spec §5.6 说的扩展方法**。必须这样：扩展方法走静态派发，通过 `any WebSessionDescriptor` 调用会拿到默认实现而不是 DeepSeek 的实现，设置页就永远显示不出账号名。

## 文件结构

**新建**

| 文件 | 职责 |
| --- | --- |
| `Sources/TokenHealth/WebSessionCredential.swift` | 凭据编解码协议 + 默认实现 |
| `Sources/TokenHealth/WebSessionError.swift` | 内核、描述符、注册表共用的错误类型 |
| `Sources/TokenHealth/WebSessionDescriptor.swift` | 描述符协议、`WebSessionFetchContext`、`WebSessionScriptEnvelope`、描述符工厂 |
| `Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift` | DeepSeek 的登录页、cookie 过滤、抽取脚本、用量脚本、信封解包、账号标识扫描 |
| `Sources/TokenHealth/WebSessionLog.swift` | 环境变量门控的调试日志 + 通用 `javascriptAuthSummary` |
| `Sources/TokenHealth/WebSessionController.swift` | 内核：登录窗口、导入、无头取用量、teardown |
| `Sources/TokenHealth/WebSessionRegistry.swift` | 按 config id 缓存内核；淘汰与 profile 清理 |
| `Tests/TokenHealthTests/WebSessionCredentialTests.swift` | 凭据编解码与 `accountLabel` |
| `Tests/TokenHealthTests/WebSessionDescriptorTests.swift` | cookie 过滤、凭据组装、信封解包、未认证判定 |
| `Tests/TokenHealthTests/WebSessionRegistryTests.swift` | 内核缓存与淘汰 |

**修改**

| 文件 | 改动 |
| --- | --- |
| `Sources/TokenHealth/DeepSeekWebSessionCredential.swift` | 改为遵循 `WebSessionCredential`，删掉重复编解码 |
| `Sources/TokenHealth/Models.swift` | `ProviderKind` 加 `defaultsToBrowserLogin` |
| `Sources/TokenHealth/DeepSeekUsageProvider.swift` | 兜底改走注册表 + 环境变量门控的强制兜底开关 |
| `Sources/TokenHealth/SettingsView.swift` | DeepSeek 登录走注册表；连接文案带账号；`+` 按钮改成菜单 |
| `Sources/TokenHealth/AppState.swift` | `addConfig(providerKind:)`、唯一 `displayName`、删除时触发淘汰 |

**删除**

| 文件 | 时机 |
| --- | --- |
| `Sources/TokenHealth/DeepSeekWebLoginController.swift` | Task 8（全部调用点改完后） |

---

## Chunk 1: 共享类型

### Task 1: `WebSessionCredential` 协议

**Files:**
- Create: `Sources/TokenHealth/WebSessionCredential.swift`
- Modify: `Sources/TokenHealth/DeepSeekWebSessionCredential.swift`
- Test: `Tests/TokenHealthTests/WebSessionCredentialTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/TokenHealthTests/WebSessionCredentialTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

@Suite
struct WebSessionCredentialTests {
    @Test
    func roundTripsAllFields() {
        let credential = DeepSeekWebSessionCredential(
            accessToken: "token-123",
            cookieHeader: "a=1; b=2",
            accountName: "user@example.com"
        )

        let encoded = credential.encodedForStorage()
        #expect(encoded.hasPrefix("deepseek-web-session:"))

        #expect(DeepSeekWebSessionCredential.decode(from: encoded) == credential)
    }

    @Test
    func decodesLegacyStoredFormat() {
        let legacy = #"deepseek-web-session:{"accessToken":"legacy-token","cookieHeader":"c=3","accountName":"old@example.com"}"#
        let decoded = DeepSeekWebSessionCredential.decode(from: legacy)

        #expect(decoded?.accessToken == "legacy-token")
        #expect(decoded?.cookieHeader == "c=3")
        #expect(decoded?.accountName == "old@example.com")
    }

    @Test
    func rejectsForeignPrefix() {
        #expect(DeepSeekWebSessionCredential.decode(from: #"kimi-web-session:{"accessToken":"x"}"#) == nil)
    }

    @Test
    func rejectsCorruptedJSON() {
        #expect(DeepSeekWebSessionCredential.decode(from: "deepseek-web-session:{not json") == nil)
    }

    @Test
    func reportsEmptinessFromAccessToken() {
        #expect(DeepSeekWebSessionCredential(accessToken: nil, cookieHeader: "a=1", accountName: nil).isEmpty)
        #expect(!DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: nil).isEmpty)
    }

    @Test
    func exposesAccountLabelOnlyWhenNamed() {
        #expect(DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: "me@x.com").accountLabel == "me@x.com")
        #expect(DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: "").accountLabel == nil)
        #expect(DeepSeekWebSessionCredential(accessToken: "t", cookieHeader: nil, accountName: nil).accountLabel == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSessionCredentialTests -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: 编译失败（`Value of type 'DeepSeekWebSessionCredential' has no member 'accountLabel'`）

- [ ] **Step 3: 写协议**

新建 `Sources/TokenHealth/WebSessionCredential.swift`：

```swift
import Foundation

/// 网页登录类 Provider 存在 Keychain 里的凭据共用的编解码约定。
/// 各 Provider 的字段并不一致（有的没有 accessToken，有的没有账号名），
/// 协议只约定存储前缀与编解码，不要求统一字段。
protocol WebSessionCredential: Codable, Equatable, Sendable {
    static var storagePrefix: String { get }
    var isEmpty: Bool { get }
    var debugSummary: String { get }
    /// 设置页与错误文案展示的账号标识；没有该信息的 Provider 返回 nil
    var accountLabel: String? { get }
}

extension WebSessionCredential {
    func encodedForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "\(Self.storagePrefix)\(string)"
    }

    static func decode(from value: String) -> Self? {
        guard value.hasPrefix(storagePrefix) else {
            return nil
        }
        let json = String(value.dropFirst(storagePrefix.count))
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
```

- [ ] **Step 4: 让 DeepSeek 结构体遵循协议**

把 `Sources/TokenHealth/DeepSeekWebSessionCredential.swift` 整体替换为：

```swift
import Foundation

struct DeepSeekWebSessionCredential: WebSessionCredential {
    static let storagePrefix = "deepseek-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var accountName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty
    }

    var accountLabel: String? {
        guard let accountName, !accountName.isEmpty else {
            return nil
        }
        return accountName
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) account=\(accountStatus)"
    }
}
```

（编码格式、前缀、`debugSummary` 文案、`isEmpty` 语义都与改动前一致。）

- [ ] **Step 5: 跑测试确认通过**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSessionCredentialTests -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: PASS（6 个用例）

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/WebSessionCredential.swift Sources/TokenHealth/DeepSeekWebSessionCredential.swift Tests/TokenHealthTests/WebSessionCredentialTests.swift
git commit -m "$(cat <<'EOF'
Add shared web session credential codec

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 2: 描述符协议、脚本信封、错误类型与 DeepSeek 描述符

**Files:**
- Create: `Sources/TokenHealth/WebSessionError.swift`
- Create: `Sources/TokenHealth/WebSessionDescriptor.swift`
- Create: `Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift`
- Test: `Tests/TokenHealthTests/WebSessionDescriptorTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/TokenHealthTests/WebSessionDescriptorTests.swift`：

```swift
import Foundation
import Testing
@testable import TokenHealth

@Suite
@MainActor
struct WebSessionDescriptorTests {
    private let descriptor = DeepSeekSessionDescriptor()

    @Test
    func filtersCookiesByDeepSeekDomain() {
        #expect(descriptor.shouldIncludeCookie(domain: "platform.deepseek.com"))
        #expect(descriptor.shouldIncludeCookie(domain: ".deepseek.com"))
        #expect(descriptor.shouldIncludeCookie(domain: "DEEPSEEK.COM"))
        // 过滤是子串匹配（沿用旧实现），所以形如 notdeepseek.example.com 的域名也会命中；
        // 这里只断言确实不含 "deepseek" 子串的域名。
        #expect(!descriptor.shouldIncludeCookie(domain: "example.com"))
        #expect(!descriptor.shouldIncludeCookie(domain: "example.org"))
        #expect(!descriptor.shouldIncludeCookie(domain: "openai.com"))
    }

    @Test
    func buildsCredentialFromExtractionResult() {
        let extraction = #"{"href":"https://platform.deepseek.com/usage","accessToken":"tok-1","userSummary":{"email":"me@example.com"}}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: "c=1",
            pageTitle: nil
        )

        let decoded = encoded.flatMap { DeepSeekWebSessionCredential.decode(from: $0) }
        #expect(decoded?.accessToken == "tok-1")
        #expect(decoded?.cookieHeader == "c=1")
        #expect(decoded?.accountName == "me@example.com")
    }

    @Test
    func fallsBackToPageTitleWhenSummaryHasNoAccount() {
        let extraction = #"{"accessToken":"tok-2","userSummary":null}"#
        let encoded = descriptor.encodeCredential(
            extractionJSON: extraction,
            cookieHeader: nil,
            pageTitle: "me@example.com"
        )

        #expect(DeepSeekWebSessionCredential.decode(from: encoded ?? "")?.accountName == "me@example.com")
    }

    @Test
    func returnsNilWhenNoAccessToken() {
        #expect(descriptor.encodeCredential(extractionJSON: #"{"accessToken":""}"#, cookieHeader: "c=1", pageTitle: nil) == nil)
        #expect(descriptor.encodeCredential(extractionJSON: "not json", cookieHeader: "c=1", pageTitle: nil) == nil)
    }

    @Test
    func scansNestedSummaryForAccountIdentifier() {
        #expect(DeepSeekSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["phone": "13800000000"]]) == "13800000000")
        #expect(DeepSeekSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["nickname": "blues", "email": "a@b.co"]]) == "a@b.co")
        #expect(DeepSeekSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["id": "12345678"]]) == "12345678")
        // 邮箱优先于纯数字：created_at 这类数字字段的键名排在 email 前面，不能让它顶掉邮箱。
        #expect(DeepSeekSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["created_at": "1789000000", "email": "a@b.co"]]) == "a@b.co")
        #expect(DeepSeekSessionDescriptor.accountLabel(fromSummary: ["biz_data": ["nickname": "blues"]]) == nil)
        #expect(DeepSeekSessionDescriptor.accountLabel(fromSummary: nil) == nil)
    }

    @Test
    func returnsWholeEnvelopeAsUsageData() throws {
        let envelope = #"{"ok":true,"status":200,"summary":{"a":1},"amount":{"b":2},"cost":{"c":3}}"#
        let data = try descriptor.usageData(fromScriptResult: envelope)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["summary"] != nil)
        #expect(object?["amount"] != nil)
        #expect(object?["cost"] != nil)
    }

    @Test
    func usageScriptMentionsRequestedMonth() {
        let script = descriptor.usageFetchScript(context: WebSessionFetchContext(year: 2026, month: 9))
        #expect(script.contains("month=9&year=2026"))
    }

    @Test
    func extractionScriptToleratesSummaryFailure() {
        let script = descriptor.extractionScript
        #expect(script.contains("try {"))
        #expect(script.contains("userSummary"))
    }

    @Test
    func treatsUnauthorizedEnvelopeAsAuthenticationFailure() {
        #expect(descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":false,"status":401,"text":"unauthorized"}"#))
        #expect(descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":false,"status":403,"text":"forbidden"}"#))
        #expect(!descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":false,"status":500,"text":"boom"}"#))
        #expect(!descriptor.isAuthenticationFailure(scriptResultJSON: #"{"ok":true,"status":200,"text":""}"#))
        #expect(!descriptor.isAuthenticationFailure(scriptResultJSON: "not json"))
    }

    @Test
    func parsesScriptEnvelope() {
        let envelope = WebSessionScriptEnvelope.parse(#"{"ok":false,"status":403,"text":"forbidden","extra":1}"#)
        #expect(envelope?.ok == false)
        #expect(envelope?.status == 403)
        #expect(envelope?.text == "forbidden")
        #expect(WebSessionScriptEnvelope.parse("not json") == nil)
        #expect(WebSessionScriptEnvelope.object(from: #"{"hasAccessToken":true}"#)?["hasAccessToken"] as? Bool == true)
        #expect(WebSessionScriptEnvelope.object(from: "not json") == nil)
    }

    @Test
    func factoryOnlyKnowsDeepSeekForNow() {
        let factory = WebSessionDescriptorFactory()
        #expect(factory.descriptor(for: .deepSeek) != nil)
        #expect(factory.descriptor(for: .kimiCode) == nil)
        #expect(factory.descriptor(for: .demo) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSessionDescriptorTests -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: 编译失败（`cannot find 'DeepSeekSessionDescriptor' in scope`）

- [ ] **Step 3: 写错误类型**

新建 `Sources/TokenHealth/WebSessionError.swift`：

```swift
import Foundation

enum WebSessionError: LocalizedError {
    case unsupportedProvider
    case cancelled(providerTitle: String)
    case sessionExpired(providerTitle: String)
    case loadTimeout(providerTitle: String, seconds: Int)
    case invalidResponse(providerTitle: String)
    case requestFailed(providerTitle: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "This provider does not support web login"
        case let .cancelled(providerTitle):
            "\(providerTitle) login cancelled"
        case let .sessionExpired(providerTitle):
            "\(providerTitle) session expired. Log in again for this account."
        case let .loadTimeout(providerTitle, seconds):
            "\(providerTitle) page did not load within \(seconds) seconds."
        case let .invalidResponse(providerTitle):
            "\(providerTitle) usage response was invalid"
        case let .requestFailed(_, message):
            message
        }
    }
}
```

- [ ] **Step 4: 写协议、信封与工厂**

新建 `Sources/TokenHealth/WebSessionDescriptor.swift`：

```swift
import Foundation

struct WebSessionFetchContext {
    let year: Int
    let month: Int
}

/// 六个 Provider 的用量脚本都返回同一个信封形状。
struct WebSessionScriptEnvelope {
    let ok: Bool
    let status: Int
    let text: String

    static func object(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func parse(_ json: String) -> WebSessionScriptEnvelope? {
        guard let object = object(from: json) else {
            return nil
        }
        return WebSessionScriptEnvelope(
            ok: (object["ok"] as? Bool) ?? false,
            status: (object["status"] as? Int) ?? 0,
            text: (object["text"] as? String) ?? ""
        )
    }
}

@MainActor
protocol WebSessionDescriptor {
    /// 窗口标题、错误文案与日志用的 Provider 名，例如 "DeepSeek"
    var providerTitle: String { get }

    /// 登录窗口加载的地址，同时定义无头 WebView 需要处于的 origin
    var loginURL: URL { get }

    /// 无头 WebView 判断"已经在正确站点上"时比对的 host
    var originHost: String { get }

    /// cookie 是否属于本 Provider
    func shouldIncludeCookie(domain: String) -> Bool

    /// 在登录页执行，返回 JSON 字符串；内核不解析它
    var extractionScript: String { get }

    /// 由抽取结果、cookie、页面标题组装 Keychain 凭据串；无法组装时返回 nil
    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String?

    /// 在已认证的页面里执行，返回脚本信封
    func usageFetchScript(context: WebSessionFetchContext) -> String

    /// 从脚本信封里取出 Provider 解析器需要的字节
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data

    /// 从 Keychain 密文里解出账号标识，供设置页显示；解不出返回 nil
    func accountLabel(fromCredential credential: String) -> String?
}

extension WebSessionDescriptor {
    /// 默认判定：信封里 `ok == false` 且 `status` 为 401 / 403。
    /// 有意做成协议扩展（静态派发，不可覆写）：目前六个 Provider 的未认证都是 401/403。
    func isAuthenticationFailure(scriptResultJSON: String) -> Bool {
        guard let envelope = WebSessionScriptEnvelope.parse(scriptResultJSON),
              !envelope.ok else {
            return false
        }
        return envelope.status == 401 || envelope.status == 403
    }

    func accountLabel(fromCredential credential: String) -> String? {
        nil
    }
}

struct WebSessionDescriptorFactory {
    func descriptor(for kind: ProviderKind) -> (any WebSessionDescriptor)? {
        switch kind {
        case .deepSeek:
            DeepSeekSessionDescriptor()
        case .kimiCode, .zhipuCode, .miniMax, .volcengineArk, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
    }
}
```

- [ ] **Step 5: 写 DeepSeek 描述符**

新建 `Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift`。脚本从旧 controller **原样搬运**：

| 内容 | 来源 |
| --- | --- |
| 登录页 URL、`originHost` | `DeepSeekWebLoginController.swift:166` |
| cookie 过滤 | `:298`（`domain.lowercased().contains("deepseek")`） |
| 抽取脚本 | `:265-277`（唯一改动：新增 `userSummary` XHR，包在 `try/catch` 里） |
| 用量脚本 | `:319-356`（唯一改动：`month` / `year` 改成插值 `context`） |
| 页面标题取账号名 | `:312-317` |

```swift
import Foundation

@MainActor
struct DeepSeekSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "DeepSeek"
    let loginURL = URL(string: "https://platform.deepseek.com/usage")!
    let originHost = "platform.deepseek.com"

    func shouldIncludeCookie(domain: String) -> Bool {
        domain.lowercased().contains("deepseek")
    }

    var extractionScript: String {
        """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const tokenRecord = parseJSON(localStorage.getItem('userToken'));
          const token = tokenRecord && typeof tokenRecord.value === 'string' ? tokenRecord.value : '';
          let userSummary = null;
          try {
            const summary = new XMLHttpRequest();
            summary.open('GET', '/api/v0/users/get_user_summary', false);
            summary.withCredentials = true;
            summary.setRequestHeader('Accept', 'application/json');
            if (token) summary.setRequestHeader('Authorization', token.startsWith('Bearer ') ? token : `Bearer ${token}`);
            summary.send();
            userSummary = summary.status >= 200 && summary.status < 300 ? parseJSON(summary.responseText || '') : null;
          } catch (_) {
            userSummary = null;
          }
          return JSON.stringify({
            href: location.href,
            accessToken: token,
            userSummary: userSummary
          });
        })();
        """
    }

    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? {
        guard let data = extractionJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let credential = DeepSeekWebSessionCredential(
            accessToken: object["accessToken"] as? String,
            cookieHeader: cookieHeader,
            accountName: Self.accountLabel(fromSummary: object["userSummary"])
                ?? Self.accountNameFromPageTitle(pageTitle)
        )
        guard !credential.isEmpty else {
            return nil
        }
        return credential.encodedForStorage()
    }

    func usageFetchScript(context: WebSessionFetchContext) -> String {
        """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const tokenRecord = parseJSON(localStorage.getItem('userToken'));
          const token = tokenRecord && typeof tokenRecord.value === 'string' ? tokenRecord.value : '';
          const request = (path) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', path, false);
            xhr.withCredentials = true;
            xhr.setRequestHeader('Accept', 'application/json');
            if (token) xhr.setRequestHeader('Authorization', token.startsWith('Bearer ') ? token : `Bearer ${token}`);
            xhr.send();
            return {
              ok: xhr.status >= 200 && xhr.status < 300,
              status: xhr.status,
              text: xhr.responseText || '',
              json: parseJSON(xhr.responseText || '')
            };
          };
          const summary = request('/api/v0/users/get_user_summary');
          const amount = request('/api/v0/usage/amount?month=\(context.month)&year=\(context.year)');
          const cost = request('/api/v0/usage/cost?month=\(context.month)&year=\(context.year)');
          const firstFailure = [summary, amount, cost].find(item => !item.ok);
          return JSON.stringify({
            ok: !firstFailure,
            status: firstFailure ? firstFailure.status : 200,
            text: firstFailure ? firstFailure.text : '',
            hasAccessToken: Boolean(token),
            summary: summary.json,
            amount: amount.json,
            cost: cost.json
          });
        })();
        """
    }

    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        guard let data = scriptResultJSON.data(using: .utf8) else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return data
    }

    func accountLabel(fromCredential credential: String) -> String? {
        DeepSeekWebSessionCredential.decode(from: credential)?.accountLabel
    }

    /// 站点返回体没有稳定的公开字段文档，按"邮箱优先、其次纯数字 id"取；
    /// 取不到返回 nil，由调用方回退到页面标题。
    nonisolated static func accountLabel(fromSummary summary: Any?) -> String? {
        guard let summary else {
            return nil
        }
        var candidates: [String] = []
        collectStrings(from: summary, into: &candidates)
        // 邮箱优先：created_at / id 这类纯数字字段很多，不能让它顶掉邮箱。
        if let email = candidates.first(where: looksLikeEmail) {
            return email
        }
        return candidates.first(where: looksLikeNumericIdentifier)
    }

    private nonisolated static func collectStrings(from value: Any, into result: inout [String]) {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
            return
        }
        if let array = value as? [Any] {
            for item in array {
                collectStrings(from: item, into: &result)
            }
            return
        }
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                collectStrings(from: object[key] as Any, into: &result)
            }
        }
    }

    private nonisolated static func looksLikeEmail(_ value: String) -> Bool {
        guard let atIndex = value.firstIndex(of: "@") else {
            return false
        }
        let domain = value[value.index(after: atIndex)...]
        return domain.contains(".") && !value.hasPrefix("@") && !value.hasSuffix("@")
    }

    private nonisolated static func looksLikeNumericIdentifier(_ value: String) -> Bool {
        value.count >= 6 && value.allSatisfy(\.isNumber)
    }

    private nonisolated static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("DeepSeek") else {
            return nil
        }
        return title
    }
}
```

- [ ] **Step 6: 跑测试确认通过**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSessionDescriptorTests -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: PASS（11 个用例）

- [ ] **Step 7: 提交**

```bash
git add Sources/TokenHealth/WebSessionError.swift Sources/TokenHealth/WebSessionDescriptor.swift Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift Tests/TokenHealthTests/WebSessionDescriptorTests.swift
git commit -m "$(cat <<'EOF'
Add web session descriptor protocol and DeepSeek descriptor

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: 内核与注册表

> Task 3 只靠编译与 Task 9 的实机验收把关，没有单元测试：登录窗口与无头 WebView 都是 WebKit 绑定，单元测试里造不出真实会话。其中可纯逻辑化的部分（cookie 过滤、凭据组装、信封解包、未认证判定）已经在 Chunk 1 被测试覆盖。Task 4（注册表）**有**单元测试，见下。

### Task 3: `WebSessionLog` 与 `WebSessionController`

**Files:**
- Create: `Sources/TokenHealth/WebSessionLog.swift`
- Create: `Sources/TokenHealth/WebSessionController.swift`

- [ ] **Step 1: 写日志工具**

新建 `Sources/TokenHealth/WebSessionLog.swift`：

```swift
import Foundation

enum WebSessionLog {
    nonisolated static func debugLog(_ message: String, providerTitle: String) {
        guard ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1" else {
            return
        }
        print("[TokenHealth][\(providerTitle)] \(message)")
    }

    /// 把信封里的 `hasXxx` 布尔值拼成一行摘要，用于排查未认证。
    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let parts = object.keys
            .filter { $0.hasPrefix("has") }
            .sorted()
            .map { key -> String in
                let label = String(key.dropFirst(3))
                let value = (object[key] as? Bool) == true ? "yes" : "no"
                return "\(label)=\(value)"
            }
        return "jsAuth \(parts.joined(separator: " "))"
    }
}
```

- [ ] **Step 2: 写内核**

新建 `Sources/TokenHealth/WebSessionController.swift`：

```swift
import AppKit
import Foundation
import WebKit

@MainActor
final class WebSessionController: NSObject, WKNavigationDelegate {
    static let loadTimeoutSeconds = 20

    let configID: UUID

    private let descriptor: any WebSessionDescriptor
    private let dataStore: WKWebsiteDataStore
    private var loginWindow: WebSessionLoginWindowController?
    private var headlessWebView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var completion: ((Result<String, Error>) -> Void)?

    init(configID: UUID, descriptor: any WebSessionDescriptor, dataStore: WKWebsiteDataStore) {
        self.configID = configID
        self.descriptor = descriptor
        self.dataStore = dataStore
        super.init()
    }

    // MARK: - 登录

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion

        let controller = loginWindow ?? WebSessionLoginWindowController(
            descriptor: descriptor,
            dataStore: dataStore
        )
        controller.onImport = { [weak self] credential in
            self?.finish(.success(credential))
        }
        controller.onImportFailed = { [weak self] in
            let title = self?.descriptor.providerTitle ?? "Web"
            self?.finish(.failure(WebSessionError.invalidResponse(providerTitle: title)), keepWindowOpen: true)
        }
        controller.onCancel = { [weak self] in
            let title = self?.descriptor.providerTitle ?? "Web"
            self?.finish(.failure(WebSessionError.cancelled(providerTitle: title)))
        }
        loginWindow = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: Result<String, Error>, keepWindowOpen: Bool = false) {
        let completion = completion
        self.completion = nil
        completion?(result)

        guard !keepWindowOpen else {
            return
        }
        loginWindow?.window?.orderOut(nil)
    }

    // MARK: - 无头取用量

    func fetchUsage(context: WebSessionFetchContext) async throws -> Data {
        let webView = headlessWebView ?? makeHeadlessWebView()
        headlessWebView = webView

        try await ensureOriginLoaded(webView)

        let raw: String
        do {
            raw = try await evaluate(descriptor.usageFetchScript(context: context), in: webView)
        } catch {
            WebSessionLog.debugLog(
                "script failed: \(error.localizedDescription)",
                providerTitle: descriptor.providerTitle
            )
            throw WebSessionError.requestFailed(
                providerTitle: descriptor.providerTitle,
                message: error.localizedDescription
            )
        }

        guard let envelope = WebSessionScriptEnvelope.parse(raw) else {
            throw WebSessionError.invalidResponse(providerTitle: descriptor.providerTitle)
        }

        guard envelope.ok else {
            let authSummary = WebSessionLog.javascriptAuthSummary(
                from: WebSessionScriptEnvelope.object(from: raw) ?? [:]
            )
            WebSessionLog.debugLog(
                "web fetch failed HTTP \(envelope.status), \(authSummary), body=\(envelope.text.prefix(220))",
                providerTitle: descriptor.providerTitle
            )
            if descriptor.isAuthenticationFailure(scriptResultJSON: raw) {
                throw WebSessionError.sessionExpired(providerTitle: descriptor.providerTitle)
            }
            throw WebSessionError.requestFailed(
                providerTitle: descriptor.providerTitle,
                message: "\(descriptor.providerTitle) Web fetch HTTP \(envelope.status): \(envelope.text.prefix(160))"
            )
        }

        WebSessionLog.debugLog(
            "web fetch succeeded, bytes=\(raw.utf8.count)",
            providerTitle: descriptor.providerTitle
        )
        return try descriptor.usageData(fromScriptResult: raw)
    }

    // MARK: - 生命周期

    func teardown() async {
        resumeLoad(throwing: WebSessionError.requestFailed(
            providerTitle: descriptor.providerTitle,
            message: "\(descriptor.providerTitle) session was removed"
        ))
        loginWindow?.window?.orderOut(nil)
        loginWindow = nil
        headlessWebView?.navigationDelegate = nil
        headlessWebView = nil
        completion = nil
    }

    private func makeHeadlessWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        return webView
    }

    private func ensureOriginLoaded(_ webView: WKWebView) async throws {
        guard webView.url?.host != descriptor.originHost else {
            return
        }

        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.loadTimeoutSeconds))
            guard !Task.isCancelled else {
                return
            }
            resumeLoad(throwing: WebSessionError.loadTimeout(
                providerTitle: descriptor.providerTitle,
                seconds: Self.loadTimeoutSeconds
            ))
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            WebSessionLog.debugLog(
                "headless load \(descriptor.loginURL.absoluteString)",
                providerTitle: descriptor.providerTitle
            )
            webView.load(URLRequest(url: descriptor.loginURL))
        }
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let string = value as? String else {
                    continuation.resume(throwing: WebSessionError.invalidResponse(providerTitle: self.descriptor.providerTitle))
                    return
                }
                continuation.resume(returning: string)
            }
        }
    }

    /// 保证 continuation 只被 resume 一次：导航回调与超时都会走到这里。
    private func resumeLoad(throwing error: Error? = nil) {
        guard let continuation = loadContinuation else {
            return
        }
        loadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoad(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeLoad(throwing: error)
    }
}
```

- [ ] **Step 3: 写登录窗口**

在同一文件末尾追加。窗口布局与导入流程从 `DeepSeekWebLoginController.swift:89-197` 搬运，只把写死的 DeepSeek 换成描述符：

```swift
@MainActor
private final class WebSessionLoginWindowController: NSWindowController, NSWindowDelegate {
    var onImport: ((String) -> Void)?
    var onImportFailed: (() -> Void)?
    var onCancel: (() -> Void)?

    private let descriptor: any WebSessionDescriptor
    private let dataStore: WKWebsiteDataStore
    private let webView: WKWebView
    private let importButton: NSButton
    private let statusLabel: NSTextField

    init(descriptor: any WebSessionDescriptor, dataStore: WKWebsiteDataStore) {
        self.descriptor = descriptor
        self.dataStore = dataStore

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore

        webView = WKWebView(frame: .zero, configuration: configuration)
        importButton = NSButton(title: "Import Session", target: nil, action: nil)
        statusLabel = NSTextField(
            labelWithString: "Log in with \(descriptor.providerTitle), wait for Usage to load, then import."
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
        let footer = NSView()

        webView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        importButton.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(webView)
        container.addSubview(footer)
        footer.addSubview(statusLabel)
        footer.addSubview(importButton)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),

            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: importButton.leadingAnchor, constant: -12),

            importButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            importButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Login with \(descriptor.providerTitle)"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        webView.load(URLRequest(url: descriptor.loginURL))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    @objc private func importSession() {
        statusLabel.stringValue = "Importing \(descriptor.providerTitle) session..."
        importButton.isEnabled = false

        webView.evaluateJavaScript(descriptor.extractionScript) { [weak self] value, _ in
            guard let self else {
                return
            }
            let extractionJSON = (value as? String) ?? ""

            self.dataStore.httpCookieStore.getAllCookies { cookies in
                let matching = cookies
                    .filter { self.descriptor.shouldIncludeCookie(domain: $0.domain) }
                    .map { "\($0.name)=\($0.value)" }
                let cookieHeader = matching.isEmpty ? nil : matching.joined(separator: "; ")

                self.importButton.isEnabled = true

                guard let credential = self.descriptor.encodeCredential(
                    extractionJSON: extractionJSON,
                    cookieHeader: cookieHeader,
                    pageTitle: self.webView.title
                ) else {
                    self.statusLabel.stringValue = "No session found. Make sure \(self.descriptor.providerTitle) is logged in."
                    self.onImportFailed?()
                    return
                }

                WebSessionLog.debugLog("session imported", providerTitle: self.descriptor.providerTitle)
                self.statusLabel.stringValue = "Session imported."
                self.onImport?(credential)
            }
        }
    }
}
```

以上窗口代码是完整的，约束块（13 条）从 `DeepSeekWebLoginController.swift:109-136` 搬运，
变量名不变，可直接粘贴。

- [ ] **Step 4: 编译**

Run: `swift build 2>&1 | tail -20`（`swift build` 不需要额外的 framework 参数）
Expected: `Build complete!`

- [ ] **Step 5: 跑全量测试确认没碰坏别的**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F" 2>&1 | tail -15
```
Expected: `52 tests in 5 suites` 之外只多出 Chunk 1 的新用例，失败集合与基线一致（只有 Cursor 那一个）

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/WebSessionLog.swift Sources/TokenHealth/WebSessionController.swift
git commit -m "$(cat <<'EOF'
Add shared web session kernel and login window

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 4: `WebSessionRegistry`

**Files:**
- Create: `Sources/TokenHealth/WebSessionRegistry.swift`
- Test: `Tests/TokenHealthTests/WebSessionRegistryTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/TokenHealthTests/WebSessionRegistryTests.swift`：

```swift
import Foundation
import Testing
import WebKit
@testable import TokenHealth

@Suite
@MainActor
struct WebSessionRegistryTests {
    private final class ProfileRemovalSpy {
        var removed: [UUID] = []
    }

    private func makeRegistry(spy: ProfileRemovalSpy) -> WebSessionRegistry {
        WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            removeProfile: { id in spy.removed.append(id) }
        )
    }

    private func deepSeekConfig() -> ServiceConfig {
        ServiceConfig(displayName: "DeepSeek", providerKind: .deepSeek, authMode: .browserLogin)
    }

    @Test
    func reusesControllerForSameConfig() {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        let config = deepSeekConfig()

        let first = registry.controller(for: config)
        let second = registry.controller(for: config)

        #expect(first != nil)
        #expect(first === second)
    }

    @Test
    func separatesControllersPerConfig() {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        let first = deepSeekConfig()
        let second = deepSeekConfig()

        let firstController = registry.controller(for: first)
        let secondController = registry.controller(for: second)
        #expect(firstController !== secondController)
    }

    @Test
    func returnsNilForProvidersWithoutDescriptor() {
        let registry = makeRegistry(spy: ProfileRemovalSpy())
        let config = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)

        #expect(registry.controller(for: config) == nil)
    }

    @Test
    func evictRemovesControllerAndProfile() async {
        let spy = ProfileRemovalSpy()
        let registry = makeRegistry(spy: spy)
        let config = deepSeekConfig()
        let first = registry.controller(for: config)

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
        #expect(registry.controller(for: config) !== first)
    }

    @Test
    func evictClearsProfileEvenWithoutController() async {
        let spy = ProfileRemovalSpy()
        let registry = makeRegistry(spy: spy)
        let config = deepSeekConfig()

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
    }

    @Test
    func evictLeavesOtherProvidersAlone() async {
        let spy = ProfileRemovalSpy()
        let registry = makeRegistry(spy: spy)
        let config = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)

        await registry.evict(config: config)

        #expect(spy.removed.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSessionRegistryTests -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: 编译失败（`cannot find 'WebSessionRegistry' in scope`）

- [ ] **Step 3: 实现**

新建 `Sources/TokenHealth/WebSessionRegistry.swift`：

```swift
import Foundation
import WebKit

@MainActor
final class WebSessionRegistry {
    static let shared = WebSessionRegistry()

    private let makeDataStore: @MainActor (UUID) -> WKWebsiteDataStore
    private let removeProfile: @MainActor (UUID) async -> Void
    private var controllers: [UUID: WebSessionController] = [:]

    init(
        makeDataStore: @escaping @MainActor (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        removeProfile: @escaping @MainActor (UUID) async -> Void = { await WebSessionRegistry.removePersistentProfile($0) }
    ) {
        self.makeDataStore = makeDataStore
        self.removeProfile = removeProfile
    }

    /// 取该 config 的内核，不存在则创建；Provider 不支持网页登录时返回 nil。
    func controller(for config: ServiceConfig) -> WebSessionController? {
        if let existing = controllers[config.id] {
            return existing
        }
        guard let descriptor = WebSessionDescriptorFactory().descriptor(for: config.providerKind) else {
            return nil
        }
        let controller = WebSessionController(
            configID: config.id,
            descriptor: descriptor,
            dataStore: makeDataStore(config.id)
        )
        controllers[config.id] = controller
        return controller
    }

    /// 删除账号：淘汰内核并清掉磁盘上的 profile。
    /// 即使本次运行里没创建过内核（例如重启后直接删除），也要清 profile。
    func evict(config: ServiceConfig) async {
        if let controller = controllers.removeValue(forKey: config.id) {
            await controller.teardown()
        }
        guard WebSessionDescriptorFactory().descriptor(for: config.providerKind) != nil else {
            return
        }
        await removeProfile(config.id)
    }

    /// 调用前必须保证使用该 store 的 WKWebView 已释放（SDK 的硬性要求），
    /// `evict` 里先 `teardown()` 再走到这里。
    static func removePersistentProfile(_ id: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if let error {
                    WebSessionLog.debugLog(
                        "profile removal failed for \(id.uuidString): \(error.localizedDescription)",
                        providerTitle: "WebSession"
                    )
                }
                continuation.resume()
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSessionRegistryTests -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: PASS（6 个用例）

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/WebSessionRegistry.swift Tests/TokenHealthTests/WebSessionRegistryTests.swift
git commit -m "$(cat <<'EOF'
Add web session registry with per-config controller cache

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 3: 接线

### Task 5: DeepSeek Provider 的兜底改走注册表

**Files:**
- Modify: `Sources/TokenHealth/DeepSeekUsageProvider.swift:18-49`（兜底分支）、`:74`、`:136-143`（其余旧引用）

- [ ] **Step 1: 改兜底调用，并迁移同文件里其余的旧引用**

先改 `fetchPlatformUsage` 的兜底分支。把：

```swift
            } catch {
                DeepSeekWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                bundleData = try await DeepSeekWebLoginController.shared.fetchUsageBundleFromActiveSession(
                    month: period.month,
                    year: period.year
                )
            }
```

改为：

```swift
            } catch {
                WebSessionLog.debugLog(
                    "native request failed: \(error.localizedDescription); falling back to own session",
                    providerTitle: "DeepSeek"
                )
                guard let controller = await WebSessionRegistry.shared.controller(for: config) else {
                    throw WebSessionError.unsupportedProvider
                }
                bundleData = try await controller.fetchUsage(
                    context: WebSessionFetchContext(year: period.year, month: period.month)
                )
            }
```

`await` 不能省：`WebSessionRegistry` 是 `@MainActor`，而 `UsageProvider.fetchUsage` 是 nonisolated
（`Providers.swift:3` 的 `protocol UsageProvider: Sendable` 没有 actor 隔离）。旧代码那一个
`try await` 覆盖了整条表达式才得以编译。

然后迁移同文件里剩下的 5 处旧引用（不改的话 Task 8 的 grep 门禁会失败）：

| 位置 | 现在 | 改成 |
| --- | --- | --- |
| `:74`、`:136`、`:140`、`:143` | `DeepSeekWebLoginController.debugLog(msg)` | `WebSessionLog.debugLog(msg, providerTitle: "DeepSeek")` |
| `:141` | `throw DeepSeekWebLoginController.LoginError.requestFailed("DeepSeek HTTP \(httpResponse.statusCode): \(body.prefix(160))")` | `throw WebSessionError.requestFailed(providerTitle: "DeepSeek", message: "DeepSeek HTTP \(httpResponse.statusCode): \(body.prefix(160))")` |

（`WebSessionLog.debugLog` 与旧 `DeepSeekWebLoginController.debugLog` 同样是 `nonisolated` +
`TOKEN_HEALTH_DEBUG` 门控，`localizedDescription` 文案也一致，行为不变。）

- [ ] **Step 2: 加环境变量门控的强制兜底开关**

在**内层** `do` 块的第一句（也就是 `bundleData = try await fetchUsageBundle(session:period:)` 之前）插入：

```swift
            do {
                if ProcessInfo.processInfo.environment["TOKEN_HEALTH_FORCE_WEB_FALLBACK"] == "1" {
                    WebSessionLog.debugLog("forced web fallback", providerTitle: "DeepSeek")
                    throw WebSessionError.requestFailed(providerTitle: "DeepSeek", message: "forced fallback")
                }
                bundleData = try await fetchUsageBundle(session: session, period: period)
            } catch {
```

位置很关键：必须在内层 `do` 里。若放到外层 `do` 的开头（`let bundleData: Data` 之前），
会被外层 `catch` 吞掉、直接返回 `.unavailable` 快照，兜底路径根本不会执行。

与既有的 `TOKEN_HEALTH_DEBUG` 同一模式，便于 Task 9 复现兜底路径；不设该环境变量时行为完全不变。

- [ ] **Step 3: 编译并跑全量测试**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift build 2>&1 | tail -5 && swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F" 2>&1 | tail -5
```
Expected: `Build complete!`，测试失败集合与基线一致（只有 Cursor 那一个）

- [ ] **Step 4: 提交**

```bash
git add Sources/TokenHealth/DeepSeekUsageProvider.swift
git commit -m "$(cat <<'EOF'
Route DeepSeek web fallback through its own account session

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 6: 设置页的登录入口与连接状态

**Files:**
- Modify: `Sources/TokenHealth/SettingsView.swift:12, 141-154, 382-413, 468-520`

- [ ] **Step 1: 把登录状态变量改名**

`isKimiLoginInProgress` 早已不是 Kimi 专用：把 `:12` 的声明与 `:150`、`:154`、`:473`、`:475`、`:518` 五处引用统一改名成 `isWebLoginInProgress`。

- [ ] **Step 2: 缓存账号标识**

`:13` 附近加一个状态位：

```swift
    @State private var storedAccountLabel: String?
```

在 `loadSecretsIfNeeded` 里，凡是把 `apiKeyStoredValue` 置为 `false` 的两处（`:392` 的 Integrations 分支、`:404` 的本地登录分支）后面都补一行 `storedAccountLabel = nil`；`:384-387` 那个 `guard let selectedID` 的提前返回分支没设 `apiKeyStoredValue`，但也一并清掉 `storedAccountLabel`，避免残留上一个配置的账号名。在 `:408-412` 那个分支里改成：

```swift
        let secrets = appState.loadSecrets(for: selectedID)
        apiKey = ""
        password = secrets.password
        apiKeyStoredValue = !secrets.apiKey.isEmpty
        storedAccountLabel = webSessionAccountLabel(for: selectedID, credential: secrets.apiKey)
        loadedSecretID = selectedID
```

并加这个 helper：

```swift
    private func webSessionAccountLabel(for configID: UUID, credential: String) -> String? {
        guard !credential.isEmpty,
              let kind = appState.configs.first(where: { $0.id == configID })?.providerKind,
              let descriptor = WebSessionDescriptorFactory().descriptor(for: kind) else {
            return nil
        }
        return descriptor.accountLabel(fromCredential: credential)
    }
```

- [ ] **Step 3: 连接文案带账号**

把 `:142` 那一行：

```swift
                        Text(apiKeyStoredValue ? "\(binding.wrappedValue.providerKind.title) web session stored locally" : "\(binding.wrappedValue.providerKind.title) web session not connected")
```

改为：

```swift
                        Text(webSessionStatusText(for: binding.wrappedValue))
```

并加：

```swift
    private func webSessionStatusText(for config: ServiceConfig) -> String {
        let title = config.providerKind.title
        guard apiKeyStoredValue else {
            return "\(title) web session not connected"
        }
        guard loadedSecretID == config.id, let storedAccountLabel else {
            return "\(title) web session stored locally"
        }
        return "\(title) web session connected: \(storedAccountLabel)"
    }
```

两级 guard 不能合并：现有文案有两条语义——没存凭据是 "not connected"，存了凭据才是
"stored locally"（`SettingsView.swift:142` 是 DeepSeek 与未迁移五家共用的分支，
丢掉第一条会让五家的 UI 文案回归）。

- [ ] **Step 4: 登录按钮走注册表**

`startWebLogin(for:)`（`:468-520`）里 `.deepSeek` 分支改为：

```swift
        case .deepSeek:
            guard let config = appState.configs.first(where: { $0.id == selectedID }),
                  let controller = WebSessionRegistry.shared.controller(for: config) else {
                isWebLoginInProgress = false
                appState.lastError = WebSessionError.unsupportedProvider.localizedDescription
                return
            }
            controller.startLogin(completion: completion)
```

其余五个 `case`（Kimi、Zhipu、MiniMax、Volcengine Ark、OpenCode Go）保持不变，阶段二再迁移。

在 `completion` 闭包里成功存下凭据之后（`:487-494` 那段 `apiKeyStoredValue = true` 附近）补一行 `loadSecretsIfNeeded(force: true)`，让刚导入的账号标识立刻显示出来。

- [ ] **Step 5: 编译并跑全量测试**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift build 2>&1 | tail -5 && swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F" 2>&1 | tail -5
```
Expected: `Build complete!`，测试失败集合与基线一致（只有 Cursor 那一个）

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/SettingsView.swift
git commit -m "$(cat <<'EOF'
Route DeepSeek login through the session registry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 7: 添加账号入口与删除时清 profile

**Files:**
- Modify: `Sources/TokenHealth/Models.swift:36-61`
- Modify: `Sources/TokenHealth/AppState.swift:54-77`
- Modify: `Sources/TokenHealth/SettingsView.swift:61-68`

- [ ] **Step 1: `ProviderKind` 加默认登录模式**

在 `Sources/TokenHealth/Models.swift` 的 `ProviderKind` 里、`supportsWebLogin` 之后加：

```swift
    /// 只能靠网页登录的 Provider（有 API key 路径的不算），新建配置时默认进 Login 模式。
    var defaultsToBrowserLogin: Bool {
        supportsWebLogin && !usesWebSession && !usesSingleAPIKeyOnly
    }
```

（当前只有 `.deepSeek` 为 true。）

- [ ] **Step 2: `AppState.addConfig` 接受 Provider 并保证名字唯一**

把 `AppState.swift:54-60` 改为：

```swift
    func addConfig(providerKind: ProviderKind = .kimiCode) -> UUID {
        let config = ServiceConfig(
            displayName: uniqueDisplayName(for: providerKind),
            providerKind: providerKind,
            authMode: providerKind.defaultsToBrowserLogin ? .browserLogin : .api
        )
        configs.append(config)
        settingsSelectedID = config.id
        saveConfigs()
        return config.id
    }

    private func uniqueDisplayName(for kind: ProviderKind) -> String {
        let base = kind.title
        let existing = Set(configs.map(\.displayName))
        guard existing.contains(base) else {
            return base
        }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }
```

- [ ] **Step 3: 删除账号时清 profile**

`AppState.deleteConfig(id:)`（`:62-77`）在 `lastError = nil` 之后、`return true` 之前插入：

```swift
            Task { await WebSessionRegistry.shared.evict(config: config) }
```

- [ ] **Step 4: `+` 按钮改成菜单**

把 `SettingsView.swift:61-68`：

```swift
                HStack {
                    Button {
                        selectedID = appState.addConfig()
                        loadSecretsIfNeeded(force: true)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add plan")
```

改为：

```swift
                HStack {
                    Menu {
                        Button("New plan") {
                            selectedID = appState.addConfig()
                            loadSecretsIfNeeded(force: true)
                        }
                        Divider()
                        ForEach(ProviderKind.allCases.filter(\.supportsWebLogin)) { kind in
                            Button("Add \(kind.title) account") {
                                selectedID = appState.addConfig(providerKind: kind)
                                loadSecretsIfNeeded(force: true)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add plan or account")
```

另外两处 `appState.addConfig()` 调用（`SettingsView.swift:227` 的空状态按钮、`StatusMenuView.swift:55`）不动——默认参数让它们继续可用。

- [ ] **Step 5: 编译并跑全量测试**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift build 2>&1 | tail -5 && swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F" 2>&1 | tail -5
```
Expected: `Build complete!`，测试失败集合与基线一致（只有 Cursor 那一个）

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenHealth/Models.swift Sources/TokenHealth/AppState.swift Sources/TokenHealth/SettingsView.swift
git commit -m "$(cat <<'EOF'
Add per-provider account creation and profile cleanup on delete

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

### Task 8: 删除 DeepSeek 旧 controller

**Files:**
- Delete: `Sources/TokenHealth/DeepSeekWebLoginController.swift`

- [ ] **Step 1: 确认没有残留引用**

Run: `grep -rn "DeepSeekWebLoginController" Sources/ Tests/`
Expected: 无输出。若有输出，说明还有调用点没改，先改完再继续。

- [ ] **Step 2: 删除文件**

```bash
git rm Sources/TokenHealth/DeepSeekWebLoginController.swift
```

- [ ] **Step 3: 编译并跑全量测试**

Run:
```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift build 2>&1 | tail -5 && swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F" 2>&1 | tail -5
```
Expected: `Build complete!`，测试失败集合与基线一致（只有 Cursor 那一个）

- [ ] **Step 4: 提交**

```bash
git commit -m "$(cat <<'EOF'
Remove the superseded DeepSeek login controller

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 4: 实机验收

### Task 9: 用两个真实 DeepSeek 账号验收

**Files:** 无代码改动（验收中发现问题则回到对应任务修）

- [ ] **Step 1: 构建并启动**

```bash
bash scripts/build-app.sh && open ".build/app/Token Health.app"
```

- [ ] **Step 2: 记下删除前的 profile 目录**

Run: `ls -la ~/Library/WebKit/local.token-health.app/WebsiteData/`
Expected: 记下当前条目，删除账号后要对比。identifier store 在磁盘上的确切形态未验证，必要时用 `find ~/Library/WebKit -newermt '-5 minutes' -type d` 辅助定位最近写入的目录。

- [ ] **Step 3: 账号 A**

设置里 `+` → "Add DeepSeek account" → 选中它 → "Login with DeepSeek" → 用账号 A 登录 →
等 Usage 页加载 → Import Session。
Expected: 菜单出现账号 A 的卡片，第一行是 `DeepSeek`，副标题是 `DeepSeek · <账号标识>`；
账号标识取不到时副标题就是 `DeepSeek`（spec §5.6 不要求一定能取到邮箱），
这种情况记一笔即可，不算失败。

- [ ] **Step 4: 账号 B，并检查 A 没被顶掉（核心验收点）**

再次 `+` → "Add DeepSeek account"（名字应是 `DeepSeek 2`）→ 登录账号 B → Import。
Expected:
- 菜单里 A 和 B 同时在，两行 `displayName` 不同（`DeepSeek` / `DeepSeek 2`）
- **A 的数字与 Step 3 完全一致**
- B 的数字是账号 B 的

- [ ] **Step 5: 两个登录窗口可以同时打开**

对 A 与 B 分别点 "Login with DeepSeek"。
Expected: 两个窗口同时存在，A 的窗口里是账号 A 的已登录页面，B 的窗口里是账号 B 的，互不影响

- [ ] **Step 6: 重启后仍然可用**

退出 App 再启动。
Expected: A 和 B 都还在，刷新后两张卡片都出数字。这一步走的是 Keychain 凭据的 URLSession 主路径，
per-account profile 只在主请求失败时才参与（兜底）；所以这里若失败，先看 Keychain 凭据有没有丢，
而不是先怀疑 profile。

- [ ] **Step 7: 兜底路径用的是自己的会话**

先退出 Step 6 启动的那个实例（只保留一个菜单栏进程），再前台运行并打开强制兜底开关。
可执行文件名是 `TokenHealth`（无空格，见 `scripts/build-app.sh:44`）：

```bash
TOKEN_HEALTH_DEBUG=1 TOKEN_HEALTH_FORCE_WEB_FALLBACK=1 ".build/app/Token Health.app/Contents/MacOS/TokenHealth"
```

Expected: 每张卡片各打一行 `[TokenHealth][DeepSeek] forced web fallback`，随后各自 `web fetch succeeded`；
A 与 B 的数字各自与此前一致，**没有出现两张卡片数字相同**（那就是串号回归）。
若某个账号的站点会话已过期，该卡片应显示 `DeepSeek session expired. Log in again for this account.`，
而不是回落到另一个账号的数据。

- [ ] **Step 8: 删除账号清 profile**

删掉账号 B，然后：

Run: `ls -la ~/Library/WebKit/local.token-health.app/WebsiteData/`
Expected: 与 Step 2 相比，属于 B 的目录消失，A 的还在。

- [ ] **Step 9: 记录结果**

把 Step 3–8 的实际结果写进本文件末尾的"验收记录"小节，包含失败的项与现象；没有失败项也要写一句"全部通过"。

---

## 验收记录

（执行时填写）

---

## 阶段二（不在本计划内）

按 spec §9：把 Kimi、Zhipu、MiniMax、Volcengine Ark、OpenCode Go 的描述符补齐
（含 `KimiWebUsageBridge` 的日志迁移与其 9 处调用点），删除各自窗口实现，逐个实机验证。
需要另写一份计划。

落地时注意两点：

- `accountLabel` 里 `guard let accountName, !accountName.isEmpty else { return nil }` 这段
  会在 MiniMax、Volcengine Ark、OpenCode Go 三家重复，届时应抽成 `WebSessionCredential`
  协议扩展里的 `static func nonEmpty(_ value: String?) -> String?`，不要抄三遍。
- 其余五家的凭据字段与 DeepSeek 不同（Kimi/Zhipu 没有 `accountName`，Volcengine Ark/OpenCode Go
  没有 `accessToken`），迁移时按 spec §5.1 的表格逐家对齐，不要套用 DeepSeek 的字段。
