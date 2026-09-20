# Volcengine Ark → Web Session Kernel: Migration Research

Read-only research on `feature/multi-account-web-session`. All code below is transcribed from the files at their current HEAD state; no files were modified.

## 1. Descriptor

New file `Sources/TokenHealth/VolcengineArkWebSessionDescriptor.swift` (per the phase-2 note in `docs/superpowers/plans/2026-09-18-multi-account-web-session.md` ~line 1843: new file, old controller file deleted after). Member order matches `DeepSeekWebSessionDescriptor`.

```swift
import Foundation

@MainActor
struct VolcengineArkWebSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "Volcengine Ark"
    let loginInstructions = "Log in with Volcengine Ark, wait for Agent Plan to load, then import."
    let missingSessionMessage = "No session found. Make sure Volcengine Ark is logged in."
    let loginURL = URL(string: "https://console.volcengine.com/ark/region:cn-beijing/subscription/agent-plan")!
    // originHost is deliberately omitted: the protocol default is `loginURL.host`, i.e.
    // "console.volcengine.com" — the same origin the old login window's WebView was on when it ran
    // the AFP fetch, so no override is needed.

    func shouldIncludeCookie(domain: String) -> Bool {
        domain.lowercased().contains("volcengine")
    }

    var extractionScript: String {
        """
        (() => {
          const cookieValue = (name) => {
            const prefix = `${name}=`;
            const item = document.cookie.split('; ').find(v => v.startsWith(prefix));
            return item ? decodeURIComponent(item.slice(prefix.length)) : '';
          };
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const userInfo = (window.__PRELOAD_DATA__ && window.__PRELOAD_DATA__.userInfo) || {};
          const accountName =
            userInfo.AccountName ||
            userInfo.UserName ||
            userInfo.Email ||
            userInfo.Mobile ||
            document.title ||
            '';
          return JSON.stringify({
            href: location.href,
            csrfToken: cookieValue('csrfToken'),
            accountName,
            localStorageKeys: Object.keys(localStorage),
            sessionStorageKeys: Object.keys(sessionStorage),
            consoleUser: parseJSON(localStorage.getItem('console_user_info')) || null
          });
        })();
        """
    }

    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? {
        var credential = VolcengineArkWebSessionCredential()
        if let object = WebSessionScriptEnvelope.object(from: extractionJSON) {
            credential.csrfToken = object["csrfToken"] as? String
            credential.accountName = object["accountName"] as? String
        }
        credential.cookieHeader = cookieHeader
        // The kernel hands over a joined "name=value; name=value" header instead of the cookie
        // store, so the named value the old controller read from getAllCookies ("csrfToken") is
        // pulled back out of the header. `??` is kept in the old order: the extraction script
        // yields "" (not null) when the cookie is missing, and "" must win over the header value,
        // exactly as it did over the cookie-store value.
        credential.csrfToken = credential.csrfToken ?? Self.cookieValue(named: "csrfToken", in: cookieHeader)
        credential.accountName = credential.accountName ?? Self.accountNameFromPageTitle(pageTitle)
        guard !credential.isEmpty else {
            return nil
        }
        return credential.encodedForStorage()
    }

    func usageFetchScript(context: WebSessionFetchContext) -> String {
        // The AFP endpoint takes an empty POST body and is not month-scoped, so the script is
        // unchanged and the context is unused today.
        """
        (() => {
          const cookieValue = (name) => {
            const prefix = `${name}=`;
            const item = document.cookie.split('; ').find(v => v.startsWith(prefix));
            return item ? decodeURIComponent(item.slice(prefix.length)) : '';
          };
          const csrf = cookieValue('csrfToken');
          const xhr = new XMLHttpRequest();
          xhr.open('POST', '/api/top/ark/cn-beijing/2024-01-01/GetAgentPlanAFPUsage?', false);
          xhr.withCredentials = true;
          xhr.setRequestHeader('Accept', 'application/json, text/plain, */*');
          xhr.setRequestHeader('Content-Type', 'application/json');
          xhr.setRequestHeader('Accept-Language', navigator.language || 'zh-CN');
          if (csrf) xhr.setRequestHeader('X-Csrf-Token', csrf);
          xhr.send(JSON.stringify({}));
          return JSON.stringify({
            ok: xhr.status >= 200 && xhr.status < 300,
            status: xhr.status,
            hasCSRF: Boolean(csrf),
            text: xhr.responseText || ''
          });
        })();
        """
    }

    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        guard let object = WebSessionScriptEnvelope.object(from: scriptResultJSON),
              let text = object["text"] as? String,
              !text.isEmpty,
              let data = text.data(using: .utf8) else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return data
    }

    func accountLabel(fromCredential credential: String) -> String? {
        VolcengineArkWebSessionCredential.decode(from: credential)?.accountLabel
    }

    /// Matches the cookie name before the first "=" — never a prefix, so a "csrfTokenV2" cookie
    /// cannot satisfy a lookup for "csrfToken". The kernel joins with "; ", unencoded.
    private nonisolated static func cookieValue(named name: String, in cookieHeader: String?) -> String? {
        guard let cookieHeader else {
            return nil
        }
        for pair in cookieHeader.components(separatedBy: "; ") {
            guard let separator = pair.firstIndex(of: "=") else {
                continue
            }
            let candidateName = String(pair[..<separator])
            if candidateName == name {
                return String(pair[pair.index(after: separator)...])
            }
        }
        return nil
    }

    /// Copied verbatim from the old controller (lines 312-317): the console's Chinese page title
    /// is mapped to "Agent Plan"; anything else is used untrimmed. The 火山方舟 literal is data,
    /// not a comment — it must survive.
    private nonisolated static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return title == "火山方舟" ? "Agent Plan" : title
    }
}
```

