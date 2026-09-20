# Zhipu → `WebSessionDescriptor` migration report (read-only research, no files modified)

Provenance: everything below is transcribed from `Sources/TokenHealth/ZhipuWebLoginController.swift` (355 lines), `Sources/TokenHealth/ZhipuWebSessionCredential.swift`, `Sources/TokenHealth/Providers.swift`, `Sources/TokenHealth/SettingsView.swift`, compared against the phase-1 DeepSeek precedent (current `DeepSeekWebSessionDescriptor.swift` + the deleted `DeepSeekWebLoginController.swift` as of `ddc2306^`) and the phase-2 guidance in `docs/superpowers/plans/2026-09-18-multi-account-web-session.md:1824-1842`. Line ranges are cited per item.

---

## 1. Descriptor

New file `Sources/TokenHealth/ZhipuWebSessionDescriptor.swift` (phase-1 landed descriptors as new files and deleted the old controller — plan deviation, plan line 1841-1842; the old controller file is deleted in the same change as `ddc2306` did for DeepSeek):

```swift
import Foundation

@MainActor
struct ZhipuWebSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "Zhipu"
    let loginInstructions = "Log in with Zhipu, wait for usage stats to load, then import."
    let missingSessionMessage = "No session found. Make sure Zhipu is logged in."
    let loginURL = URL(string: "https://bigmodel.cn/coding-plan/team/usage-stats")!

    func shouldIncludeCookie(domain: String) -> Bool {
        domain.lowercased().contains("bigmodel")
    }

    var extractionScript: String {
        """
        (() => JSON.stringify({
          href: location.href,
          organizationID: localStorage.getItem('Bigmodel-Organization') || '',
          projectID: localStorage.getItem('Bigmodel-Project') || ''
        }))();
        """
    }

    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? {
        guard let data = extractionJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let credential = ZhipuWebSessionCredential(
            accessToken: Self.cookieValue(named: "bigmodel_token_production", in: cookieHeader),
            cookieHeader: cookieHeader,
            organizationID: object["organizationID"] as? String,
            projectID: object["projectID"] as? String,
            planName: PlanNameExtractor().find(in: object) ?? Self.planNameFromPageTitle(pageTitle)
        )
        guard !credential.isEmpty else {
            return nil
        }
        return credential.encodedForStorage()
    }

    func usageFetchScript(context: WebSessionFetchContext) -> String {
        // Zhipu's script takes no date parameters; `context` belongs to the kernel's uniform
        // signature and is unused here.
        """
        (() => {
          const tokenCookie = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('bigmodel_token_production='));
          const token = tokenCookie ? decodeURIComponent(tokenCookie.split('=').slice(1).join('=')) : '';
          const org = localStorage.getItem('Bigmodel-Organization') || '';
          const project = localStorage.getItem('Bigmodel-Project') || '';
          const xhr = new XMLHttpRequest();
          xhr.open('GET', '/api/monitor/usage/quota/limit?type=2', false);
          xhr.withCredentials = true;
          xhr.setRequestHeader('Accept', 'application/json');
          xhr.setRequestHeader('Content-Type', 'application/json;charset=utf-8');
          xhr.setRequestHeader('Set-Language', 'zh');
          xhr.setRequestHeader('Accept-Language', 'zh-CN');
          if (token) xhr.setRequestHeader('Authorization', token);
          if (org) xhr.setRequestHeader('Bigmodel-Organization', org);
          if (project) xhr.setRequestHeader('Bigmodel-Project', project);
          xhr.send();
          return JSON.stringify({
            ok: xhr.status >= 200 && xhr.status < 300,
            status: xhr.status,
            hasAccessToken: Boolean(token),
            hasOrganizationID: Boolean(org),
            hasProjectID: Boolean(project),
            text: xhr.responseText || ''
          });
        })();
        """
    }

    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        // The envelope's `text` is the site response body, and the kernel reports a missing field
        // as the empty string, so empty text has to be rejected here rather than passed on.
        guard let envelope = WebSessionScriptEnvelope.parse(scriptResultJSON), !envelope.text.isEmpty else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return Data(envelope.text.utf8)
    }

    func accountLabel(fromCredential credential: String) -> String? {
        // Same shape as DeepSeek; ZhipuWebSessionCredential.accountLabel is nil because the struct
        // carries a plan name, not an account name.
        ZhipuWebSessionCredential.decode(from: credential)?.accountLabel
    }

    /// Pulls one named cookie out of the kernel's joined `name=value; name=value` header. Matches
    /// the whole name before the first `=`, never a prefix, and keeps everything after the first
    /// `=` as the value, because cookie values may contain `=`.
    private nonisolated static func cookieValue(named name: String, in cookieHeader: String?) -> String? {
        guard let cookieHeader else {
            return nil
        }
        for pair in cookieHeader.components(separatedBy: "; ") {
            guard let separatorIndex = pair.firstIndex(of: "=") else {
                continue
            }
            if pair[..<separatorIndex] == name {
                return String(pair[pair.index(after: separatorIndex)...])
            }
        }
        return nil
    }

    private nonisolated static func planNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("智谱AI开放平台") else {
            return nil
        }
        return title
    }
}
```

