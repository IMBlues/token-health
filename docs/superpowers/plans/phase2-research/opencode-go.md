# Phase 2 — OpenCode Go → web session kernel: research report

Reference points used: `WebSessionDescriptor.swift`, `DeepSeekWebSessionDescriptor.swift`, `WebSessionController.swift`, `WebSessionCredential.swift`, `WebSessionError.swift`, `WebSessionLog.swift`, `OpenCodeGoWebLoginController.swift`, `OpenCodeGoWebSessionCredential.swift`, `OpenCodeGoUsageProvider.swift`, `SettingsView.swift`, `Models.swift`, plus the phase-1 plan/spec (`docs/superpowers/plans/2026-09-18-multi-account-web-session.md`, `docs/superpowers/specs/2026-09-18-multi-account-web-session-design.md`) and the phase-1 commits `e8bb064`, `83b8070`, `ddc2306`.

File placement follows the phase-1 deviation the plan records at its end ("spec §5.2 说…实际落地改成了新建文件 + 完成后删除旧文件…阶段二照此办理"): create `Sources/TokenHealth/OpenCodeGoWebSessionDescriptor.swift`, delete `Sources/TokenHealth/OpenCodeGoWebLoginController.swift`.

## 1. Descriptor

Member order mirrors `DeepSeekWebSessionDescriptor` exactly (title copy → loginURL → cookie predicate → extraction → credential → usage script → usage data → account label → static helpers).

```swift
import Foundation

@MainActor
struct OpenCodeGoWebSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "OpenCode Go"
    let loginInstructions = "Log in with GitHub or Google at opencode.ai/auth, wait for the console to load, then import."
    let missingSessionMessage = "No session found. Make sure the OpenCode console is logged in."
    let loginURL = URL(string: "https://console.opencode.ai/")!

    func shouldIncludeCookie(domain: String) -> Bool {
        domain == "opencode.ai" || domain.hasSuffix(".opencode.ai")
    }

    /// No storage extraction: this provider's credential is cookie-only, and the kernel reads the
    /// cookies itself, so there is nothing to pull from the page.
    var extractionScript: String {
        "JSON.stringify({})"
    }

    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? {
        let credential = OpenCodeGoWebSessionCredential(
            cookieHeader: cookieHeader,
            accountName: Self.accountNameFromPageTitle(pageTitle)
        )
        guard !credential.isEmpty else {
            return nil
        }
        return credential.encodedForStorage()
    }

    /// The status endpoint takes no period parameters, so the context is intentionally unused.
    func usageFetchScript(context: WebSessionFetchContext) -> String {
        """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const request = (path) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', path, false);
            xhr.withCredentials = true;
            xhr.setRequestHeader('Accept', 'application/json');
            xhr.send();
            return {
              ok: xhr.status >= 200 && xhr.status < 300,
              status: xhr.status,
              text: xhr.responseText || '',
              json: parseJSON(xhr.responseText || '')
            };
          };
          const status = request('/api/go/status');
          const session = request('/auth/session');
          const failed = !status.ok;
          return JSON.stringify({
            ok: !failed,
            status: status.status,
            text: failed ? status.text : '',
            hasSession: Boolean(session.ok && session.json && session.json.user),
            goStatus: status.json,
            session: session.ok ? session.json : null
          });
        })();
        """
    }

    /// The parser normalizes both shapes itself (`goStatus` envelope or bare GoStatus), so hand it
    /// the whole envelope exactly as the old controller did.
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        guard let data = scriptResultJSON.data(using: .utf8) else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return data
    }

    func accountLabel(fromCredential credential: String) -> String? {
        OpenCodeGoWebSessionCredential.decode(from: credential)?.accountLabel
    }

    private nonisolated static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("OpenCode") else {
            return nil
        }
        return title
    }
}
```

### Provenance of each member (line ranges in `OpenCodeGoWebLoginController.swift`)