Provenance and decision notes, member by member:

- `providerTitle` — the old window title is `"Login with Volcengine Ark"` (line 144) and every error string is prefixed `"Volcengine Ark …"` (lines 19, 21, 23, 25). Confirmed "Volcengine Ark", not `ProviderKind.title` (which happens to be the same string — `Models.swift:29`).
- `loginInstructions` — verbatim from the status-label initializer, line 104: `"Log in with Volcengine Ark, wait for Agent Plan to load, then import."` **Verified: it says "Agent Plan", not "Usage."**
- `missingSessionMessage` — verbatim from the import-failure status string, line 193: `"No session found. Make sure Volcengine Ark is logged in."` (Not from `LoginError.noSessionFound`, line 21 — see Surprises.)
- `loginURL` — verbatim from `loadAgentPlan()`, line 166.
- `originHost` — **omitted**; the protocol default (WebSessionDescriptor.swift:80-83) returns `loginURL.host` = `"console.volcengine.com"`, which is where the old window's AFP XHR ran from. No override needed.
- `shouldIncludeCookie` — reproduces `isVolcengineCookie` (lines 307-310): lowercase the domain, substring-match `"volcengine"`. The kernel already lowercases before calling (`WebSessionController.swift:374`); the extra `.lowercased()` matches DeepSeek's shape and is harmless. The same predicate served both the import filter (line 288) and the debug cookie summary (line 258).
- `extractionScript` — verbatim from `sessionExtractionScript()` body, **lines 320-347** (declaration at 319). Not `afpUsageFetchScript()`.
- `encodeCredential` — composition reproduced from `importSession`, **lines 183-191** (with `extractStorageCredential` lines 268-284 and `extractCookieCredential` lines 286-305). The named cookie is **`csrfToken`** (extracted at line 302 as `volcCookies.first { $0.name == "csrfToken" }?.value`; the kernel's header now supplies it, matched on the full name before the first `=` per the protocol doc at WebSessionDescriptor.swift:60-64). Preserved subtleties: (a) the old code kept the cookie-store fallback only for the case where the storage JSON failed to parse (`storageCredential == nil`), because the script returns `""` rather than `null` for a missing cookie, and `"" ?? x == ""`; the `??` chain above preserves exactly that. (b) On parse failure the old code still imported when cookies existed — the descriptor must **not** early-return `nil` for bad `extractionJSON` (this is the one structural divergence from DeepSeek's `encodeCredential`, which returns nil for non-JSON).
- `usageFetchScript` — verbatim from `afpUsageFetchScript()` body, **lines 351-374** (declaration at 350). It does **not** interpolate a month/year, so `context` is ignored.
- `usageData` — the old `fetchAFPUsage` returns the envelope's **`text` field**, not the whole envelope: lines 205-209 unwrap `object["text"] as? String` and lines 219-222 return `text.data(using: .utf8)`. (DeepSeek is the opposite — its descriptor returns the whole envelope.) The guard here throws the same `WebSessionError.invalidResponse` whose text equals the old `LoginError.invalidResponse` message byte-for-byte. The extra `!text.isEmpty` check follows the phase-2 note at plan-doc line 1837 ("必须校验非空并抛 invalidResponse"); the one corner where it differs from today's code is flagged in Surprises.
- `accountLabel(fromCredential:)` — same shape as DeepSeek's: decode and return `accountLabel`.
- `isAuthenticationFailure` — not implemented; the kernel default (401/403 → session expired) applies. See Surprises.