Decisions and provenance, item by item:

- **`providerTitle = "Zhipu"`** — not `ProviderKind.title` ("Zhipu Coding"). Evidence: window title `"Login with Zhipu"` (line 146), status `"Importing Zhipu session..."` (174), `"No session found. Make sure Zhipu is logged in."` (195), error copy `"Zhipu login cancelled"` / `"Zhipu usage response was invalid"` (19, 24-25), log prefix `[TokenHealth][Zhipu]` (80). Matches plan phase-2 note line 1839.
- **`loginInstructions`** — line 106, verbatim. **`missingSessionMessage`** — line 195, verbatim (the kernel also uses it for the `onImportFailed` completion, replacing `LoginError.noSessionFound`; see Surprises).
- **`loginURL`** — line 168 verbatim. `originHost` is **omitted**: `loginURL.host` is `"bigmodel.cn"`, and the protocol extension defaults `originHost` to exactly that (`WebSessionDescriptor.swift:81-83`). The installed DeepSeek descriptor likewise declares no `originHost`.
- **`shouldIncludeCookie`** — copies line 307 (`$0.domain.lowercased().contains("bigmodel")`; same predicate at line 260). **Keep the internal `lowercased()`**: the kernel already lowercases before calling (`WebSessionController.swift:374`), so it is a no-op on that path, but it matches the reference implementation and keeps the predicate correct when tests call it directly with mixed case (DeepSeek's test does exactly that, `WebSessionDescriptorTests.swift:11-21`).
- **`extractionScript`** — lines 272-276 verbatim, from `extractStorageCredential` (271-277). `logBrowserState`'s script (245-251) is debug-only and is not the import extraction.
- **`encodeCredential`** — reproduces `importSession` lines 185-197. Field mapping:
  - `accessToken` = value of the cookie **named `bigmodel_token_production`** pulled from `cookieHeader` (old line 316, assigned via `credential.accessToken ?? accessToken` at line 187 where the extraction-side value was always `nil` — constructor line 288). Verified: yes, Zhipu needs the cookie by name, exactly as the phase-1 notes claim (plan lines 1831-1832). The helper matches on the full name before the first `=` per the protocol doc comment (`WebSessionDescriptor.swift:60-64`). It returns the **raw** cookie value — the old Swift path used `WKHTTPCookie.value` undecoded (only the JS script does `decodeURIComponent`), so no decoding here.
  - `cookieHeader` = the kernel's joined header (old line 186 / 317 — same `name=value` join; kernel builds `matching.joined(separator: "; ")`, and `nil` when no cookies match, matching the old `guard !zhipuCookies.isEmpty else { completion(nil, nil) }` at 308-312).
  - `organizationID` / `projectID` = `as? String` of the extraction object's fields (old lines 289-290). Note the script's `|| ''` means a missing value is stored as `""`, not nil — that must stay, it changes the encoded JSON.
  - `planName` = `PlanNameExtractor().find(in: object) ?? Self.planNameFromPageTitle(pageTitle)` (old line 292 for the extractor, 188 for the `??` page-title fallback, 298-303 for the title filter).
  - **"Empty" gate**: `!credential.isEmpty`, i.e. both `accessToken` and `cookieHeader` empty (old lines 191-197; `isEmpty` at `ZhipuWebSessionCredential.swift:10-12`).
- **`usageFetchScript(context:)`** — lines 324-348 verbatim; no month/year interpolation anywhere in the script, so `context` is ignored (signature-only change from `static func usageFetchScript()`, lines 322-350).
- **`usageData(fromScriptResult:)`** — the old method returned the envelope's **`text` field**, not the whole envelope: it parsed the envelope to read `object["text"] as? String` (208-212) and returned `text.data(using: .utf8)` (221-225). Confirmed twice more: design spec §5.2 ("DeepSeek / MiniMax / OpenCode Go 返回整个信封；Kimi / Zhipu / Volcengine Ark 返回 `text`") and plan lines 1836-1838, which explicitly require validating `text` non-empty and throwing `invalidResponse` instead of handing out `Data(envelope.text.utf8)` empty. The thrown text `"Zhipu usage response was invalid"` is byte-identical to the old `LoginError.invalidResponse`. The kernel now performs the `ok == false` handling (debug log + `requestFailed`) that lines 214-219 did, producing the same `"Zhipu Web fetch HTTP <status>: <text 160>"` message (`WebSessionController.swift:135-145`).
- **`accountLabel(fromCredential:)`** — **nil is right**. This struct has `planName`, not `accountName`; a plan tier cannot identify an account (two Zhipu accounts on the same plan would produce the same label, which defeats the settings label's purpose and the design explicitly maps Zhipu to `nil` — spec §5.1 table, line 102, and §10 test expectation "Kimi / Zhipu 断言为 nil"). The protocol extension would return nil on its own, but keeping the member preserves DeepSeek's member order and puts the decision in the credential's `accountLabel`.
- Comments are all English; the only Chinese in the file is the `"智谱AI开放平台"` string literal in `planNameFromPageTitle` (old line 299) — a brand filter, not a comment, and it must be preserved verbatim.

---

## 2. Credential

Whole file `Sources/TokenHealth/ZhipuWebSessionCredential.swift` after migration (prefix from line 28; fields order preserved so synthesized JSON key order — and thus the stored ciphertext — is unchanged; `isEmpty`/`debugSummary` bodies copied byte-for-byte from lines 10-21; `encodedForStorage()`/`decode(from:)` bodies deleted in favor of the protocol extension, `WebSessionCredential.swift:18-37`):

```swift
import Foundation

struct ZhipuWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "zhipu-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var organizationID: String?
    var projectID: String?
    var planName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
    }

    /// No account name is available: `planName` names a plan tier, not an account, so two accounts
    /// on the same plan would show the same label.
    var accountLabel: String? {
        nil
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let orgStatus = (organizationID ?? "").isEmpty ? "no" : "yes"
        let projectStatus = (projectID ?? "").isEmpty ? "no" : "yes"
        let planStatus = (planName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) org=\(orgStatus) project=\(projectStatus) plan=\(planStatus)"
    }
}
```

Storage stays compatible: same prefix `zhipu-web-session:`, same JSON keys, legacy strings decode unchanged. Both callers (`Providers.swift:45` and the descriptor) call `decode` on the concrete type, so the extension's implementation is what runs (the existential-dispatch warning in `WebSessionCredential.swift:7-9` does not apply).

---

## 3. Call sites

All references to `ZhipuWebLoginController` outside its own file are 13 lines: one in `SettingsView.swift`, twelve in `Providers.swift`. Preamble: add `private static let providerTitle = "Zhipu"` to `ZhipuCodeUsageProvider` (mirrors `DeepSeekUsageProvider.swift:4`); the table's `Self.providerTitle` refers to it. The five `ZhipuUsageParser` rows are a separate type with no precedent for a stored title, so they use the literal `"Zhipu"` (debug-log prefix only).

| file:line | current code | proposed replacement |
|---|---|---|
| `Sources/TokenHealth/SettingsView.swift:536-537` | `case .zhipuCode:`<br>`    ZhipuWebLoginController.shared.startLogin(completion: completion)` | `case .zhipuCode:`<br>`    guard let config = appState.configs.first(where: { $0.id == selectedID }),`<br>`          let controller = WebSessionRegistry.shared.controller(for: config) else {`<br>`        isWebLoginInProgress = false`<br>`        appState.lastError = WebSessionError.unsupportedProvider.localizedDescription`<br>`        return`<br>`    }`<br>`    controller.startLogin(completion: completion)` |
| `Providers.swift:54` | `ZhipuWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")` | `WebSessionLog.debugLog(`<br>`    "native request failed: \(error.localizedDescription); falling back to own session",`<br>`    providerTitle: Self.providerTitle`<br>`)` |
| `Providers.swift:55` | `quotaData = try await ZhipuWebLoginController.shared.fetchUsageDataFromActiveSession()` | guard + `fetchUsage(context:)` block — full text in §4 |
| `Providers.swift:143` | `ZhipuWebLoginController.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")` | `WebSessionLog.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)", providerTitle: Self.providerTitle)` |
| `Providers.swift:147` | `ZhipuWebLoginController.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")` | `WebSessionLog.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))", providerTitle: Self.providerTitle)` |
| `Providers.swift:148` | `throw ZhipuWebLoginController.LoginError.requestFailed("Zhipu HTTP \(httpResponse.statusCode): \(body.prefix(160))")` | `throw WebSessionError.requestFailed(providerTitle: Self.providerTitle, message: "Zhipu HTTP \(httpResponse.statusCode): \(body.prefix(160))")` |
| `Providers.swift:150` | `ZhipuWebLoginController.debugLog("native request succeeded, bytes=\(data.count)")` | `WebSessionLog.debugLog("native request succeeded, bytes=\(data.count)", providerTitle: Self.providerTitle)` |
| `Providers.swift:153` | `ZhipuWebLoginController.debugLog("quota body=\(body.prefix(1000))")` | `WebSessionLog.debugLog("quota body=\(body.prefix(1000))", providerTitle: Self.providerTitle)` |
| `Providers.swift:205` | `ZhipuWebLoginController.debugLog("parser found no limits in body=\(responsePreview(data))")` | `WebSessionLog.debugLog("parser found no limits in body=\(responsePreview(data))", providerTitle: "Zhipu")` |
| `Providers.swift:235` | `ZhipuWebLoginController.debugLog("parser could not map limits keys=\(keySummary), body=\(responsePreview(data))")` | `WebSessionLog.debugLog("parser could not map limits keys=\(keySummary), body=\(responsePreview(data))", providerTitle: "Zhipu")` |
| `Providers.swift:243` | `ZhipuWebLoginController.debugLog("model parser invalid body=\(responsePreview(data))")` | `WebSessionLog.debugLog("model parser invalid body=\(responsePreview(data))", providerTitle: "Zhipu")` |
| `Providers.swift:268` | `ZhipuWebLoginController.debugLog("model parser found no usage body=\(responsePreview(data))")` | `WebSessionLog.debugLog("model parser found no usage body=\(responsePreview(data))", providerTitle: "Zhipu")` |
| `Providers.swift:275` | `ZhipuWebLoginController.debugLog("tool parser invalid body=\(responsePreview(data))")` | `WebSessionLog.debugLog("tool parser invalid body=\(responsePreview(data))", providerTitle: "Zhipu")` |

Notes: the only thrown `LoginError` on this list is line 148, and its user-visible text is preserved byte-for-byte (`WebSessionError.requestFailed`'s `errorDescription` is the message, `WebSessionError.swift:23-24`). The line-54 log text is reworded ("falling back to active WebView" → "falling back to own session") exactly as the DeepSeek precedent did in `e8bb064` — logs only, not user-visible. `WebSessionLog.debugLog` prints `[TokenHealth][Zhipu] …`, identical to the old `[TokenHealth][Zhipu]` prefix. After this change `ZhipuWebLoginController.swift` has no remaining references and is deleted (as `DeepSeekWebLoginController.swift` was in `ddc2306`).

---

## 4. Wiring

`Sources/TokenHealth/WebSessionDescriptor.swift` (currently lines 100-110), add one case and drop `.zhipuCode` from the nil list:

```swift
        case .deepSeek:
            DeepSeekWebSessionDescriptor()
        case .zhipuCode:
            ZhipuWebSessionDescriptor()
        case .kimiCode, .miniMax, .volcengineArk, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
```

`Sources/TokenHealth/Providers.swift` fallback call. Before (lines 49-56, plus the new static at the top of `ZhipuCodeUsageProvider`, lines 41-44):

```swift
struct ZhipuCodeUsageProvider: UsageProvider {
    private let quotaEndpoint = "https://bigmodel.cn/api/monitor/usage/quota/limit?type=2"
    ...
        do {
            let quotaData: Data
            do {
                quotaData = try await fetchUsageData(session: session, endpoint: quotaEndpoint)
            } catch {
                ZhipuWebLoginController.debugLog("native request failed: \(error.localizedDescription); falling back to active WebView")
                quotaData = try await ZhipuWebLoginController.shared.fetchUsageDataFromActiveSession()
            }
```

After (validated with swiftc):

```swift
struct ZhipuCodeUsageProvider: UsageProvider {
    private static let providerTitle = "Zhipu"
    private let quotaEndpoint = "https://bigmodel.cn/api/monitor/usage/quota/limit?type=2"
    ...
        do {
            let quotaData: Data
            do {
                quotaData = try await fetchUsageData(session: session, endpoint: quotaEndpoint)
            } catch {
                WebSessionLog.debugLog(
                    "native request failed: \(error.localizedDescription); falling back to own session",
                    providerTitle: Self.providerTitle
                )
                guard let controller = await WebSessionRegistry.shared.controller(for: config) else {
                    throw WebSessionError.unsupportedProvider
                }
                // Zhipu's script takes no date parameters; the kernel wants a context for its
                // uniform signature, so the site's own time zone supplies harmless values.
                let now = Date()
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
                quotaData = try await controller.fetchUsage(
                    context: WebSessionFetchContext(
                        year: calendar.component(.year, from: now),
                        month: calendar.component(.month, from: now)
                    )
                )
            }
```

This is the exact shape of the DeepSeek fallback (`DeepSeekUsageProvider.swift:34-45`), including the design-mandated explicit nil handling (`throw WebSessionError.unsupportedProvider`, spec §5.5). Errors from the fallback still land in the outer `catch` at line 73-75 → `ProviderUsageSnapshot.unavailable(config:message: error.localizedDescription)`.

---

## 5. Surprises

1. **Named cookie confirmed.** `bigmodel_token_production` must be pulled out of the joined `cookieHeader` by name (controller line 316; plan lines 1831-1832). One helper function inside the descriptor is enough — the protocol does not need the structured `[WebSessionCookie]` change the plan floats as a fallback; that stays YAGNI. The raw (undecoded) value is correct: the old Swift path stored `WKHTTPCookie.value` raw, while only the JS path does `decodeURIComponent`.
2. **Two extra credential fields that must survive, and they do**: `organizationID` and `projectID` are read by the native request path as `Bigmodel-Organization` / `Bigmodel-Project` headers (`Providers.swift:136-141`), and `planName` feeds the snapshot title (`Providers.swift:67`). The descriptor writes all three. The `|| ''` in the extraction script means missing values encode as `""`, not nil — keep `as? String` on the extraction object, not an emptiness-normalizing variant, or the stored ciphertext changes.
3. **No second host.** Login page, usage endpoint, and the native endpoints are all `bigmodel.cn`; `originHost` is omitted (defaults to `loginURL.host`). But the usage script uses a *relative* XHR path and same-origin `localStorage`, and the kernel checks the host only *before* the headless load (`WebSessionController.swift:191-216`) — if a logged-out visit redirects the headless WebView off `bigmodel.cn`, the script would resolve against that origin. Behavior parity with today (the script ran in the login window, wherever it was) — worth one line in manual acceptance, not a kernel change.
4. **Plan-name derivation.** Zhipu's ultimate fallback is `"团队套餐标准版"` (a Chinese literal, `Providers.swift:67`), not Kimi's `"Allegretto"` — and it lives in the *provider*, not the descriptor, so the migration does not touch it. The descriptor's `planName` comes from `PlanNameExtractor().find(in: extractionObject) ?? planNameFromPageTitle(pageTitle)`; in practice the extractor returns nil on the extraction object (its keys are only `href`/`organizationID`/`projectID`, none matching the extractor's plan-word *and* name-word rule in `PlanNameExtractor.swift:48-54`), so the page title is the effective source — and that title is dropped entirely when it contains `"智谱AI开放平台"` (line 299). Keep that Chinese literal exactly. Since both accounts of a provider typically share a plan, distinguishing accounts still rests on `displayName` (design §5.6) — and Zhipu's `accountLabel` is nil, so settings shows "Zhipu Coding web session stored locally".
5. **Behavior deltas inherited from the kernel (same as DeepSeek's phase-1 migration, flagging for reviewers):**
   - A malformed extraction JSON now aborts the import (`return nil` → `missingSessionMessage`, window stays open). Old code fell back to a cookie-only credential (`storageCredential ?? ZhipuWebSessionCredential()`, line 185). DeepSeek's new descriptor has exactly the same property (its test asserts non-JSON → nil).
   - `text` present but empty with `ok == true` now throws `invalidResponse` instead of returning empty `Data` — mandated by plan lines 1836-1838.
   - `ok == false` with status 401/403 now surfaces `"Zhipu session expired. Log in again for this account."` (`sessionExpired`) instead of `"Zhipu Web fetch HTTP 401: …"`. The default 401/403 rule is what the design mandates for all providers (spec §5.2); the old Zhipu path had no expiry detection at all, so nothing is lost, but the endpoint may in practice redirect to a login page and return 200 + HTML, in which case the failure stays a parser error, exactly as today.
   - `LoginError.noSessionFound`'s message ("Zhipu login session was not found. Log in first, wait for usage stats to load, then click Import Session.") is replaced by the status string "No session found. Make sure Zhipu is logged in." — precisely what happened to DeepSeek (its old `.noSessionFound` text was likewise dropped).
   - `LoginError.missingWebView` ("Zhipu WebView session is unavailable") disappears: the fallback no longer needs an open window, which is the point of the phase-1 design.
   - Debug logs change: the kernel logs `session imported` instead of the old controller's `import storage …` / `browserState=…` / `httpCookieStore=…` lines, and `WebSessionLog.javascriptAuthSummary` renames the envelope flags (`hasAccessToken`→`accessToken`, `hasOrganizationID`→`OrganizationID`, sorted alphabetically). Kernel-side, not expressible via the descriptor; accepted for DeepSeek too.
6. **No kernel change is needed.** Everything Zhipu-specific (named cookie, extra fields, title filter, `text` unwrapping) fits behind the descriptor protocol.
7. **Tests.** `WebSessionDescriptorTests.factoryOnlyKnowsDeepSeekForNow` (lines 114-119) still passes after the factory change; phase 2 should extend it with `factory.descriptor(for: .zhipuCode) != nil`. Spec §10 already prescribes the new expectations: Zhipu `accountLabel == nil`, and `usageData(fromScriptResult:)` returns the `text` body for Zhipu. No existing test references Zhipu.
8. **File layout.** Per phase-1 deviation (plan lines 1841-1842): create `ZhipuWebSessionDescriptor.swift`, delete `ZhipuWebLoginController.swift` once the call sites move; do not rewrite the spec.