| Member | Source | Lines |
| --- | --- | --- |
| `providerTitle` | `window.title = "Login with OpenCode Go"`; controller `LoginError` copy | 144 (title), 18–28 (error copy) |
| `loginInstructions` | status label footer string, verbatim — "Log in with GitHub or Google at opencode.ai/auth, wait for the console to load, then import." Confirmed: GitHub/Google wording is exact | 104 |
| `missingSessionMessage` | status label set on empty import, verbatim — "No session found. Make sure the OpenCode console is logged in." | 190 |
| `loginURL` | `loadConsole()` → `https://console.opencode.ai/` (trailing slash preserved) | 165–168 |
| `originHost` | **omitted.** Defaults to `loginURL.host` = `"console.opencode.ai"`, which is exactly the host the old controller loaded and the host `/api/go/status` runs on. No override needed | — |
| `shouldIncludeCookie(domain:)` | `isOpenCodeAuthCookie`, reproduced exactly | 276–279 |
| `extractionScript` | **No extraction step exists.** `importSession` (170–194) only calls `extractCookieCredential` (260–274), which reads `httpDataStore.httpCookieStore`; no `evaluateJavaScript` runs at import. Minimal no-op script supplied instead | (170–194, 260–274) |
| `encodeCredential` | `importSession` composition: fresh credential, `cookieHeader` set, `accountName = accountName ?? accountNameFromPageTitle(webView.title)` (183) → with a fresh struct this is just `accountNameFromPageTitle`; emptiness gate at 186–192 | 170–194, 281–286 |
| `usageFetchScript` | `usageFetchScript()`, transcribed verbatim; it interpolates no month/year, so the context is unused | 288–320 |
| `usageData` | `fetchUsageBundle` returns `data` — the **whole envelope** (`return data`), not `object["text"]`; the parser's comment at `OpenCodeGoUsageProvider.swift:173–175` confirms the contract | 196–216, return at 215 |
| `accountLabel` | Decodes the credential's `accountName` via the new `accountLabel` property | credential file 1–35 |

**Domain predicate verification.** `cookies.filter(Self.isOpenCodeAuthCookie)` where `isOpenCodeAuthCookie` lowercases (`cookie.domain.lowercased()`, line 277) and returns `domain == "opencode.ai" || domain.hasSuffix(".opencode.ai")`. The kernel also lowercases (`WebSessionController.swift:374`), so the double-lowering is harmless. Lookalike check: `"evil-opencode.ai"` fails both arms (its 12-char suffix is `-opencode.ai`, not `.opencode.ai`); `"notopencode.ai"` likewise (`topencode.ai`). Only `opencode.ai` itself and true subdomains (`console.opencode.ai`, `.opencode.ai`) pass. This is stricter than DeepSeek's `contains` and is the intended behavior — reproduced exactly.

## 2. Credential

Whole file, `Sources/TokenHealth/OpenCodeGoWebSessionCredential.swift`:

```swift
import Foundation

struct OpenCodeGoWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "opencode-go-web-session:"

    var cookieHeader: String?
    var accountName: String?

    var isEmpty: Bool {
        (cookieHeader ?? "").isEmpty
    }

    var accountLabel: String? {
        guard let accountName, !accountName.isEmpty else {
            return nil
        }
        return accountName
    }

    var debugSummary: String {
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "cookie=\(cookieStatus) account=\(accountStatus)"
    }
}
```

