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
- **每个 Provider 一个提交**，且每个提交都必须能编译、能通过测试。

## 三个需要拍板的决定（已定，各 Provider 任务照此执行）

1. **会话过期文案统一用内核的**：`"<Provider> session expired. Log in again for this account."`（`WebSessionError.sessionExpired`）。
   五家的旧实现里，只有 Kimi/Zhipu/MiniMax/Volcengine Ark 的卡片文案曾是 `"<Provider> Web fetch HTTP 401: …"`，OpenCode Go 是 `"OpenCode Go session expired. Re-login with OpenCode Go."`。
   **统一替换、不做逐字节保留**：六家一致 + "for this account" 正是本功能的多账号语义。`OpenCodeGoUsageProvider` 里那条基于 `"401"` 字符串的原生路径判断**要保留**（它管的是原生请求）。
2. **新增 `WebSessionFetchContext.currentUTC()`**：五家的脚本都不插值月份/年份，但 `fetchUsage(context:)` 必须收一个 context。与其让五家各自手搓日历（研究文档里各写了一份），不如加一个共用工厂，值取当前 UTC 年/月——将来某个脚本真要用到，值是合理的而不是 0。
3. **新增 `WebSessionCredential.nonEmpty(_:)`**：`guard let x, !x.isEmpty else { return nil }` 这段会在 MiniMax、Volcengine Ark、OpenCode Go 三家出现，抽成协议扩展里的静态方法，不要抄三遍。（阶段一计划里就预告了这件事。）

---

## Task 1: 共用小工具

**Files:**
- Modify: `Sources/TokenHealth/WebSessionDescriptor.swift`（加 `WebSessionFetchContext` 扩展）
- Modify: `Sources/TokenHealth/WebSessionCredential.swift`（加 `nonEmpty`）
- Test: `Tests/TokenHealthTests/WebSessionDescriptorTests.swift`（补用例）

- [ ] **Step 1: 写失败测试**

给 `WebSessionDescriptorTests` 加：

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

给 `WebSessionCredentialTests` 加：

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

（`DeepSeekWebSessionCredential.accountLabel` 可以顺手改成 `Self.nonEmpty(accountName)`——它的现有测试已经覆盖了 nil / 空串 / 非空三种情况，改完必须仍然全过。）

- [ ] **Step 4: 跑测试确认通过，提交**

