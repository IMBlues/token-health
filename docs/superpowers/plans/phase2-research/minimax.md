# Phase 2 migration report: MiniMax → web session kernel

Files read: `/Users/amazingblues/SourceCodes/Local/token-health/Sources/TokenHealth/{WebSessionDescriptor,DeepSeekWebSessionDescriptor,WebSessionController,WebSessionRegistry,WebSessionError,WebSessionLog,WebSessionCredential,DeepSeekWebSessionCredential,MiniMaxWebLoginController,MiniMaxWebSessionCredential,MiniMaxUsageProvider,DeepSeekUsageProvider,SettingsView,Models}.swift`, `Tests/TokenHealthTests/WebSessionDescriptorTests.swift`, `docs/superpowers/specs/2026-09-18-multi-account-web-session-design.md`, `docs/superpowers/plans/2026-09-18-multi-account-web-session.md`, plus the phase-1 commits `63567d0`, `24051ce`, `e8bb064`, `83b8070`, `68e320e`, `ddc2306`.

## 1. Descriptor

`providerTitle` is **`MiniMax`** — the brand name used in the window title (`MiniMaxWebLoginController.swift:145`, `"Login with MiniMax"`) and all error copy (`:19-27`). All strings below are verbatim from `/Users/amazingblues/SourceCodes/Local/token-health/Sources/TokenHealth/MiniMaxWebLoginController.swift`.

New file `Sources/TokenHealth/MiniMaxWebSessionDescriptor.swift` (phase-1 deviation 1, plan line 1841-1842: new file + delete the old controller afterwards; DeepSeek did the same in `ddc2306`):