## 2. Credential

Whole file, `Sources/TokenHealth/VolcengineArkWebSessionCredential.swift` (all fields preserved, in existing order; no `accessToken`; `encodedForStorage()`/`decode(from:)` are dropped because the protocol extension supplies them — the old prefix was checked by hand at line 28 and prepended at line 24, and the extension reproduces both exactly):

```swift
import Foundation

struct VolcengineArkWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "volcengine-ark-web-session:"

    var cookieHeader: String?
    var csrfToken: String?
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
        let csrfStatus = (csrfToken ?? "").isEmpty ? "no" : "yes"
        let accountStatus = (accountName ?? "").isEmpty ? "no" : "yes"
        return "cookie=\(cookieStatus) csrf=\(csrfStatus) account=\(accountStatus)"
    }
}
```

Unchanged semantics: `isEmpty` is cookie-only (identical to old lines 8-10); `debugSummary` prints the same three flags in the same order as old lines 12-17. The serialized JSON keys (`cookieHeader`, `csrfToken`, `accountName`) are untouched, so existing Keychain values still decode; the protocol extension's `encodedForStorage` emits `"volcengine-ark-web-session:" + JSONEncoder output`, byte-identical to the old hand-rolled pair. The only caller of `decode(from:)` is `VolcengineArkUsageProvider.swift:8`, which calls it on the concrete type, so the non-dynamic-dispatch caveat in `WebSessionCredential.swift:7-9` doesn't bite.

## 3. Call sites

Every reference to `VolcengineArkWebLoginController` outside its own file (verified by grep over `Sources/` and `Tests/`; nothing in tests):

| file:line | current code | proposed replacement |
|---|---|---|
| `SettingsView.swift:549` | `VolcengineArkWebLoginController.shared.startLogin(completion: completion)` | see block below (mirrors the DeepSeek case at lines 538-545) |
| `VolcengineArkUsageProvider.swift:17` | `VolcengineArkWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")` | `WebSessionLog.debugLog("native request failed: \(error.localizedDescription); falling back to own session", providerTitle: Self.providerTitle)` |
| `VolcengineArkUsageProvider.swift:18` | `usageData = try await VolcengineArkWebLoginController.shared.fetchAFPUsageFromActiveSession()` | `guard let controller = await WebSessionRegistry.shared.controller(for: config) else { throw WebSessionError.unsupportedProvider }` + `usageData = try await controller.fetchUsage(context: Self.currentFetchContext())` |
| `VolcengineArkUsageProvider.swift:70` | `VolcengineArkWebLoginController.debugLog("native request action=\(action), \(session.debugSummary)")` | `WebSessionLog.debugLog("native request action=\(action), \(session.debugSummary)", providerTitle: Self.providerTitle)` |
| `VolcengineArkUsageProvider.swift:74` | `VolcengineArkWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")` | `WebSessionLog.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))", providerTitle: Self.providerTitle)` |
| `VolcengineArkUsageProvider.swift:75` | `throw VolcengineArkWebLoginController.LoginError.requestFailed("Volcengine Ark HTTP \(httpResponse.statusCode): \(body.prefix(160))")` | `throw WebSessionError.requestFailed(providerTitle: Self.providerTitle, message: "Volcengine Ark HTTP \(httpResponse.statusCode): \(body.prefix(160))")` |
| `VolcengineArkUsageProvider.swift:79` | `VolcengineArkWebLoginController.debugLog("native request succeeded, action=\(action), bytes=\(data.count)")` | `WebSessionLog.debugLog("native request succeeded, action=\(action), bytes=\(data.count)", providerTitle: Self.providerTitle)` |

