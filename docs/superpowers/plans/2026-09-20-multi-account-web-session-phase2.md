# 多账号登录会话 阶段二实现计划（其余五家 Provider）

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Kimi、Zhipu、MiniMax、Volcengine Ark、OpenCode Go 五家网页登录 Provider 迁移到阶段一建好的共享会话内核上，让它们的多个账号也能各自独立登录、互不顶掉。

**Architecture:** 每家 Provider 得到一个小描述符（`XxxWebSessionDescriptor`），只装该家特有的东西：登录页、cookie 谓词、抽取脚本、用量脚本、信封解包、账号标识。阶段一已经验证过：**这些差异全都能在描述符里表达，不需要改内核**。每家迁移完就删掉自己的旧 controller。

**Tech Stack:** Swift 6 / swift-tools 6.0、SwiftUI（macOS 14+）、WebKit、swift-testing。

**上游文档：**
- 设计与阶段一计划：`docs/superpowers/specs/2026-09-18-multi-account-web-session-design.md`、`docs/superpowers/plans/2026-09-18-multi-account-web-session.md`
- **每家的逐行研究（本计划的代码来源，含出处行号）**：`docs/superpowers/plans/phase2-research/{kimi,zhipu,minimax,volcengine-ark,opencode-go}.md`

## 开始前的状态

分支 `feature/multi-account-web-session`，阶段一已完成并已装到 `/Applications` 实机验证可用。测试基线：`86 tests in 8 suites`，其中 **8 个 issue 是既有的**（`CursorUsageProviderTests` 的 `mapsMonthlyAutoAndAPIPools` 7 个 + `acceptsFlexiblePercentagesAndFormatsPlanName` 1 个，另一会话负责）。本阶段每加一个 Provider 会增加用例数，但**失败集合必须始终只有这两个**。

## 共用约定

- **注释一律英文**（仓库 40 个 Swift 文件只有 1 行既有中文注释）。研究文档里的代码已经是英文注释。
- **测试命令**（本机无 Xcode，裸跑 `swift test` 会报 `no such module 'Testing'`）：
  ```bash
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
  ```
  `--filter <SuiteName>` 放在 `swift test` 之后。`swift build` 不需要这些参数。
- **提交**：只用显式路径 `git add`（工作区里 `AppSupport/Info.plist`、`Sources/TokenHealth/StatusMenuView.swift` 是无关的既有改动，不要卷进来）；尾注固定 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`；message 用陈述句、不带 `feat:` 前缀，与分支既有提交一致。
- **每个任务一个提交**，且每个提交都必须能编译、能通过测试。
- 判断"是不是新回归"的方法：跑全量后看失败集合，**只有** `mapsMonthlyAutoAndAPIPools`（7 条断言）与 `acceptsFlexiblePercentagesAndFormatsPlanName`（1 条）算基线；出现任何别的失败都是本次改动引入的。

## 四个需要拍板的决定（已定，任务照此执行）

1. **会话过期文案统一用内核的**：`"<Provider> session expired. Log in again for this account."`（`WebSessionError.sessionExpired`）。
   五家的旧文案各不相同（Kimi/Zhipu/MiniMax/Volcengine Ark 是 `"<Provider> Web fetch HTTP 401: …"`，OpenCode Go 是 `"OpenCode Go session expired. Re-login with OpenCode Go."`）。**统一替换、不做逐字节保留**：六家一致 + "for this account" 正是本功能的多账号语义。
   ⚠️ **这条覆盖研究文档**：`phase2-research/opencode-go.md` §3 的表格里插了一条 `case .sessionExpired: message = "OpenCode Go session expired. Re-login with OpenCode Go."`——**不要采纳那一行**。Task 3 的 catch 不需要 `.sessionExpired` 分支，让它落到 `sessionError.localizedDescription` 即可。
   同时**保留** `OpenCodeGoUsageProvider` 里那条基于字符串 `"401"` 的判断（它管的是**原生**路径的 HTTP 状态码，与内核无关）。
2. **新增 `WebSessionFetchContext.currentUTC()`**：五家的脚本都不插值月份/年份，但 `fetchUsage(context:)` 必须收一个 context。与其让五家各自手搓日历（研究文档里各写了一份），不如加一个共用工厂，值取当前 UTC 年/月。
3. **新增 `WebSessionCredential.nonEmpty(_:)`**：`guard let x, !x.isEmpty else { return nil }` 这段会在 MiniMax、Volcengine Ark、OpenCode Go 三家出现，抽成协议扩展里的静态方法，不要抄三遍。
4. **五家都加 `TOKEN_HEALTH_FORCE_WEB_FALLBACK` 调试开关**（阶段一 DeepSeek 已有）。这不是可选项：五家的原生请求都会先跑，而它用的就是刚写进 Keychain 的同一份凭据——没有这个开关，实机验收**根本碰不到本次迁移的代码**（见 Task 8）。

---

## Task 1: 共用小工具

**Files:**
- Modify: `Sources/TokenHealth/WebSessionDescriptor.swift`
- Modify: `Sources/TokenHealth/WebSessionCredential.swift`
- Modify: `Sources/TokenHealth/DeepSeekWebSessionCredential.swift`
- Test: `Tests/TokenHealthTests/WebSessionDescriptorTests.swift`、`Tests/TokenHealthTests/WebSessionCredentialTests.swift`

- [ ] **Step 1: 写失败测试**

`WebSessionDescriptorTests` 加：

```swift
    @Test
    func buildsTheCurrentUTCMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date()
        let context = WebSessionFetchContext.currentUTC(now: now)

        #expect(context.year == calendar.component(.year, from: now))
        #expect(context.month == calendar.component(.month, from: now))
    }