```swift
import Foundation

@MainActor
struct MiniMaxWebSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "MiniMax"
    let loginInstructions = "Log in with MiniMax Platform, wait for Usage to load, then import."
    let missingSessionMessage = "No session found. Make sure MiniMax Platform is logged in."
    let loginURL = URL(string: "https://platform.minimaxi.com/console/usage")!

    // originHost is deliberately NOT overridden. The default is loginURL.host
    // ("platform.minimaxi.com") and that is where the page must stay: the usage script reads
    // localStorage (access_token, user_detail, minimax_current_group_id) from this origin and
    // only then reaches www.minimaxi.com with absolute URLs. An override to www.minimaxi.com
    // would never match webView.url?.host and would reload the page on every fetch.

    func shouldIncludeCookie(domain: String) -> Bool {
        let lowered = domain.lowercased()
        return lowered.contains("minimaxi.com") || lowered.contains("minimax.io")
    }

    var extractionScript: String {
        """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const userDetail = parseJSON(localStorage.getItem('user_detail'));
          const persisted = parseJSON(localStorage.getItem('persist:root'));
          const auth = persisted && typeof persisted.auth === 'string' ? parseJSON(persisted.auth) : null;
          const groupID =
            new URLSearchParams(location.search).get('group_id') ||
            localStorage.getItem('minimax_current_group_id') ||
            (userDetail && Array.isArray(userDetail.groups) && userDetail.groups[0]) ||
            (userDetail && userDetail.group_id) ||
            '';
          const accountName =
            (userDetail && (userDetail.name || userDetail.user_name || userDetail.nickname || userDetail.email || userDetail.mobile)) ||
            (auth && (auth.email || auth.mobile || auth.userName)) ||
            '';
          return JSON.stringify({
            href: location.href,
            accessToken: localStorage.getItem('access_token') || '',
            groupID,
            accountName
          });
        })();
        """
    }

    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? {
        var credential = Self.storageCredential(fromExtractionJSON: extractionJSON)
            ?? MiniMaxWebSessionCredential()
        credential.cookieHeader = cookieHeader
        // The old controller read this cookie off the HTTPCookie objects; the kernel hands us a
        // joined "name=value; name=value" header, so the named value is parsed back out of it.
        credential.groupID = credential.groupID
            ?? Self.cookieValue(named: "minimax_group_id_v2", in: cookieHeader)
        credential.accountName = credential.accountName ?? Self.accountNameFromPageTitle(pageTitle)
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
          const userDetail = parseJSON(localStorage.getItem('user_detail'));
          const groupID =
            new URLSearchParams(location.search).get('group_id') ||
            localStorage.getItem('minimax_current_group_id') ||
            (userDetail && Array.isArray(userDetail.groups) && userDetail.groups[0]) ||
            (userDetail && userDetail.group_id) ||
            '';
          const accessToken = localStorage.getItem('access_token') || '';
          const request = (path) => {
            const xhr = new XMLHttpRequest();
            const url = path.startsWith('http') ? path : `https://www.minimaxi.com${path}`;
            xhr.open('GET', url, false);
            xhr.withCredentials = true;
            xhr.setRequestHeader('Accept', 'application/json, text/plain, */*');
            if (groupID) xhr.setRequestHeader('X-Group-Id', groupID);
            xhr.send();
            return {
              ok: xhr.status >= 200 && xhr.status < 300,
              status: xhr.status,
              text: xhr.responseText || '',
              json: parseJSON(xhr.responseText || '')
            };
          };
          const subscription = request('/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=1&resource_package_type=7');
          const remains = request('/v1/api/openplatform/coding_plan/remains');
          const credits = request('/backend/account/token_plan_credit');
          const summary = request('/backend/account/token_plan/usage_summary');
          const firstFailure = [subscription, remains, credits, summary].find(item => !item.ok);
          return JSON.stringify({
            ok: !firstFailure,
            status: firstFailure ? firstFailure.status : 200,
            text: firstFailure ? firstFailure.text : '',
            hasAccessToken: Boolean(accessToken),
            hasGroupID: Boolean(groupID),
            subscription: subscription.json,
            remains: remains.json,
            credits: credits.json,
            summary: summary.json
          });
        })();
        """
    }

    /// MiniMax, like DeepSeek, hands the whole envelope to its parser: `MiniMaxUsageParser
    /// .parseBundle` reads the envelope's own top-level keys (subscription/remains/credits/summary).
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        guard let data = scriptResultJSON.data(using: .utf8) else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return data
    }

    func accountLabel(fromCredential credential: String) -> String? {
        MiniMaxWebSessionCredential.decode(from: credential)?.accountLabel
    }

    /// The extraction script always emits those four keys, with `""` for a value it could not
    /// find, so `nil` here means only one thing: the script result was not a JSON object at all.
    /// That matches the old controller, which fell through to the cookie/paper-title fallbacks
    /// exactly when the extraction produced no JSON.
    private nonisolated static func storageCredential(
        fromExtractionJSON extractionJSON: String
    ) -> MiniMaxWebSessionCredential? {
        guard let data = extractionJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return MiniMaxWebSessionCredential(
            accessToken: object["accessToken"] as? String,
            cookieHeader: nil,
            groupID: object["groupID"] as? String,
            accountName: object["accountName"] as? String
        )
    }

    /// Pulls one named cookie out of the kernel's joined header. The match is on the full name
    /// before the first `=`, never on a prefix: `minimax_group_id_v2` and a hypothetical
    /// `minimax_group_id_v2_x` are different cookies, and only the first match (in WebKit's own
    /// order, which the join preserves) corresponds to the old `first(where:)` lookup.
    private nonisolated static func cookieValue(named name: String, in cookieHeader: String?) -> String? {
        guard let cookieHeader else {
            return nil
        }
        for pair in cookieHeader.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separatorIndex = trimmed.firstIndex(of: "=") else {
                continue
            }
            let cookieName = String(trimmed[trimmed.startIndex..<separatorIndex])
            guard cookieName == name else {
                continue
            }
            return String(trimmed[trimmed.index(after: separatorIndex)...])
        }
        return nil
    }

    private nonisolated static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("MiniMax") else {
            return nil
        }
        return title
    }
}
```

Member order matches `DeepSeekWebSessionDescriptor` exactly: `providerTitle`, `loginInstructions`, `missingSessionMessage`, `loginURL`, `shouldIncludeCookie`, `extractionScript`, `encodeCredential`, `usageFetchScript`, `usageData`, `accountLabel`, then the nonisolated static helpers. `originHost` is intentionally absent — it defaults to `loginURL.host` = `platform.minimaxi.com` (see section 5).

**Hosts, verified from the code.** The login page is `https://platform.minimaxi.com/console/usage` (`MiniMaxWebLoginController.swift:167`, `loadMiniMaxUsage()`), and every usage request is rewritten to an **absolute URL on a different host**: `:356` is `` const url = path.startsWith('http') ? path : `https://www.minimaxi.com${path}`; `` and all four call sites (`:369-372`) pass `"/…"` paths, so all four XHRs hit `https://www.minimaxi.com/…`. So yes — the script issues absolute-URL, cross-origin requests that the kernel's same-origin page load does not cover. `originHost` must therefore be left at its default (`platform.minimaxi.com`), not `www.minimaxi.com`: the script needs the platform origin for its `localStorage` reads, and the kernel's guard compares `webView.url?.host` (always `platform.minimaxi.com` after loading `loginURL`) against `originHost`, so an override would make every fallback reload the page and never short-circuit. The cross-origin fetch is a property of the script, not of the kernel, so **the descriptor expresses the current behaviour fully and no kernel change is needed** — details in section 5.

`shouldIncludeCookie`: the old predicate is `MiniMaxWebLoginController.swift:328-331` (`domain.lowercased().contains("minimaxi.com") || domain.lowercased().contains("minimax.io")`). Note for provenance: the design doc calls these "suffixes" (spec line 134), but the code is a substring `matches` — `evilminimaxi.com.example` would match — and that is preserved deliberately. The kernel already lowercases (`WebSessionController.swift:374`); the helper lowercases again so it is idempotent and directly unit-testable (the DeepSeek test asserts `descriptor.shouldIncludeCookie(domain: "DEEPSEEK.COM")`, `WebSessionDescriptorTests.swift:14`).

**The two-value cookie extraction.** In the old controller the cookie pass returned a pair (`:311-326`): the joined header **and** one named cookie value, `minimaxCookies.first(where: { $0.name == "minimax_group_id_v2" })?.value` (`:323`). The cookie name is **`minimax_group_id_v2`**. `encodeCredential` recovers it with `Self.cookieValue(named:in:)` above. Behaviour is reproduced exactly, including the non-obvious part of the old composition (`:184-187`): because the extraction script always emits `"groupID"` (as `""` when empty), `credential.groupID` is non-nil whenever the JSON parsed, so `??` only consults the cookie when the extraction produced no JSON at all — `Self.storageCredential(...) ?? MiniMaxWebSessionCredential()` then `?? cookieValue(...)` has exactly the same reachability. Same for `accountName ?? accountNameFromPageTitle(pageTitle)`.

## 2. Credential

`/Users/amazingblues/SourceCodes/Local/token-health/Sources/TokenHealth/MiniMaxWebSessionCredential.swift`, whole file in its new form (mirrors `DeepSeekWebSessionCredential.swift:1-27`; the `encodedForStorage()`/`decode(from:)` bodies move to the protocol extension at `WebSessionCredential.swift:18-37`):

```swift
import Foundation

struct MiniMaxWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "minimax-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var groupID: String?
    var accountName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
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
        let groupStatus = (groupID ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) group=\(groupStatus) account=\(accountStatus)"
    }
}
```

- `isEmpty` and `debugSummary` are unchanged byte-for-byte; note MiniMax's `isEmpty` requires **both** token and cookie empty (unlike DeepSeek's token-only rule) — keep it.
- `accountLabel` maps from `accountName` (spec §5.1 table, line 103). It must be **computed** so the encoded JSON keeps its four keys and existing Keychain values stay decodable (spec line 109: no migration of stored credentials).
- The plan (line 1826-1828) asks for the `guard let x, !x.isEmpty` guard to be hoisted into a `WebSessionCredential` extension helper (`static func nonEmpty(_ value: String?) -> String?`) before it is triplicated by MiniMax/Volcengine Ark/OpenCode Go. That is a fair option; shown inline above to match the DeepSeek file's shape, which is what "same shape" asks for.

## 3. Call sites

Every reference outside `MiniMaxWebLoginController.swift` in the main checkout. (A second, stale copy of these two files exists under `/Users/amazingblues/SourceCodes/Local/token-health/.claude/worktrees/strange-jemison-f47458/` — a git worktree, not the branch under migration; ignore it.)

| file:line | current | proposed replacement |
| --- | --- | --- |
| `Sources/TokenHealth/SettingsView.swift:547` | `MiniMaxWebLoginController.shared.startLogin(completion: completion)` | registry dispatch — see block A |
| `Sources/TokenHealth/MiniMaxUsageProvider.swift:16` | `MiniMaxWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")` | see block B (log only; wording follows the DeepSeek precedent) |
| `Sources/TokenHealth/MiniMaxUsageProvider.swift:17` | `bundleData = try await MiniMaxWebLoginController.shared.fetchUsageBundleFromActiveSession()` | see block B |
| `Sources/TokenHealth/MiniMaxUsageProvider.swift:101` | `MiniMaxWebLoginController.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")` | `WebSessionLog.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)", providerTitle: Self.providerTitle)` |
| `Sources/TokenHealth/MiniMaxUsageProvider.swift:105` | `MiniMaxWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")` | `WebSessionLog.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))", providerTitle: Self.providerTitle)` |
| `Sources/TokenHealth/MiniMaxUsageProvider.swift:106` | `throw MiniMaxWebLoginController.LoginError.requestFailed("MiniMax HTTP \(httpResponse.statusCode): \(body.prefix(160))")` | `throw WebSessionError.requestFailed(providerTitle: Self.providerTitle, message: "MiniMax HTTP \(httpResponse.statusCode): \(body.prefix(160))")` |
| `Sources/TokenHealth/MiniMaxUsageProvider.swift:108` | `MiniMaxWebLoginController.debugLog("native request succeeded, path=\(path), bytes=\(data.count)")` | `WebSessionLog.debugLog("native request succeeded, path=\(path), bytes=\(data.count)", providerTitle: Self.providerTitle)` |

`Self.providerTitle` is the shape the DeepSeek file ended at; add `private static let providerTitle = "MiniMax"` next to `private let platformHost` (`MiniMaxUsageProvider.swift:4-5`), introduced in `68e320e`.

**Block A — `SettingsView.swift:546-547`** (byte-identical to the `.deepSeek` case at `:538-545`, which `83b8070` produced):

```swift
        case .miniMax:
            guard let config = appState.configs.first(where: { $0.id == selectedID }),
                  let controller = WebSessionRegistry.shared.controller(for: config) else {
                isWebLoginInProgress = false
                appState.lastError = WebSessionError.unsupportedProvider.localizedDescription
                return
            }
            controller.startLogin(completion: completion)
```

**Block B — `MiniMaxUsageProvider.swift:11-18`**, before (current):

```swift
        do {
            let bundleData: Data
            do {
                bundleData = try await fetchUsageBundle(session: session)
            } catch {
                MiniMaxWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                bundleData = try await MiniMaxWebLoginController.shared.fetchUsageBundleFromActiveSession()
            }
```

after (the DeepSeek file's current shape, `DeepSeekUsageProvider.swift:24-45`):

```swift
        do {
            let bundleData: Data
            do {
                // Debug-only escape hatch for exercising the web-session fallback path; there is
                // no real native request behind this failure.
                if ProcessInfo.processInfo.environment["TOKEN_HEALTH_FORCE_WEB_FALLBACK"] == "1" {
                    WebSessionLog.debugLog("forced web fallback", providerTitle: Self.providerTitle)
                    throw WebSessionError.requestFailed(providerTitle: Self.providerTitle, message: "forced fallback")
                }
                bundleData = try await fetchUsageBundle(session: session)
            } catch {
                WebSessionLog.debugLog(
                    "native request failed: \(error.localizedDescription); falling back to own session",
                    providerTitle: Self.providerTitle
                )
                guard let controller = await WebSessionRegistry.shared.controller(for: config) else {
                    throw WebSessionError.unsupportedProvider
                }
                bundleData = try await controller.fetchUsage(context: Self.currentFetchContext())
            }
```

with, next to the other helpers:

```swift
    /// MiniMax's usage script does not interpolate the period, so this value exists only to
    /// satisfy `fetchUsage(context:)`; it is taken from the same Asia/Shanghai calendar the
    /// parser uses to define "today".
    private static func currentFetchContext(now: Date = Date()) -> WebSessionFetchContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let components = calendar.dateComponents([.year, .month], from: now)
        return WebSessionFetchContext(year: components.year ?? 0, month: components.month ?? 0)
    }
```

The `TOKEN_HEALTH_FORCE_WEB_FALLBACK` branch is not required by the kernel, but it is part of the DeepSeek precedent (`e8bb064`) and is the only way to trigger the fallback for acceptance; keep or drop deliberately.

**Error-text mapping** (all strings below are what the user/`lastError` sees; every replacement is byte-for-byte identical):

| old (`LoginError`, `MiniMaxWebLoginController.swift:16-29`) | new | text |
| --- | --- | --- |
| `.cancelled` | `WebSessionError.cancelled(providerTitle:)` (kernel) | `MiniMax login cancelled` — unchanged |
| `.noSessionFound` | `WebSessionError.requestFailed(providerTitle:message: descriptor.missingSessionMessage)` (kernel) | changes: `"MiniMax login session was not found. Log in first, wait for the usage page to load, then click Import Session."` → `"No session found. Make sure MiniMax Platform is logged in."` (see section 5) |
| `.missingWebView` | `WebSessionError.unsupportedProvider` (Block B) | changes: `"MiniMax WebView session is unavailable"` → `"This provider does not support web login"`; unreachable after wiring |
| `.invalidResponse` | `WebSessionError.invalidResponse(providerTitle:)` (kernel) | `MiniMax usage response was invalid` — unchanged |
| `.requestFailed(msg)` from the web fetch | `WebSessionError.requestFailed` (kernel builds `"MiniMax Web fetch HTTP \(status): \(text.prefix(160))"`, controller line 144) | unchanged for non-401/403; **401/403 now becomes `MiniMax session expired. Log in again for this account.`** (kernel default `isAuthenticationFailure`) |
| `.requestFailed(msg)` from the native path | `WebSessionError.requestFailed` (line 106 row above) | `MiniMax HTTP \(code): …` — unchanged |

## 4. Wiring

`WebSessionDescriptorFactory.descriptor(for:)` in `/Users/amazingblues/SourceCodes/Local/token-health/Sources/TokenHealth/WebSessionDescriptor.swift:100-110` — add one case and remove `.miniMax` from the nil list:

```swift
    func descriptor(for kind: ProviderKind) -> (any WebSessionDescriptor)? {
        switch kind {
        case .deepSeek:
            DeepSeekWebSessionDescriptor()
        case .miniMax:
            MiniMaxWebSessionDescriptor()
        case .kimiCode, .zhipuCode, .volcengineArk, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
    }
```

`MiniMaxUsageProvider.swift` fallback call: the before/after is Block B in section 3 (line 17 becomes the `guard let controller … fetchUsage(context:)` pair). No other provider-side change is needed: `ProviderKind.usesWebSession` already includes `.miniMax` (`Models.swift:54`), and `SettingsView`'s account-label plumbing (`:431-438`, `:557-566`) picks the descriptor up from the factory automatically, so the settings row will start showing `MiniMax web session connected: <accountName>` once `accountLabel(fromCredential:)` exists.

## 5. Surprises

1. **The cross-origin fetch is expressible — no kernel change is needed — but `originHost` must be omitted, not "corrected".** `platform.minimaxi.com` (page, `loginURL`, and `localStorage` origin) and `www.minimaxi.com` (all four XHR targets, controller `:356`) are different hosts. The kernel's `ensureOriginLoaded` (`WebSessionController.swift:191-216`) only loads and checks the *top-level* page, so the cross-origin XHRs run exactly as they do today from the platform page. Setting `originHost = "www.minimaxi.com"` compiles and still "works", which is the trap: the guard `webView.url?.host != descriptor.originHost` would never match, so every `fetchUsage` would perform a full 20-second-budget page reload and never take the fast path. The design's worry is real but points the other way — the kernel must *never* be asked to put the page on `www.minimaxi.com`, because the script's `access_token` / `user_detail` / `minimax_current_group_id` reads come from `platform`'s `localStorage`. Leaving `originHost` at the protocol default (as DeepSeek does) is the correct and complete expression.
2. **`MiniMaxUsageParser` reads the envelope, not `text`.** `parseBundle` (`MiniMaxUsageProvider.swift:157-160`) reads the envelope's own `subscription` / `remains` / `credits` / `summary` keys, so `usageData(fromScriptResult:)` must return the whole envelope as `Data` — the old `fetchUsageBundle` did exactly that (`:206-220`). Returning `envelope.text` (the Kimi/Zhipu/Volcengine-Ark rule, spec line 149) would hand the parser `"…"` and fail with "Expected a JSON object". Also note `WebSessionScriptEnvelope.text` is `""`-when-missing, not nil — irrelevant here only because MiniMax uses the whole envelope.
3. **The two-value cookie extraction has a reachability quirk worth preserving rather than "fixing".** `credential.groupID ?? cookieGroupID` only reaches the `minimax_group_id_v2` cookie when the extraction returned no JSON at all, because the script always emits `groupID` as a string (`""` when not found, so `??` never fires). Copying the composition verbatim (as above) keeps the quirk; a "cleaner" `if credential.groupID.isEmpty { credential.groupID = cookie }` would silently change behaviour for an empty-but-present `groupID`.
4. **Extra credential fields survive untouched, but the settings label is new.** `groupID` is load-bearing twice over: the native path sends it as `X-Group-Id` (`:130-132`) and the JS path sets the same header (`:360`). It is not used for `accountLabel` — that is `accountName` (spec line 103). Adding `accountLabel` changes what Settings shows for existing credentials (label appears where "web session stored locally" used to be) — expected, that's the phase-1 feature.
5. **Two user-visible error strings change, both by precedent.** (a) Import-failure copy: the old import-failed path surfaced `LoginError.noSessionFound` ("MiniMax login session was not found. …click Import Session."), while the footer said "No session found. Make sure MiniMax Platform is logged in."; the kernel's `missingSessionMessage` keeps only the footer text. This is exactly what phase 1 did for DeepSeek (its deleted controller had the same two strings, checked in `ddc2306^`), so it is precedented — but it is a change, and it needs a byte-exact copy of the footer string, not the enum string. (b) 401/403 now throws `sessionExpired` ("MiniMax session expired. Log in again for this account.") instead of `requestFailed("MiniMax Web fetch HTTP 401: …")`. That is the kernel's default `isAuthenticationFailure` (`WebSessionDescriptor.swift:87-93`), which the spec deliberately does not want descriptors to override (spec lines 159-161); the old MiniMax controller had no such distinction, so this is the one place the port intentionally improves on the old behaviour.
6. **`javascriptAuthSummary` degrades slightly, logs only.** The kernel's generic version (`WebSessionLog.swift:19-29`) prints `jsAuth AccessToken=yes GroupID=yes` where the old one printed `jsAuth accessToken=yes group=yes` (`:83-87`) — key names are derived by `dropFirst(3)` from `hasAccessToken`/`hasGroupID`. Debug output only, no action needed.
7. **One real behavioural improvement (and one small loss).** The old fallback required the login *window* to exist in this app run (`guard let windowController else { throw .missingWebView }`, `:57-60`); the kernel works headlessly off the persisted profile, so `missingWebView` disappears (mapped to `unsupportedProvider`, only reachable pre-wiring). The small loss: the kernel loads the bare `loginURL` with no query string, so the script's first `groupID` source — `new URLSearchParams(location.search).get('group_id')` (`:348`) — can no longer fire in the headless WebView. The `minimax_current_group_id` localStorage and `user_detail` fallbacks behind it are profile-local and unchanged, so this is low risk, but it is a genuine, silent difference from the old window-based fetch.
8. **`planName` derivation is untouched and unrelated.** `planName: result.planName ?? session.accountName` (`MiniMaxUsageProvider.swift:25`) still reads the parser's subscription title first, with the stored `accountName` as fallback; the migration does not touch it. `accountName` therefore serves two roles (menu plan fallback + settings label) — worth remembering if the label and the plan ever look wrong together.
9. **Test fallout, all benign.** `WebSessionDescriptorTests.factoryOnlyKnowsDeepSeekForNow` (`:113-119`) asserts `deepSeek != nil`, `kimiCode == nil`, `demo == nil` — adding `.miniMax` does not fail it, but its name goes stale, and spec §10 wants a MiniMax `shouldIncludeCookie` fixture pair (`minimaxi.com`, `minimax.io`) plus an `encodeCredential` round-trip that asserts `groupID` is taken from the extraction first and from the cookie second. Separately, `Tests/TokenHealthTests/OpenCodeGoUsageProviderTests.swift:346` uses the literal `"minimax-web-session:{}"` as a *foreign-prefix* fixture — it asserts OpenCode Go rejects it, so it neither constrains nor breaks MiniMax, but it does mean the `minimax-web-session:` prefix string is now load-bearing in two test files.
10. **Nothing in `AppState`, `Providers.swift` (`:20-21` factory), `UsageReporter` or the menu touches the controller**, so deleting `MiniMaxWebLoginController.swift` after the call sites move is safe; the only thing lost with it is its now-unused `javascriptAuthSummary` / `debugLog` statics (the kernel's `WebSessionLog` covers both).

**Provenance (line ranges transcribed into the descriptor).** Extraction script `MiniMaxWebLoginController.swift:266-291`; usage script `:341-386` (absolute-URL rewrite at `:356`, endpoints `:369-372`); cookie predicate `:328-331`; cookie header join and named-cookie read `:322-323`; import composition `:184-196` (status strings `:191`, `:194`); storage-credential build `:293-308`; page-title fallback `:333-338`; login URL `:166-169`; window title and footer text `:105`, `:145`; envelope unwrap and whole-envelope return `:201-221`; `LoginError` copy `:16-29`. DeepSeek reference: descriptor `/Users/amazingblues/SourceCodes/Local/token-health/Sources/TokenHealth/DeepSeekWebSessionDescriptor.swift:1-177`, call-site precedent `Sources/TokenHealth/DeepSeekUsageProvider.swift:24-45`, migrations `83b8070` (SettingsView), `e8bb064` + `68e320e` (provider), `ddc2306` (controller deletion).