Notes:
- Field set preserved: **`cookieHeader`, `accountName` only — there is no `accessToken`** (matches spec §5.1's table).
- `encodedForStorage()` and `decode(from:)` move to the `WebSessionCredential` extension unchanged in behavior: prefix `"opencode-go-web-session:"` + JSONEncoder/JSONDecoder on the same field names in the same order → byte-identical storage format, so already-stored Keychain credentials still decode (spec §5.1: "存储格式与现有字符串完全兼容…已存凭据无需迁移").
- `isEmpty` semantics identical (`cookieHeader` empty ⇒ empty) and `debugSummary` identical text.
- Existing tests call both codec members on the concrete type (`Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift:333–360`) — the extension provides them, no test change needed.
- Plan phase-2 note (plan doc, end of file): the `guard let accountName, !accountName.isEmpty` shape will now be repeated in MiniMax, Volcengine Ark and OpenCode Go, and the plan asks for a shared `static func nonEmpty(_ value: String?) -> String?` on `WebSessionCredential` instead of copying it a third time. That helper does not exist in the repo yet (see §5, item 7).

## 3. Call sites

Every reference to `OpenCodeGoWebLoginController` outside its own file (the `.claude/worktrees/…` copies are a stale worktree snapshot, not the main tree).

| file:line | current code | proposed replacement |
| --- | --- | --- |
| `Sources/TokenHealth/SettingsView.swift:551` | `OpenCodeGoWebLoginController.shared.startLogin(completion: completion)` (case `.openCodeGo`) | `case .openCodeGo:` → same body DeepSeek uses at `SettingsView.swift:538–545`: <br>`guard let config = appState.configs.first(where: { $0.id == selectedID }),` <br>`      let controller = WebSessionRegistry.shared.controller(for: config) else {` <br>`    isWebLoginInProgress = false` <br>`    appState.lastError = WebSessionError.unsupportedProvider.localizedDescription` <br>`    return` <br>`}` <br>`controller.startLogin(completion: completion)` |
| `Sources/TokenHealth/OpenCodeGoUsageProvider.swift:28` | `OpenCodeGoWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")` | `WebSessionLog.debugLog("native request failed: \(error.localizedDescription); falling back to own session", providerTitle: Self.providerTitle)` |
| `…OpenCodeGoUsageProvider.swift:29` | `bundleData = try await OpenCodeGoWebLoginController.shared.fetchUsageBundleFromActiveSession()` | `guard let controller = WebSessionRegistry.shared.controller(for: config) else {` <br>`    throw WebSessionError.unsupportedProvider` <br>`}` <br>`bundleData = try await controller.fetchUsage(` <br>`    context: WebSessionFetchContext(year: 0, month: 0)` <br>`)` — the script reads no period (see §4/§5) |
| `…OpenCodeGoUsageProvider.swift:51` | `if let loginError = error as? OpenCodeGoWebLoginController.LoginError {` | `if let sessionError = error as? WebSessionError {` |
| `…OpenCodeGoUsageProvider.swift:53–54` | `case .missingWebView:` / `message = "OpenCode Go session is unavailable. Re-login with OpenCode Go."` | `case .unsupportedProvider:` / same message string, byte-for-byte |
| `…OpenCodeGoUsageProvider.swift:55–58` | `case let .requestFailed(text):` / `message = text.contains("401") ? "OpenCode Go session expired. Re-login with OpenCode Go." : text` | `case let .requestFailed(_, text):` / identical ternary (the kernel's `requestFailed` carries `providerTitle` + `message`) — needed to keep the **native** 401 mapping ("OpenCode Go HTTP 401: …" contains "401") |
| `…OpenCodeGoUsageProvider.swift:59` (insert before `default:`) | — | `case .sessionExpired:` / `message = "OpenCode Go session expired. Re-login with OpenCode Go."` — new case, keeps the 401/403 card text identical when the kernel throws it |
| `…OpenCodeGoUsageProvider.swift:60` | `message = loginError.localizedDescription` | `message = sessionError.localizedDescription` (renderings already match old `LoginError` for `.cancelled` and `.invalidResponse`: "OpenCode Go login cancelled", "OpenCode Go usage response was invalid") |
| `…OpenCodeGoUsageProvider.swift:85` | `OpenCodeGoWebLoginController.debugLog("API usage request endpoint=\(url.absoluteString)")` | `WebSessionLog.debugLog("API usage request endpoint=\(url.absoluteString)", providerTitle: Self.providerTitle)` |
| `…OpenCodeGoUsageProvider.swift:90` | `OpenCodeGoWebLoginController.debugLog("API usage request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")` | same call with `providerTitle: Self.providerTitle` |
| `…OpenCodeGoUsageProvider.swift:138` | `OpenCodeGoWebLoginController.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")` | same call with `providerTitle: Self.providerTitle` |
| `…OpenCodeGoUsageProvider.swift:142` | `OpenCodeGoWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")` | same call with `providerTitle: Self.providerTitle` |
| `…OpenCodeGoUsageProvider.swift:143` | `throw OpenCodeGoWebLoginController.LoginError.requestFailed("OpenCode Go HTTP \(httpResponse.statusCode): \(body.prefix(160))")` | `throw WebSessionError.requestFailed(providerTitle: Self.providerTitle, message: "OpenCode Go HTTP \(httpResponse.statusCode): \(body.prefix(160))")` |
| `…OpenCodeGoUsageProvider.swift:145` | `OpenCodeGoWebLoginController.debugLog("native request succeeded, bytes=\(data.count)")` | same call with `providerTitle: Self.providerTitle` |
| `…OpenCodeGoUsageProvider.swift:4` (add) | — | `private static let providerTitle = "OpenCode Go"` — mirrors `DeepSeekUsageProvider.swift:4`; every rendered byte above is unchanged by using `Self.providerTitle` |

All old `LoginError` renderings that must survive map cleanly: `.cancelled` → `WebSessionError.cancelled(providerTitle:)` ("OpenCode Go login cancelled"), `.invalidResponse` → `.invalidResponse(providerTitle:)` ("OpenCode Go usage response was invalid"), `.requestFailed(m)` → `.requestFailed(providerTitle:message:)` (message verbatim), `.noSessionFound` → the kernel's `missingSessionMessage` path ("No session found. Make sure the OpenCode console is logged in."), `.missingWebView` → `.unsupportedProvider` (mapped back to its old card text in the catch). The controller's `javascriptAuthSummary` (lines 83–86) is internal to the window/fetch path and is replaced by `WebSessionLog.javascriptAuthSummary` inside the kernel.

## 4. Wiring

**Factory** — `Sources/TokenHealth/WebSessionDescriptor.swift:101–109`. Before:

```swift
        switch kind {
        case .deepSeek:
            DeepSeekWebSessionDescriptor()
        case .kimiCode, .zhipuCode, .miniMax, .volcengineArk, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
```

After:

```swift
        switch kind {
        case .deepSeek:
            DeepSeekWebSessionDescriptor()
        case .openCodeGo:
            OpenCodeGoWebSessionDescriptor()
        case .kimiCode, .zhipuCode, .miniMax, .volcengineArk,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
```

**Provider fallback** — `OpenCodeGoUsageProvider.swift:27–30`. Before:

```swift
            } catch {
                OpenCodeGoWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                bundleData = try await OpenCodeGoWebLoginController.shared.fetchUsageBundleFromActiveSession()
            }
```

After (DeepSeek precedent, `DeepSeekUsageProvider.swift:34–45`):

```swift
            } catch {
                WebSessionLog.debugLog(
                    "native request failed: \(error.localizedDescription); falling back to own session",
                    providerTitle: Self.providerTitle
                )
                guard let controller = WebSessionRegistry.shared.controller(for: config) else {
                    throw WebSessionError.unsupportedProvider
                }
                // The OpenCode Go status endpoint takes no period parameters, so the context is
                // unused by its script.
                bundleData = try await controller.fetchUsage(
                    context: WebSessionFetchContext(year: 0, month: 0)
                )
            }
```

## 5. Surprises

1. **No `accessToken` — the session cookie is the whole credential.** The native request authenticates with only `request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")` plus a Safari UA and `Accept` (`OpenCodeGoUsageProvider.swift:130–136`); there is no Authorization header anywhere in the OpenCode Go path. The kernel needs no token either: its headless `WKWebView` runs on the config's own persistent profile, so `withCredentials = true` XHRs carry the cookies. Consequence: `isEmpty` keys off `cookieHeader` (unlike DeepSeek, which keys off the token), so "cookies but no account name" is a valid import — and the cookie join (`"\(name)=\(value)"` in WebKit's order, `"; "`-joined) is byte-identical between the kernel (`WebSessionController.swift:373–376`) and the old `extractCookieCredential` (line 271), so Keychain values stay equivalent.

2. **Domain predicate is the strictest of the six.** `== "opencode.ai" || hasSuffix(".opencode.ai")` correctly rejects `evil-opencode.ai` and `notopencode.ai` while accepting `console.opencode.ai` and WebKit's leading-dot `.opencode.ai` form. Nothing else in the kernel needs to know; the kernel lowercases before calling. Worth an explicit test in phase 2 (`OpenCodeGoWebSessionDescriptorTests`) since a future refactor to `contains` would silently widen it.

3. **401/403 wording changes unless the provider maps it back.** The kernel's default `isAuthenticationFailure` (401/403) throws `WebSessionError.sessionExpired`, whose copy is "OpenCode Go session expired. Log in again for this account." — *not* the old card text "OpenCode Go session expired. Re-login with OpenCode Go." The task's byte-for-byte rule therefore requires the `case .sessionExpired:` arm proposed in §3. Note the tension: spec §7's table expects the kernel's standard wording for all six providers, and the plan says the default rule is not meant to be overridden. The alternative is to accept spec §7's text and drop the old "Re-login" phrasing — a product-copy decision the migration plan should state rather than leave implicit. Also note the old `.requestFailed` "401" heuristic still has a live job on the *native* path (`"OpenCode Go HTTP 401: …"`), so that arm must stay even once the web path throws `sessionExpired`.
   Related: the envelope carries `hasSession`, but the kernel only consults `status` when `ok == false`, so a never-logged-in profile that happens to answer `/api/go/status` with a 200 (e.g. a redirect to an HTML login page) will be treated as a *successful* envelope with `goStatus: null`, and the parser will report "OpenCode Go is not subscribed. Subscribe at opencode.ai/zen first." rather than session-expired. `isAuthenticationFailure` is a protocol requirement (phase-1 review promoted it precisely so a conformer's override wins), so this is fixable through the descriptor if manual testing shows it — no kernel change required.

4. **`ProviderKind.usesSingleAPIKeyOnly` does not touch the kernel path.** It only (a) hides the API-endpoint/local-JSON/username-password fields (`SettingsView.swift:168`, `190`) and (b) keeps `defaultsToBrowserLogin` false, so `AppState.addConfig` creates OpenCode Go configs in `.api` mode (`AppState.swift:54–59`) and the "Login with …" button only appears after the user switches Auth to Login. Also `usesWebSession` stays `false` for `openCodeGo` (exactly like DeepSeek post-migration), so the success path's `if …usesWebSession { authMode = .api }` (`SettingsView.swift:518`) does not fire — Login mode survives an import, as with DeepSeek. **No `Models.swift` change is required by phase 2** unless the plan decides OpenCode Go should default to Login mode, which would be a separate product decision.

5. **Debug-only losses (accepted by precedent).** Gone with the controller: `logBrowserState`'s localStorage-keys/cookie-name script and HTTP-cookie summary (lines 234–258), the "Import Session clicked, url=…" and "import credential cookie=… account=…" lines, and the per-fetch "active WebView …" lines. Two cosmetic deltas: log prefix becomes `[TokenHealth][OpenCode Go]` (space) instead of `[TokenHealth][OpenCodeGo]`, because `providerTitle` must be the brand name; and the auth summary renders as `jsAuth Session=yes` instead of `jsAuth session=yes` (the kernel strips the `has` prefix without lowercasing — the same pre-existing delta DeepSeek accepted with `AccessToken`). Nothing user-visible.

6. **`fetchUsageBundleFromActiveSession` required an open login window; the kernel fallback does not.** The old guard threw `.missingWebView` whenever no window was open in this run; the new path works windowless from the persistent profile — and, per spec §8, will fail with session-expired exactly once after upgrading (new, empty profile; no cookie migration by design). The old `.missingWebView` card text is preserved by mapping `.unsupportedProvider` back to "OpenCode Go session is unavailable. Re-login with OpenCode Go." (that registry-nil state is now only reachable during an account deletion or if the factory forgets the provider).

7. **`usageFetchScript(context:)` demands a context the script never reads.** The provider must pass *something*; §4 proposes zeros with a comment, the alternative being current-UTC values like `DeepSeekUsagePeriod.currentUTC()`. Either is harmless today; if OpenCode Go ever grows a period-scoped query, the descriptor's unused parameter is where it plugs in. Also flag the plan's phase-2 standing instruction to hoist the repeated `accountLabel` non-empty guard into a `WebSessionCredential` extension helper (`nonEmpty(_:)`) instead of copying it a third time — the current repo has no such helper, so this migration either adds it or repeats DeepSeek's inline form.

8. **`LoginError.noSessionFound`'s long copy is retired.** Its old text ("OpenCode Go login session was not found. Log in with GitHub or Google, wait for the console to load, then click Import Session.") was shown in Settings' error line; the kernel shows `missingSessionMessage` instead — the same collapse DeepSeek's migration made, with the same in-window string preserved verbatim. Record it as an accepted delta.

9. **Test touchpoints for the plan** (beyond the report's scope but easy to miss): `Tests/TokenHealthTests/WebSessionDescriptorTests.swift:114–118` (`factoryOnlyKnowsDeepSeekForNow`) asserts `.kimiCode`/`.demo` are nil and should gain `#expect(factory.descriptor(for: .openCodeGo) != nil)`; the credential/round-trip/emptiness tests at `OpenCodeGoUsageProviderTests.swift:333–360` pass unchanged.