```

`WebSessionCredentialTests` 加：

```swift
    @Test
    func treatsNilAndEmptyStringsAlike() {
        #expect(DeepSeekWebSessionCredential.nonEmpty(nil) == nil)
        #expect(DeepSeekWebSessionCredential.nonEmpty("") == nil)
        #expect(DeepSeekWebSessionCredential.nonEmpty("x") == "x")
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSession -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: 编译失败（`currentUTC` / `nonEmpty` 不存在）

- [ ] **Step 3: 实现**

`WebSessionDescriptor.swift` 末尾加：

```swift
extension WebSessionFetchContext {
    /// The current year and month in UTC. Providers whose scripts take no period still have to pass
    /// something to `fetchUsage(context:)`; this keeps the value meaningful if a script ever starts
    /// interpolating one.
    static func currentUTC(now: Date = Date()) -> WebSessionFetchContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return WebSessionFetchContext(
            year: calendar.component(.year, from: now),
            month: calendar.component(.month, from: now)
        )
    }
}
```

顺手把 `WebSessionDescriptor.swift` 里 `encodeCredential` 的文档注释改准（它说 "Five phase-2 providers must pull a specifically-named cookie"，实际只有三家：Zhipu、MiniMax、Volcengine Ark）。

`WebSessionCredential.swift` 的协议扩展里加：

```swift
    /// Maps an optional string to nil when it is nil or empty, so conformers can write
    /// `var accountLabel: String? { Self.nonEmpty(accountName) }` instead of repeating the guard.
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
```

`DeepSeekWebSessionCredential.accountLabel` 改成 `Self.nonEmpty(accountName)`——它的现有测试已覆盖 nil / 空串 / 非空三种情况，改完必须仍然全过。

- [ ] **Step 4: 跑测试确认通过**

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test --filter WebSession -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F"
```
Expected: PASS（既有 34 个 + 新增 2 个）

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/WebSessionDescriptor.swift Sources/TokenHealth/WebSessionCredential.swift Sources/TokenHealth/DeepSeekWebSessionCredential.swift Tests/TokenHealthTests/WebSessionDescriptorTests.swift Tests/TokenHealthTests/WebSessionCredentialTests.swift
git commit -m "$(cat <<'EOF'
Add shared fetch-context and credential helpers for phase two

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 用系统查询替换 profile 内存簿记

阶段一留下的已知缺口：`WebSessionRegistry.configuredProfileIDs` 只在内存里，于是"改过 Provider 类型 → 重启 App → 再删除"这条组合下，`evict` 会提前返回、账号留在磁盘上的 profile 不会被清理。系统本身就能回答"这个 id 到底有没有 profile"，自己做簿记既多余又会在重启后失效。

**Files:**
- Modify: `Sources/TokenHealth/WebSessionRegistry.swift`
- Test: `Tests/TokenHealthTests/WebSessionRegistryTests.swift`

- [ ] **Step 1: 写失败测试**

在 `WebSessionRegistryTests` 里把注入改成三个依赖，并加用例：

```swift
    private func makeRegistry(
        spy: ProfileRemovalSpy,
        existingProfiles: Set<UUID> = []
    ) -> WebSessionRegistry {
        WebSessionRegistry(
            makeDataStore: { _ in .nonPersistent() },
            hasStoredProfile: { existingProfiles.contains($0) },
            removeProfile: { id in spy.removed.append(id) }
        )
    }

    @Test
    func evictClearsAProfileThatOutlivedTheAppRun() async {
        // This account had a profile on disk from an earlier run, and this run never built a kernel
        // for it (the provider kind was changed away from a web-login kind, then the app restarted).
        // Neither the cache nor the current kind can answer "was there a profile?" — only the store
        // query can. The config must therefore be one the factory rejects, or the descriptor arm of
        // the guard short-circuits and this test would pass against the old bookkeeping too.
        let spy = ProfileRemovalSpy()
        var config = deepSeekConfig()
        config.providerKind = .demo
        let registry = makeRegistry(spy: spy, existingProfiles: [config.id])

        await registry.evict(config: config)

        #expect(spy.removed == [config.id])
    }

    @Test
    func evictLeavesProfilesThatNeverExisted() async {
        let spy = ProfileRemovalSpy()
        let config = ServiceConfig(displayName: "Demo", providerKind: .demo, authMode: .api)
        let registry = makeRegistry(spy: spy)

        await registry.evict(config: config)

        #expect(spy.removed.isEmpty)
    }
```

现有的 `evictClearsTheProfileAfterTheKernelWasDroppedByAProviderChange` 改成给 `existingProfiles` 传 `[config.id]`（它验证的行为不变，但依据从内存簿记换成了存储查询）。

- [ ] **Step 2: 跑测试确认失败**（`hasStoredProfile` 参数不存在）

- [ ] **Step 3: 实现**

`WebSessionRegistry` 的 `init` 增加一个注入（默认查真实存储），删掉 `configuredProfileIDs`：

```swift
    private let hasStoredProfile: @MainActor (UUID) async -> Bool

    init(
        makeDataStore: @escaping @MainActor (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        hasStoredProfile: @escaping @MainActor (UUID) async -> Bool = { await WebSessionRegistry.hasPersistentProfile($0) },
        removeProfile: @escaping @MainActor (UUID) async -> Void = { await WebSessionRegistry.removePersistentProfile($0) }
    ) { ... }
```

`evict` 的守卫改为：

```swift
        // Whether this config ever had a profile cannot be answered by this run's bookkeeping: the
        // provider kind may have changed, and the app may have restarted since. Ask the store.
        let hadProfile = removed != nil
            || WebSessionDescriptorFactory().descriptor(for: config.providerKind) != nil
            || await hasStoredProfile(config.id)
        guard hadProfile else {
            return
        }
        await removeProfile(config.id)
```

新增静态查询（沿用 `removePersistentProfile` 的 `withCheckedContinuation` 包装风格）：

```swift
    /// Whether a persistent profile for this id exists on disk. Unlike anything kept in memory, this
    /// answer survives an app restart.
    static func hasPersistentProfile(_ id: UUID) async -> Bool {
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        return identifiers.contains(id)
    }
```

（`allDataStoreIdentifiers` 是 macOS 14 的异步类属性，`WK_SWIFT_ASYNC_NAME(getter:)` 暴露的就是这个拼写；写完 `swift build` 会立刻告诉你拼写对不对。）

- [ ] **Step 4: 跑测试确认通过 + 全量**

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift build 2>&1 | tail -3 && swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker "$F" 2>&1 | tail -3
```
Expected: 失败集合仍只有那两个 Cursor 用例。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenHealth/WebSessionRegistry.swift Tests/TokenHealthTests/WebSessionRegistryTests.swift
git commit -m "$(cat <<'EOF'
Ask the store whether a profile exists instead of remembering it

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## 各 Provider 任务的统一形状

Task 3-7 每家都按这六步走，只有"必须做对的决定"不同。**描述符代码取自对应的研究文档，不要自己重写脚本。**

- [ ] **Step 1: 写描述符测试**（先红）

新建 `Tests/TokenHealthTests/<Provider>WebSessionDescriptorTests.swift`，照 `WebSessionDescriptorTests.swift` 的形状。每家都要有：

1. **cookie 谓词**：至少一个正例、一个反例，外加该家特有的边界（见各任务）；
2. **`encodeCredential`**：固定抽取 JSON + cookie header → 产出的串能被该家凭据类型解码回来、字段正确；
3. **`usageData(fromScriptResult:)`**：断言返回的是**整包信封**还是 **`text` 体**（各家不同，见下）；
4. **空 `text` 的负例**（仅"返回 `text`"的三家：Zhipu、Volcengine Ark、Kimi）：`{"ok":true,"status":200,"text":""}` 必须抛 `invalidResponse`；
5. **`accountLabel(fromCredential:)`**：有账号名的断言取到，没有的断言 `nil`。

- [ ] **Step 2: 跑测试确认编译失败**（类型还不存在）
- [ ] **Step 3: 实现描述符 + 凭据**：新建 `<Provider>WebSessionDescriptor.swift`；凭据结构体改为遵循 `WebSessionCredential`（保留全部既有字段，加 `storagePrefix` 与 `accountLabel`，`isEmpty`/`debugSummary` 语义不变）。
- [ ] **Step 4: 接线**：工厂加 case；Provider 兜底改成经注册表（形状照 `DeepSeekUsageProvider.swift:24-45`，**含 `TOKEN_HEALTH_FORCE_WEB_FALLBACK` 开关**，context 用 `.currentUTC()`）；`SettingsView` 的对应 case 改成注册表分派；该文件里其余的旧 `debugLog` / `LoginError` 引用按研究文档的表格迁移。

  **开关位置（Kimi 不同，见 Task 7）**：其余四家放在**内层 `do` 的第一句**（包住原生请求的那个 `do`）。判据是行为而不是行号：设了环境变量后，日志必须出现 `forced web fallback`，**并且随后真的走了 web 兜底**。放错层（例如放到"只有原生失败才进入"的函数里）会静默失效。
- [ ] **Step 5: 删除旧 controller + 更新工厂测试**：先跑 grep 门禁（该文件之外应无引用），再 `git rm`；把 `WebSessionDescriptorTests.factoryOnlyKnowsDeepSeekForNow` 改名（如 `factoryKnowsEveryMigratedProvider`）并加断言 `factory.descriptor(for: .xxx) != nil`。
- [ ] **Step 6: 编译 + 全量测试 + 提交**：失败集合必须仍只有那两个 Cursor 用例。

**统一注意：**
- **`originHost` 一律不声明**，用协议默认值（= `loginURL.host`）。各家研究文档都验证过默认值就是正确的那一个；**MiniMax 尤其危险**——把 `originHost` 改成它的跨域取数主机 `www.minimaxi.com` 会编译通过、也能跑，但每次刷新都会整页重载。
- 只迁移引用，**除决定 1 说的会话过期文案外，不改任何用户可见字符串**。

---

## Task 3: OpenCode Go

**研究文档：** `phase2-research/opencode-go.md`（形状最简单的一家）

- [ ] **Step 1: 写测试**（按统一形状的 1-5 条）——额外的边界：**cookie 谓词必须断言 `evil-opencode.ai` 与 `notopencode.ai` 被拒绝**，它是六家里唯一用精确/后缀匹配的，将来有人改成 `contains` 会悄悄放宽。
- [ ] **Step 2-4: 实现与接线**，其中：
  - 凭据**没有 `accessToken`**（只有 `cookieHeader` + `accountName`），`isEmpty` 看 cookie；`extractionScript` 是占位（`JSON.stringify({})`）。
  - `usageData` 返回**整包信封**。
  - `accountLabel` 取 `accountName`（用 `Self.nonEmpty`）。
  - **catch 里不要加 `.sessionExpired` 分支**（决定 1），让它落到 `localizedDescription`；但保留原生路径那条 `"401"` 字符串判断。
  - 旧 controller 从 `SettingsView` 的分派里移除后删除文件。
- [ ] **Step 5: 删文件 + 工厂测试**
- [ ] **Step 6: 编译 + 全量 + 提交**

```bash
git commit -m "Migrate OpenCode Go to the shared web session kernel"
```

---

## Task 4: Volcengine Ark

**研究文档：** `phase2-research/volcengine-ark.md`

- [ ] **Step 1: 写测试** —— 额外两条：csrf 的取值先后（抽取为空串时用 cookie 里的值）、空 `text` 抛 `invalidResponse`。
- [ ] **Step 2-4: 实现与接线**，其中：
  - 凭据**没有 `accessToken`**；`csrfToken` 要从 cookie header 里**按完整名字**取（`csrfToken`，不是前缀匹配），并保留 `??` 顺序（脚本取不到时给的是 `""`，`""` 要压过 header 值）。
  - `usageData` 返回 **`text`**，**校验非空**再抛 `invalidResponse`。
  - ⚠️ **`encodeCredential` 遇到抽取 JSON 解析失败时不能直接返回 nil**——旧实现只要 cookie 还在就照样导入。用 `if let object = WebSessionScriptEnvelope.object(from:)` 而**不是** `guard let`。照抄 DeepSeek 会写错这里。
  - `accountNameFromPageTitle` 把页面标题 `"火山方舟"` 映射成 `"Agent Plan"`；**这个中文字面量是数据不是注释，必须原样保留**。
  - `loginInstructions` 的等待目标是 **"Agent Plan"**（不是 Usage）。
- [ ] **Step 5: 删文件 + 工厂测试**
- [ ] **Step 6: 编译 + 全量 + 提交**

```bash
git commit -m "Migrate Volcengine Ark to the shared web session kernel"
```

---

## Task 5: Zhipu

**研究文档：** `phase2-research/zhipu.md`

- [ ] **Step 1: 写测试** —— 额外一条：`accountLabel` 必须断言为 `nil`（它只有套餐名）；空 `text` 抛 `invalidResponse`。
- [ ] **Step 2-4: 实现与接线**，其中：
  - `accessToken` 从 cookie header 按完整名字取 **`bigmodel_token_production`**（取**未解码**的原值；只有 JS 那边才 `decodeURIComponent`）。
  - `usageData` 返回 **`text`**，校验非空。
  - **`accountLabel` 返回 nil**：结构体只有 `planName`（套餐名），同套餐的两个账号会显示成同一个标签，反而误导。
  - `planName` 的组装**逐字保留**：`PlanNameExtractor().find(in: 抽取对象) ?? planNameFromPageTitle(pageTitle)`。抽取对象只有 `href`/`organizationID`/`projectID`，那个 extractor 实际总返回 nil、真正生效的是页面标题——但**不要"顺手"删掉它**。
  - 页面标题过滤里的中文 `"智谱AI开放平台"` 是数据，原样保留。
  - 抽取脚本里的 `|| ''` 让缺值编码成空串而非 null，`as? String` 照旧，否则存进 Keychain 的密文会变。
- [ ] **Step 5: 删文件 + 工厂测试**
- [ ] **Step 6: 编译 + 全量 + 提交**

```bash
git commit -m "Migrate Zhipu to the shared web session kernel"
```

---

## Task 6: MiniMax

**研究文档：** `phase2-research/minimax.md`

- [ ] **Step 1: 写测试** —— 额外两条：`groupID` 的取值先后；两个 cookie 域名（`minimaxi.com`、`minimax.io`）各自的正例。
- [ ] **Step 2-4: 实现与接线**，其中：
  - ⚠️ **`originHost` 绝不能声明**（用默认 `platform.minimaxi.com`）。取数脚本用绝对 URL 打到 `www.minimaxi.com`，但 `access_token` / `user_detail` / `minimax_current_group_id` 这些 localStorage 值只在 platform 源上。
  - `groupID` 先从抽取结果拿，拿不到才回落到 cookie header 里按完整名字取 **`minimax_group_id_v2`**；**`??` 顺序必须照抄**（脚本对缺失 cookie 给的是 `""`，`""` 压过 header 值）。不要"顺手"改成 `isEmpty` 判断。
  - `usageData` 返回**整包信封**（`parseBundle` 读的是信封自己的 `subscription`/`remains`/`credits`/`summary`）。
  - `isEmpty` 要求 token 与 cookie **都为空**才为空（与 DeepSeek 只看 token 不同），保持原样。
- [ ] **Step 5: 删文件 + 工厂测试**
- [ ] **Step 6: 编译 + 全量 + 提交**

```bash
git commit -m "Migrate MiniMax to the shared web session kernel"
```

---

## Task 7: Kimi（最复杂的一家）

**研究文档：** `phase2-research/kimi.md`

- [ ] **Step 1: 写测试** —— 额外要点：
  - **`encodeCredential` 的 fixture 必须把 `volcano-token-info` 写成嵌套的 JSON *字符串*（不是对象）**，并断言 `trafficID`/`deviceID`/`sessionID`/`planName` 都被解出来。这是那 ~110 行递归辅助代码唯一的自动化守卫，一个 `{"accessToken":…}` 的朴素 fixture 会通过却什么也没覆盖。
  - 空 `text` 抛 `invalidResponse`；`accountLabel` 断言 `nil`；cookie 谓词两个域名（`kimi`、`moonshot`）。
- [ ] **Step 2-4: 实现与接线**，其中：
  - **五个凭据字段都要活下来**：`accessToken`/`cookieHeader`/`trafficID`/`deviceID`/`sessionID`/`planName`——后三个被原生路径用作 `X-Traffic-Id` / `x-msh-device-id` / `x-msh-session-id` 请求头。
  - 描述符要**搬过来约 110 行辅助代码**（`sessionCredential(from:)`、`findVolcanoTokenInfo`、`findAccessToken(in:keyPath:)`、`parseEmbeddedJSON`），顺手丢掉没有调用方的死方法 `findAccessToken(in json: String)`。
  - `isEmpty` 是 token 与 cookie **都为空**才为空，**只有 cookie 的导入必须仍然合法**；`sessionCredential` 自己那道预判（全空抽取 → 返回 nil，但只有 trafficID 的要保留）也要照搬。
  - `usageData` 返回 **`text`**，校验非空。
  - `loginURL` 用窗口那个（`?from=kfc_overview_topbar`）。
  - **要删两个文件**：`KimiWebLoginController.swift` 与 `KimiWebUsageBridge.swift`。桥的 **9 处 `debugLog` 调用点**全在 `Providers.swift`（`phase2-research/kimi.md` §3 列了确切行号），连同 `KimiWebLoginController.swift:223` 那处 `javascriptAuthSummary` 一起迁移——两者在 `WebSessionLog` 里都已有实现。
  - Kimi 的兜底原本是**两段式**（先活跃窗口、再隐藏 WebView）：`Providers.swift:661-688` 的 `fetchConsoleUsageViaWebView` 整段按研究文档改写成一次注册表调用。注意它读 `secrets` 只是为了 `planName`，那个参数要留着。
  - ⚠️ **`TOKEN_HEALTH_FORCE_WEB_FALLBACK` 开关在 Kimi 这里没有现成的"内层 `do`"**：Kimi 的 `fetchUsage` 在 `.api` 分支里直接调 `fetchConsoleUsage`，原生请求和 web 兜底都在其中，迁移后连那个两段式 `do/catch` 也合并掉了。
    **开关必须放在"原生请求之前、且原生失败后确实会走到 web 兜底"的那一层**（即 `.api` 分支进入原生尝试之前，或 `fetchConsoleUsage` 里紧挨原生请求之前）。
    **最容易放错的位置是 `fetchConsoleUsageViaWebView` 内部——那里只在原生已经失败之后才进入，开关永远不会触发**，Kimi 的验收会静默失败。
    判据同样是行为：设了环境变量后，日志必须出现 `forced web fallback`，**且随后真的执行了 web 兜底**（Task 8 Step 4 会验证这一点）。
- [ ] **Step 5: 删两个文件 + 工厂测试**（把 `factory.descriptor(for: .kimiCode) == nil` 翻转成 `!= nil`）
- [ ] **Step 6: 编译 + 全量 + 提交**

```bash
git commit -m "Migrate Kimi to the shared web session kernel"
```

**实机验收时要特别看的一条**：旧桥的源站判断是 `host.contains("kimi.com")` 的宽松匹配，内核是**精确等于** `www.kimi.com`。如果控制台被重定向到别的主机名，内核会每次刷新都重载页面。这是唯一一处代码里没法预先保证、必须实机确认的点（Task 8 Step 4）。

---

## Task 8: 实机验收

**Files:** 无代码改动（发现问题则回到对应任务修）

五家各需要一个真实账号。**能测几家测几家**，没账号的如实记为"未验证"。

- [ ] **Step 1: 构建**

```bash
bash scripts/build-app.sh
```
先单独构建成功，再做后面的替换——**不要**把构建和替换写成一个 `&&` 之外的链条，否则构建失败也会把已装的 App 删掉。

- [ ] **Step 2: 安装并前台启动（带调试开关）**

```bash
osascript -e 'tell application "Token Health" to quit'; sleep 2; rm -rf "/Applications/Token Health.app" && cp -R ".build/app/Token Health.app" /Applications/
TOKEN_HEALTH_DEBUG=1 ".build/app/Token Health.app/Contents/MacOS/TokenHealth" &
```
末尾的 `&` 只是把进程放到后台好继续敲命令，**它的 stdout 仍然接在这个终端上**——之所以不直接用 `open`，就是因为 `open` 会把输出丢掉，而 `debugLog` 是本次验收唯一的观测手段。

- [ ] **Step 3: 每家一条，走**原生路径**先确认日常可用**：在设置里点该家的 "Login with X" → 登录 → Import Session → 菜单卡片出数字。
  Expected：状态行显示 `… web session connected: <账号>`；**Kimi 与 Zhipu 例外**（它们没有账号标识，仍显示 `stored locally`，设计如此）；OpenCode Go 的标识来自页面标题、被过滤掉时也是 `stored locally`。**如实记录每家显示的是哪一种**。

- [ ] **Step 4: 关键一步——强制走兜底，验证本次迁移的代码**

重启 App，让五家的**原生请求全部失败**，从而真正执行新的描述符代码：

```bash
osascript -e 'tell application "Token Health" to quit'; sleep 2
TOKEN_HEALTH_DEBUG=1 TOKEN_HEALTH_FORCE_WEB_FALLBACK=1 "/Applications/Token Health.app/Contents/MacOS/TokenHealth" &
```
Expected：日志里每家各出现 `forced web fallback`，随后是各自 `web fetch succeeded`，卡片仍出数字。若某家出现 `session expired`，说明该账号的站点会话已过期——重新登录一次再试（新的 per-config profile 是空的，这是升级的一次性成本）。**只有这一步能证明 cookie 抽取、用量脚本、信封解包真的生效。**
  同时观察 Kimi 的源站行为（Task 7 末尾那条）：日志里不应每次刷新都出现 `headless load …`。

- [ ] **Step 5: 多账号**（至少挑一家有第二个账号的）：再加一个账号 → 两张卡片并存 → 在其中一个上重新登录，另一张的数字不变。这是本功能的核心验收点。

- [ ] **Step 6: 删除账号确实清掉了磁盘上的 profile**

先记下删除前的目录内容：

```bash
ls -la ~/Library/WebKit/local.token-health.app/WebsiteData/
```

然后在设置里删掉其中一个账号，再跑一次同样的命令。

Expected：属于该账号的那个目录消失，其余账号的还在。
这一步不能省——`hasStoredProfile` 走的是真实 SDK（`allDataStoreIdentifiers`），而**单元测试里它是被注入替身挡掉的**，全流程只有这里能验证它。它是"删除账号即清 cookie"这条承诺的唯一实测点。

- [ ] **Step 7: 重启后仍在**：退出 App 再用 `open` 正常启动，各卡片刷新正常。

- [ ] **Step 8: 记录**：结果写进本文件末尾的"验收记录"，含未验证项与原因。

---

## Task 9: 合并评审

- [ ] **Step 1: 跑评审**：对整个阶段二范围（Task 1-7 的提交）派**两个**子代理并行评审——一个 spec 合规（sonnet），一个代码质量（opus）。两者都要喂：基线约束（测试总数与"只有两个 Cursor 失败"）、阶段二计划路径、以及"五家的差异必须与原实现逐字节等价（会话过期文案除外）"这条判定标准。
- [ ] **Step 2: 修问题**：按结论修，重复直到通过。

## Task 10: 提 PR 并合并到 main

- [ ] **Step 1: 处理工作区那两处无关改动**：`AppSupport/Info.plist`（0.8.2/18 的残留）与 `Sources/TokenHealth/StatusMenuView.swift`（去掉 `onAppear` 刷新）。开 PR 前必须决定：StatusMenuView 那处作为独立提交带上（它是有效改动），Info.plist 由 Task 11 的版本提升覆盖。
- [ ] **Step 2: 推分支**：`git push -u origin feature/multi-account-web-session`。**推之前把分支名与将要推的提交列表报给用户确认**（推送到远端是对外动作）。
- [ ] **Step 3: 建 PR**：`gh pr create --base main`，描述写明：改了什么、根因是什么（六个 Provider 共用一个 WebKit 存储，登录第二个账号会顶掉第一个）、六家迁移的结论、评审与实机验收的结果（含未验证项）、已知缺口、以及**升级后每家需重新登录一次**这个一次性成本。结尾带 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。**建 PR 前把标题与正文给用户过目。**
- [ ] **Step 4: 合并**：等用户确认后合并到 main。

## Task 11: 发新版本

- [ ] **Step 1: 版本号**：`AppSupport/Info.plist` 的 `CFBundleShortVersionString` → `0.9.0`、`CFBundleVersion` → `19`，**作为一个独立提交**（0.8.2 的 tag 指向的提交里版本号还是 0.8.1，就是因为这步没提交）。
- [ ] **Step 2: 构建 DMG**：`bash scripts/build-dmg.sh`，把产物路径与大小报给用户。
- [ ] **Step 3: 打 tag 并建 Release**：`git tag 0.9.0 && git push origin 0.9.0`，然后 `gh release create 0.9.0 "<dmg>" --title "Token Health 0.9.0" --notes "<要点>"`。
  **发布是对外动作：执行前把 tag、Release 标题与 notes 给用户确认。**
- [ ] **Step 4: 核对**：`gh release view 0.9.0` 确认 DMG 已附上，且 tag 指向的提交里版本号确实是 0.9.0。

---

## 验收记录

（执行时填写）

## 未验证 / 已知缺口

- 升级后每家 Provider 需要**重新登录一次**（新的 per-config profile 是空的），原生路径在此期间照常工作。
- Kimi 的源站判断由宽松匹配（`host.contains("kimi.com")`）收紧为精确匹配（`== "www.kimi.com"`）——若实测出现重载循环，**修法是放宽内核的匹配规则**（例如让描述符提供一个 `isOnOrigin(_:)` 判定），**不是**在描述符里覆写 `originHost`：它的用量请求是相对路径，页面必须留在 `www.kimi.com`，默认值本来就是对的。