`WebSessionError.requestFailed`'s description returns `message` verbatim (WebSessionError.swift:23-24), so the only user-visible string in this set is preserved byte-for-byte. `Self.providerTitle` requires adding, at the top of `VolcengineArkUsageProvider` (DeepSeek precedent, `DeepSeekUsageProvider.swift:4`):

```swift
    private static let providerTitle = "Volcengine Ark"
```

SettingsView replacement for line 549 (the DeepSeek precedent at lines 538-545, adapted):

```swift
        case .volcengineArk:
            guard let config = appState.configs.first(where: { $0.id == selectedID }),
                  let controller = WebSessionRegistry.shared.controller(for: config) else {
                isWebLoginInProgress = false
                appState.lastError = WebSessionError.unsupportedProvider.localizedDescription
                return
            }
            controller.startLogin(completion: completion)
```

Note on the line-17 log text: the DeepSeek migration (commit `e8bb064`) changed `"falling back to active WebView"` to `"falling back to own session"` in the same edit, because the "active WebView" concept no longer exists — I reproduced that wording. It's debug-only output, not user-visible.

Also, after the change `VolcengineArkWebLoginController.swift` (including its `debugLog`, `javascriptAuthSummary`, `LoginError` and the private window controller) becomes fully unreferenced and should be deleted — exactly the DeepSeek precedent commit `ddc2306`.

Message-text parity for errors that reach users (old `LoginError` → `WebSessionError`, all confirmed identical because `providerTitle == "Volcengine Ark"`):
- `.cancelled` → `.cancelled(providerTitle:)` → "Volcengine Ark login cancelled" (both).
- `.invalidResponse` → `.invalidResponse(providerTitle:)` → "Volcengine Ark usage response was invalid" (both).
- `.requestFailed(message)` → `.requestFailed(providerTitle:message:)` → `message` (both).
- The kernel's kernel-generated web-fetch failure `"\(providerTitle) Web fetch HTTP \(status): \(text.prefix(160))"` (WebSessionController.swift:144) is byte-identical to the old controller's line 215 string.
- `.noSessionFound` and `.missingWebView` have no direct successor — see Surprises.

## 4. Wiring

**Factory case** — in `WebSessionDescriptor.swift`, `WebSessionDescriptorFactory.descriptor(for:)` (lines 101-109):

```swift
        switch kind {
        case .deepSeek:
            DeepSeekWebSessionDescriptor()
        case .volcengineArk:
            VolcengineArkWebSessionDescriptor()
        case .kimiCode, .zhipuCode, .miniMax, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
```

(`.volcengineArk` is removed from the nil arm. No existing test breaks: `WebSessionRegistryTests.returnsNilForProvidersWithoutDescriptor` uses `.demo`, and `WebSessionDescriptorTests.factoryOnlyKnowsDeepSeekForNow` never asserts volcengineArk — its name just goes stale.)

**Provider fallback** — `VolcengineArkUsageProvider.swift`, before (lines 12-19):

```swift
        do {
            let usageData: Data
            do {
                usageData = try await fetchAgentPlanAFPUsage(session: session)
            } catch {
                VolcengineArkWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                usageData = try await VolcengineArkWebLoginController.shared.fetchAFPUsageFromActiveSession()
            }
```

after:

```swift
        do {
            let usageData: Data
            do {
                usageData = try await fetchAgentPlanAFPUsage(session: session)
            } catch {
                WebSessionLog.debugLog(
                    "native request failed: \(error.localizedDescription); falling back to own session",
                    providerTitle: Self.providerTitle
                )
                guard let controller = await WebSessionRegistry.shared.controller(for: config) else {
                    throw WebSessionError.unsupportedProvider
                }
                usageData = try await controller.fetchUsage(context: Self.currentFetchContext())
            }
```

with the context helper added to the struct:

```swift
    /// The AFP endpoint is not month-scoped today (the script POSTs an empty body), but the
    /// kernel's fetch entry point requires a context; the current month keeps the value
    /// meaningful if the script ever interpolates one.
    private static func currentFetchContext() -> WebSessionFetchContext {
        let calendar = Calendar.current
        let now = Date()
        return WebSessionFetchContext(
            year: calendar.component(.year, from: now),
            month: calendar.component(.month, from: now)
        )
    }
```

Optional, if the fallback needs to be exercised without breaking the native path: the DeepSeek precedent commit added a debug escape hatch inside the inner `do` (before the native call), reproduced for parity:

```swift
                // Debug-only escape hatch for exercising the web-session fallback path; there is
                // no real native request behind this failure.
                if ProcessInfo.processInfo.environment["TOKEN_HEALTH_FORCE_WEB_FALLBACK"] == "1" {
                    WebSessionLog.debugLog("forced web fallback", providerTitle: Self.providerTitle)
                    throw WebSessionError.requestFailed(providerTitle: Self.providerTitle, message: "forced fallback")
                }
```

## 5. Surprises

1. **Two-value cookie extraction, and a nearly-dead fallback.** The old controller produced the credential from two async sources: `extractStorageCredential` (JS) and `extractCookieCredential` (cookie store), the latter returning `(header, csrfToken)` (line 286-305). The kernel only gives a joined header, so `csrfToken` is parsed back out of it by exact name (kernel joins with `"; "`, values unencoded — WebSessionController.swift:372-376 — so the extracted value is byte-identical to the old `$0.value`). Crucial detail: because the extraction script returns `""` (not null) for a missing cookie, `credential.csrfToken ?? cookieCSRF` only ever fell back when the JS JSON failed to parse. A "tidier" implementation that treats empty-string script csrf as absent would change behavior; the descriptor above preserves the exact `??` order.
2. **No `accessToken`, by design.** The credential authenticates nothing by itself; the native request sends `cookieHeader` as the `Cookie` header (provider lines 62-64) and `csrfToken` as `X-Csrf-Token` (lines 65-67). `isEmpty` being cookie-only is therefore correct and must stay cookie-only — if `isEmpty` were widened, the settings UI and import would start flagging csrf-less sessions differently. This matches the plan doc's phase-2 note (line ~1827-1829: Volcengine Ark/OpenCode Go have no `accessToken`).
3. **Month-scoped AFP usage does not exist.** `afpUsageFetchScript` posts `{}` to a fixed path; nothing is month-scoped. The descriptor ignores `context`, and only the provider's call site must fabricate a `WebSessionFetchContext` (helper above). If a later change makes the endpoint month-scoped, the descriptor — not the provider — is the place to interpolate.
4. **`usageData` returns `envelope.text`, not the envelope.** DeepSeek's descriptor returns the whole script envelope because its parser expects the bundle; Volcengine's `VolcengineArkUsageParser.parseAFPUsage(data:)` expects the raw API body (`Result`/`Code`/`ResponseMetadata` at the top level, provider lines 84-137). Returning the envelope would make every fallback parse die with `invalidShape`. Also note the corner case: the old code returned the empty `Data` for a present-but-empty `text` (surfacing "Expected a JSON object"), whereas my guard throws `invalidResponse` ("Volcengine Ark usage response was invalid") — this follows plan-doc line 1837, but if strict byte-parity is preferred, drop `!text.isEmpty`.
5. **`isAuthenticationFailure` default is newly reachable for this provider.** The old controller had no session-expiry concept: any non-2xx envelope became `requestFailed("Volcengine Ark Web fetch HTTP …")`. Under the kernel, a 401/403 becomes `sessionExpired` → "Volcengine Ark session expired. Log in again for this account." The descriptor keeps the default (DeepSeek precedent). Worth an explicit decision during real-device verification; if the AFP endpoint uses different status codes for expiry, override `isAuthenticationFailure` in the descriptor.
6. **Retired error copy with nowhere to go.** `LoginError.noSessionFound` ("Volcengine Ark session was not found. Log in first, wait for the Agent Plan page to load, then click Import Session.", line 21) and `.missingWebView` ("Volcengine Ark WebView session is unavailable", line 23) disappear with the controller. Import failure now surfaces `missingSessionMessage` via `requestFailed` and the window stays open (kernel `onImportFailed` → `keepWindowOpen: true` — same window behavior as the old `.noSessionFound`). This is exactly what the DeepSeek migration did with its identically-shaped `noSessionFound`.
7. **The stored `cookieHeader` value changes bytes (order only).** Old: cookies sorted by name (line 298-301). New: WebKit's own order (WebSessionController.swift:376). Semantically irrelevant to the server, but a previously-imported credential and a re-imported one will not be string-equal, and the header is stored in the Keychain. Same trade-off DeepSeek already accepted (documented in the protocol, WebSessionDescriptor.swift:60-64).
8. **Debug-log surface changes.** `debugLog` prefix becomes `[TokenHealth][Volcengine Ark]` (was `[TokenHealth][VolcengineArk]`); the per-provider `javascriptAuthSummary` (`jsAuth csrf=yes`) is replaced by the kernel's generic one (`jsAuth CSRF=yes`, from `hasCSRF`); the old `logBrowserState` cookie-name dump and `extractCookieCredential cookies=…` line vanish with the controller. All debug-only. The envelope keeps `hasCSRF` so the kernel's generic summary stays informative.
9. **Two cosmetic side effects of enabling the factory.** (a) `SettingsView.webSessionAccountLabel` (lines 431-438) starts returning a label for Volcengine Ark configs, so the settings row changes from "…web session stored locally" to "…web session connected: <accountName>" — automatic, no call-site change. (b) The login window shrinks from 1120x780 (old line 106) to the kernel's 1080x760 (WebSessionController.swift:303,336); DeepSeek's old window was already 1080x760 so the kernel geometry is the accepted precedent.
10. **Not a descriptor fix, but on phase two's plate:** the plan doc's "已知窄缺口" (lines 1810-1816) records that `WebSessionRegistry.configuredProfileIDs` is memory-only, so deleting a config whose provider kind was previously changed can leak an on-disk profile. It is recorded as phase-two work and is orthogonal to this descriptor — no descriptor change can address it.
11. **Optional shared helper (not required now):** plan-doc line 1828 suggests extracting `accountLabel`'s non-empty guard into a `WebSessionCredential` extension (`static func nonEmpty(_:)`) once MiniMax/Volcengine Ark/OpenCode Go all repeat it. That touches `WebSessionCredential.swift` (kernel file); the inline guard above is the DeepSeek-parity choice for a single-provider migration, and the helper can be introduced when the other two land.