```bash
git add Sources/TokenHealth/WebSessionDescriptor.swift Sources/TokenHealth/WebSessionCredential.swift Tests/TokenHealthTests/WebSessionDescriptorTests.swift Tests/TokenHealthTests/WebSessionCredentialTests.swift
git commit -m "$(cat <<'EOF'
Add shared fetch-context and credential helpers for phase two

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## 各 Provider 任务的统一形状

下面 Task 2-6 每家都按同样的六步走，只有"必须做对的决定"不同：

1. **写描述符测试**（TDD，先红）：新建 `Tests/TokenHealthTests/<Provider>WebSessionDescriptorTests.swift`，照 `WebSessionDescriptorTests.swift` 的形状写：
   - cookie 谓词：至少一个正例、一个反例，**外加该家特有的边界**（见各任务）；
   - `encodeCredential`：给固定的抽取 JSON + cookie header，断言产出的串能被该家凭据类型解码回来、字段正确；
   - `usageData(fromScriptResult:)`：断言返回的是**整包信封**还是 **`text` 体**（各家不同，见下）；
   - `accountLabel(fromCredential:)`：有账号名的断言取到，没有的断言 `nil`。
2. **跑测试确认编译失败**（类型还不存在）。
3. **实现**：新建描述符文件、凭据结构体改为遵循 `WebSessionCredential`。**代码取自对应的研究文档**，不要自己重写脚本。
4. **接线**：工厂加 case；Provider 的兜底改成经注册表；`SettingsView` 的对应 case 改成注册表分派；该文件里其余的旧 `debugLog` / `LoginError` 引用按研究文档的表格迁移。
5. **删除旧 controller**：先跑 grep 门禁（该文件之外应无引用），再 `git rm`；更新 `WebSessionDescriptorTests.factoryOnlyKnowsDeepSeekForNow`（改名 + 加断言 `factory.descriptor(for: .xxx) != nil`）。
6. **编译 + 全量测试 + 提交**：失败集合必须仍只有那两个 Cursor 用例。

统一注意：
- **`originHost` 一律不声明**，用协议默认值（= `loginURL.host`）。各家研究文档都验证过默认值就是正确的那一个；**MiniMax 尤其危险**——它的取数是跨域发往 `www.minimaxi.com`，把 `originHost` 改成它会导致每次刷新都整页重载。
- 兜底统一写成阶段一 `DeepSeekUsageProvider.swift:34-45` 的形状，context 用 `.currentUTC()`。
- 只迁移引用，**不改任何用户可见字符串**。

---

## Task 2: OpenCode Go

**研究文档：** `phase2-research/opencode-go.md`（最完整的一家，形状也最简单）

**必须做对的决定：**
- 凭据**没有 `accessToken`**，只有 `cookieHeader` + `accountName`；`isEmpty` 看 cookie。`extractionScript` 是没有抽取步骤的占位（`JSON.stringify({})`）。
- **cookie 谓词是六家里最严的**：`domain == "opencode.ai" || domain.hasSuffix(".opencode.ai")`。测试里必须断言 `evil-opencode.ai` 与 `notopencode.ai` **被拒绝**——将来有人图省事改成 `contains` 就会悄悄放宽。
- `usageData` 返回**整包信封**（解析器自己兼容两种形状）。
- `accountLabel` 取 `accountName`。

**Steps:** 按"统一形状"六步。用例预期 4 个。

提交 message：`Migrate OpenCode Go to the shared web session kernel`

---

## Task 3: Volcengine Ark

**研究文档：** `phase2-research/volcengine-ark.md`

**必须做对的决定：**
- 凭据**没有 `accessToken`**；`csrfToken` 要从 cookie header 里**按完整名字**取（`csrfToken`，不是前缀匹配）。
- `usageData` 返回 **`text`**，且**必须校验非空再抛 `invalidResponse`**（内核把缺失的 `text` 当空串，不是 nil）。
- **`encodeCredential` 遇到抽取 JSON 解析失败时不能直接返回 nil**——旧实现只要 cookie 还在就照样导入。用 `if let object = WebSessionScriptEnvelope.object(from:)` 而不是 `guard let`。这是照抄 DeepSeek 会写错的地方。
- `csrfToken` 的 `??` 取值顺序要保留：抽取脚本取不到时给的是 `""` 而不是 null，所以 `""` 要压过 header 里的值，与旧行为一致。
- `accountNameFromPageTitle` 里把页面标题 `"火山方舟"` 映射成 `"Agent Plan"`，**这个中文字面量是数据不是注释，必须原样保留**。
- `loginInstructions` 里的等待目标是 **"Agent Plan"**（不是 Usage）。

**Steps:** 按"统一形状"六步。用例预期 5 个（多一个 csrf 取值的先后顺序）。

提交 message：`Migrate Volcengine Ark to the shared web session kernel`

---

## Task 4: Zhipu

**研究文档：** `phase2-research/zhipu.md`

**必须做对的决定：**
- `accessToken` 从 cookie header 里按完整名字取 **`bigmodel_token_production`**（取**未解码**的原值；只有 JS 那边才 `decodeURIComponent`）。
- `usageData` 返回 **`text`**，校验非空。
- **`accountLabel` 返回 nil**：结构体里只有 `planName`（套餐名），同套餐的两个账号会显示成同一个标签，反而误导。
- `planName` 的组装要**逐字保留**：`PlanNameExtractor().find(in: 抽取对象) ?? planNameFromPageTitle(pageTitle)`。抽取对象只有 `href`/`organizationID`/`projectID`，那个 extractor 实际上总是返回 nil、真正生效的是页面标题——但**不要"顺手"把它删掉**，那是行为改变。
- 页面标题过滤里的中文 `"智谱AI开放平台"` 是数据，原样保留。
- 抽取脚本里的 `|| ''` 让缺值编码成空串而不是 null，`as? String` 要照旧，否则存进 Keychain 的密文会变。

**Steps:** 按"统一形状"六步。用例预期 5 个。

提交 message：`Migrate Zhipu to the shared web session kernel`

---

## Task 5: MiniMax

**研究文档：** `phase2-research/minimax.md`

**必须做对的决定：**
- **`originHost` 绝不能声明**（用默认 `platform.minimaxi.com`）。取数脚本用绝对 URL 打到 `www.minimaxi.com`，但 `access_token` / `user_detail` / `minimax_current_group_id` 这些 localStorage 值只在 platform 源上。声明成 www 会编译通过、也能跑，但每次刷新都会整页重载。
- `groupID` 先从抽取结果拿，拿不到才回落到 cookie header 里按完整名字取 **`minimax_group_id_v2`**；**`??` 的顺序必须照抄**（脚本对缺失的 cookie 给的是 `""` 而不是 null，所以 `""` 压过 header 值，与旧行为一致）。不要"顺手"改成 `isEmpty` 判断。
- `usageData` 返回**整包信封**（`MiniMaxUsageParser.parseBundle` 读的是信封自己的 `subscription`/`remains`/`credits`/`summary`）。
- cookie 谓词是两个域名的子串匹配（`minimaxi.com` 或 `minimax.io`）。
- `isEmpty` 要求 token 与 cookie **都为空**才为空（与 DeepSeek 只看 token 不同），保持原样。
- **已知的可接受差异**：内核的无头加载用的是不带查询串的 `loginURL`，所以脚本里 `location.search` 那条 groupID 来源不会再命中；后两条（localStorage）仍然有效。写进验收记录即可。

**Steps:** 按"统一形状"六步。用例预期 6 个（多一个 groupID 取值顺序）。

提交 message：`Migrate MiniMax to the shared web session kernel`

---

## Task 6: Kimi（最复杂的一家）

**研究文档：** `phase2-research/kimi.md`

**必须做对的决定：**
- **五个凭据字段都要活下来**：除 `accessToken`/`cookieHeader` 外还有 `trafficID`/`deviceID`/`sessionID`/`planName`，它们被原生路径用作 `X-Traffic-Id` / `x-msh-device-id` / `x-msh-session-id` 请求头以及快照的 `planName`。
- 描述符需要**搬过来约 110 行辅助代码**（`sessionCredential(from:)`、`findVolcanoTokenInfo`、`findAccessToken(in:keyPath:)`、`parseEmbeddedJSON`）——Kimi 的 token 藏在内嵌 JSON 字符串里，要递归找。研究文档里有完整代码。顺手丢掉没有调用方的死方法 `findAccessToken(in json: String)`。
- `isEmpty` 是 token 与 cookie **都为空**才为空，**只要 cookie 的导入必须仍然合法**；`sessionCredential` 自己还有一道预判（全空的抽取结果 → 返回 nil，但只有 trafficID 的要保留）。
- `usageData` 返回 **`text`**，校验非空。
- `accountLabel` 返回 **nil**（结构体没有账号名）。
- cookie 谓词是 `"kimi"` **或** `"moonshot"` 两个子串。
- `loginURL` 用窗口那个（`?from=kfc_overview_topbar`），带 `from=token_health` 的那个桥用变体随之消失。
- **要删两个文件**：`KimiWebLoginController.swift` 和 `KimiWebUsageBridge.swift`。桥的 9 处 `debugLog` 调用点全在 `Providers.swift`（研究文档列出了确切行号），连同 `KimiWebLoginController.swift:223` 那处 `javascriptAuthSummary` 一起处理——两者在 `WebSessionLog` 里都已有对应实现。
- Kimi 的兜底是**两段式**（先活跃窗口、再隐藏 WebView），迁移后合并成一次注册表调用：`Providers.swift:661-688` 的 `fetchConsoleUsageViaWebView` 整段按研究文档改写。
- **验收时要特别看的一条**：旧桥的源站判断是 `host.contains("kimi.com")` 的宽松匹配，内核是**精确等于** `www.kimi.com`。如果控制台被重定向到别的主机名，内核会每次刷新都重载页面。这是唯一需要实机确认、代码里没法预先保证的点。

**Steps:** 按"统一形状"六步，但第 5 步删两个文件、第 4 步的引用迁移表更长。用例预期 6 个。

提交 message：`Migrate Kimi to the shared web session kernel`

---

## Task 7: 实机验收

**Files:** 无代码改动（发现问题则回到对应任务修）

五家都需要各自的一个真实账号。**能测几家测几家**，没账号的如实记为"未验证"。

- [ ] **Step 1: 构建并安装**

```bash
bash scripts/build-app.sh && osascript -e 'tell application "Token Health" to quit'; sleep 2; rm -rf "/Applications/Token Health.app" && cp -R ".build/app/Token Health.app" /Applications/ && open "/Applications/Token Health.app"
```

- [ ] **Step 2: 每家一条**：在设置里点该家的 "Login with X" → 登录 → Import Session → 菜单卡片出数字。
  Expected：设置页状态行显示 `… web session connected: <账号>`（Kimi 与 Zhipu 例外——它们没有账号标识，仍显示 `stored locally`，这是设计如此）。
- [ ] **Step 3: 多账号**（至少挑一家有第二个账号的）：再加一个账号 → 两张卡片并存 → 登录其中一个，另一张的数字不变。这是本功能的核心验收点。
- [ ] **Step 4: Kimi 的源站检查**：按 Task 6 那条——观察日志里是否每次刷新都出现 `headless load …`（出现即意味着重载循环）。
- [ ] **Step 5: 重启后仍在**：退出 App 再启动，各卡片刷新正常。
- [ ] **Step 6: 记录**：结果写进本文件末尾的"验收记录"，含未验证项与原因。

---

## Task 8: 收尾——合并评审

- [ ] **Step 1: 合并评审**：对整个阶段二范围（Task 1-6 的提交）跑一次 spec 合规评审 + 一次代码质量评审（各派一个子代理，spec 用 sonnet、质量用 opus，喂清基线：测试总数与"只有两个 Cursor 失败"的约束）。
- [ ] **Step 2: 修问题**：按评审结论修，重复直到通过。

## Task 9: 提 PR 并合并到 main

- [ ] **Step 1: 处理工作区那两处无关改动**：`AppSupport/Info.plist`（0.8.2/18 的残留）与 `Sources/TokenHealth/StatusMenuView.swift`（去掉 `onAppear` 刷新）。**开 PR 前必须决定**：要么各自单独提交到本分支并在 PR 描述里说明，要么丢弃/保留在工作区。默认建议：StatusMenuView 那处作为独立提交带上（它是有效改动），Info.plist 由 Task 10 的版本提升覆盖。
- [ ] **Step 2: 推分支**：`git push -u origin feature/multi-account-web-session`
- [ ] **Step 3: 建 PR**：`gh pr create --base main`，描述里写明：做了什么、为什么（多账号会话互相顶掉的根因）、六家 Provider 的迁移、评审与实机验收的结论、已知缺口（`configuredProfileIDs` 重启后失效那条）、以及**升级后每家需要重新登录一次**这个一次性成本。结尾带 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。
- [ ] **Step 4: 合并**：等 CI（如有）与用户确认后合并到 main。

## Task 10: 发新版本

- [ ] **Step 1: 版本号**：把 `AppSupport/Info.plist` 的 `CFBundleShortVersionString` 提到 `0.9.0`、`CFBundleVersion` 提到 `19`，**作为一个独立提交**（上一个版本 0.8.2 的 tag 指向的提交里版本号还是 0.8.1，就是因为没提交这步）。
- [ ] **Step 2: 构建 DMG**：`bash scripts/build-dmg.sh`，把产物路径与大小报给用户看一眼。
- [ ] **Step 3: 打 tag 并建 Release**：`git tag 0.9.0 && git push origin 0.9.0`，然后 `gh release create 0.9.0 "<dmg path>" --title "Token Health 0.9.0" --notes "<要点：多账号、六家 Provider 迁移、升级后需重新登录一次>"`。
  **发布是对外动作，执行前把 tag、Release 标题与 notes 给用户确认。**
- [ ] **Step 4: 核对**：`gh release view 0.9.0` 确认 DMG 已附上、tag 指向的提交里版本号确实是 0.9.0。

---

## 验收记录

（执行时填写）

## 未验证 / 已知缺口

- `WebSessionRegistry.configuredProfileIDs` 只在内存里：改过 Provider 类型 + 重启 + 再删除的组合下，旧 profile 不会被清理。修法与背景见阶段一计划同名小节。
- 升级后每家 Provider 需要**重新登录一次**（新的 per-config profile 是空的），原生路径在此期间照常工作。