### Line ranges used

- `VolcengineArkWebLoginController.swift`: 9-30 (LoginError copy), 35-54 (login flow), 56-62 (`fetchAFPUsageFromActiveSession`), 104 (loginInstructions), 144 (window title), 165-168 (`loadAgentPlan`), 170-198 (`importSession`), 200-223 (`fetchAFPUsage`), 241-266 (`logBrowserState`), 268-284 (`extractStorageCredential`), 286-305 (`extractCookieCredential`, csrf at 302), 307-310 (`isVolcengineCookie`), 312-317 (`accountNameFromPageTitle`), 319-348 (`sessionExtractionScript`), 350-375 (`afpUsageFetchScript`).
- `VolcengineArkWebSessionCredential.swift`: 1-37 (whole file).
- `VolcengineArkUsageProvider.swift`: 3-35 (`fetchUsage`, fallback at 14-19), 41-81 (`fetchTopAction`, auth headers 62-67), 84-110 (parser entry).
- `WebSessionDescriptor.swift`: 34-98 (protocol + defaults), 100-110 (factory).
- `WebSessionController.swift`: 127-153 (envelope handling + error text), 183-216 (headless webview/origin), 280-396 (login window, import at 362-395, cookie join 372-376).
- Precedents: `DeepSeekUsageProvider.swift:3-45, 105-183`; `DeepSeekWebSessionDescriptor.swift:4-109`; `DeepSeekWebSessionCredential.swift:1-27`; commits `e8bb064` (provider fallback migration), `83b8070` (SettingsView routing), `ddc2306` (controller deletion), and the deleted `DeepSeekWebLoginController.swift` (via `git show ddc2306^`).
- Plan doc `docs/superpowers/plans/2026-09-18-multi-account-web-session.md`: 1810-1816 (profile-bookkeeping gap), 1818 (phase two), 1826-1843 (phase-2 landing notes incl. named-cookie and `text`-non-empty rules).
