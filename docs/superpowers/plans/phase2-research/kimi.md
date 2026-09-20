---

# Kimi → web-session-kernel migration report (read-only research)

Sources verified against `feature/multi-account-web-session` HEAD (`2d4c1a4`) plus working-tree state. The old worktree copy under `.claude/worktrees/strange-jemison-f47458/` was ignored. Uncommitted diffs (Info.plist version bump, StatusMenuView `onAppear` removal) are unrelated to this migration.

---

## 1. Descriptor

New file `Sources/TokenHealth/KimiWebSessionDescriptor.swift` (phase-1 deviation 1: new file, old files deleted afterwards — plan doc lines 1841-1842). Shape and member order match `DeepSeekWebSessionDescriptor.swift` exactly.

```swift
import Foundation

@MainActor
struct KimiWebSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "Kimi"
    let loginInstructions = "Log in with Kimi, wait for Console to load, then import."
    let missingSessionMessage = "No session found. Make sure Kimi Console is logged in."
    let loginURL = URL(string: "https://www.kimi.com/code/console?from=kfc_overview_topbar")!

    /// Verbatim predicate from `KimiWebLoginController.extractCookieCredential` (:315-318): a cookie
    /// belongs to Kimi when its domain mentions "kimi" or "moonshot". The kernel lowercases `domain`
    /// before calling (WebSessionController.swift:374), so the `lowercased()` here is redundant —
    /// kept anyway as the exact carry-over (DeepSeekWebSessionDescriptor keeps the same redundancy).
    func shouldIncludeCookie(domain: String) -> Bool {
        let lowered = domain.lowercased()
        return lowered.contains("kimi") || lowered.contains("moonshot")
    }

    var extractionScript: String {
        """
        (() => {
          const copyStorage = (storage) => {
            const result = {};
            for (let i = 0; i < storage.length; i++) {
              const key = storage.key(i);
              result[key] = storage.getItem(key);
            }
            return result;
          };
          return JSON.stringify({
            href: location.href,
            localStorage: copyStorage(localStorage),
            sessionStorage: copyStorage(sessionStorage)
          });
        })();
        """
    }

    /// Composition of `KimiWebLoginController.importSession` (:155-175): the storage dump becomes a
    /// credential via the moved helpers, the cookie header is attached, and the import fails only
    /// when `isEmpty` (no access token AND no cookies). `pageTitle` is unused — Kimi's credential
    /// has no account-name field, unlike DeepSeek's.
    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? {
        var credential = Self.sessionCredential(from: extractionJSON) ?? KimiWebSessionCredential()
        credential.cookieHeader = cookieHeader
        guard !credential.isEmpty else {
            return nil
        }
        return credential.encodedForStorage()
    }

    /// Kimi's gateway call asks for the current FEATURE_CODING window and takes no year/month, so
    /// `context` is deliberately unused (unlike DeepSeek's month=…&year=… interpolation).
    func usageFetchScript(context: WebSessionFetchContext) -> String {
        """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const token = localStorage.getItem('access_token');
          const tokenInfo = parseJSON(localStorage.getItem('volcano-token-info')) || {};
          const xhr = new XMLHttpRequest();
          xhr.open('POST', '/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages', false);
          xhr.withCredentials = true;
          xhr.setRequestHeader('Accept', 'application/json');
          xhr.setRequestHeader('Content-Type', 'application/json');
          xhr.setRequestHeader('x-msh-platform', 'web');
          xhr.setRequestHeader('x-msh-version', '1.0.0');
          xhr.setRequestHeader('R-Timezone', Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Shanghai');
          if (token) xhr.setRequestHeader('Authorization', token.startsWith('Bearer ') ? token : `Bearer ${token}`);
          if (tokenInfo.userId) xhr.setRequestHeader('X-Traffic-Id', tokenInfo.userId);
          if (tokenInfo.webId) xhr.setRequestHeader('x-msh-device-id', tokenInfo.webId);
          if (tokenInfo.ssid) xhr.setRequestHeader('x-msh-session-id', tokenInfo.ssid);
          xhr.send(JSON.stringify({ scope: ['FEATURE_CODING'] }));
          return JSON.stringify({
            ok: xhr.status >= 200 && xhr.status < 300,
            status: xhr.status,
            hasAccessToken: Boolean(token),
            hasTrafficID: Boolean(tokenInfo.userId),
            hasDeviceID: Boolean(tokenInfo.webId),
            hasSessionID: Boolean(tokenInfo.ssid),
            text: xhr.responseText || ''
          });
        })();
        """
    }

    /// Kimi returns the envelope's `text` field as the payload (spec §5.2 line 149; plan :1836-1838
    /// requires the non-empty check — the kernel defaults a missing `text` to `""`, not nil).
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        guard let envelope = WebSessionScriptEnvelope.parse(scriptResultJSON),
              !envelope.text.isEmpty,
              let data = envelope.text.data(using: .utf8) else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return data
    }

    /// Kimi's credential has no account name (spec §5.1 maps its label to `nil`), so this always
    /// returns nil today. It goes through the concrete codec for shape parity with DeepSeek.
    func accountLabel(fromCredential credential: String) -> String? {
        KimiWebSessionCredential.decode(from: credential)?.accountLabel
    }

    // MARK: - Import helpers (moved verbatim from KimiWebLoginController :336-443)

    private static func sessionCredential(from json: String) -> KimiWebSessionCredential? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let tokenInfo = findVolcanoTokenInfo(in: object)
        let credential = KimiWebSessionCredential(
            accessToken: findAccessToken(in: object, keyPath: []),
            cookieHeader: nil,
            trafficID: tokenInfo?["userId"] as? String,
            deviceID: tokenInfo?["webId"] as? String,
            sessionID: tokenInfo?["ssid"] as? String,
            planName: PlanNameExtractor().find(in: object)
        )
        return credential.isEmpty
            && (credential.trafficID ?? "").isEmpty
            && (credential.deviceID ?? "").isEmpty
            && (credential.sessionID ?? "").isEmpty ? nil : credential
    }

    private static func findVolcanoTokenInfo(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "volcano-token-info",
                   let string = child as? String,
                   let parsed = parseEmbeddedJSON(string) as? [String: Any] {
                    return parsed
                }

                if let found = findVolcanoTokenInfo(in: child) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let found = findVolcanoTokenInfo(in: child) {
                    return found
                }
            }
        }

        return nil
    }

    private static func findAccessToken(in value: Any, keyPath: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if let token = findAccessToken(in: child, keyPath: keyPath + [key]) {
                    return token
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let token = findAccessToken(in: child, keyPath: keyPath) {
                    return token
                }
            }
        }

        guard let string = value as? String else {
            return nil
        }

        if let parsed = parseEmbeddedJSON(string),
           let token = findAccessToken(in: parsed, keyPath: keyPath) {
            return token
        }

        let joinedKey = keyPath.joined(separator: "_").lowercased()
        let looksLikeAccessTokenKey = joinedKey.contains("access") && joinedKey.contains("token")
        let looksLikeBearer = string.lowercased().hasPrefix("bearer ")
        let looksLikeJWT = string.range(
            of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#,
            options: .regularExpression
        ) != nil

        if string.count > 20,
           !joinedKey.contains("refresh"),
           looksLikeAccessTokenKey || looksLikeBearer || looksLikeJWT {
            return string.replacingOccurrences(of: "Bearer ", with: "")
        }

        return nil
    }

    private static func parseEmbeddedJSON(_ string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
```

Field-by-field answers to the checklist:

- **`providerTitle` = `"Kimi"`** — the brand name actually used. Old window title `"Login with Kimi"` (KimiWebLoginController.swift:124); error copy "Kimi login cancelled" (:13-15), "Kimi Web fetch HTTP …" (:225), "Kimi usage response was invalid" (bridge :23). Not `ProviderKind.title` ("Kimi Code", Models.swift:25). Matches plan note :1839.
- **`loginInstructions`** — verbatim from the status label, KimiWebLoginController.swift:84.
- **`missingSessionMessage`** — verbatim from the import-failure label, KimiWebLoginController.swift:171. (Note it is the *label* text, not `LoginError.noSessionFound`'s longer sentence — see Section 3.)
- **`loginURL`** = `https://www.kimi.com/code/console?from=kfc_overview_topbar` (KimiWebLoginController.swift:146). The bridge used the same page with `from=token_health` (KimiWebUsageBridge.swift:108); the query param is attribution-only, see Surprises (e).
- **`originHost` omitted** — it equals `loginURL.host` (`"www.kimi.com"`), which is exactly what `WebSessionDescriptor.originHost`'s default returns (WebSessionDescriptor.swift:81-83). Do not override. (But note the old bridge's looser `contains("kimi.com")` check — Surprises (d).)
- **`shouldIncludeCookie`** — predicate body `contains("kimi") || contains("moonshot")` carried over from KimiWebLoginController.swift:315-318 (same predicate also at :271-272). Should it still lowercase internally? Not required — the kernel guarantees a lowercased domain (WebSessionController.swift:374), and the spec (line 133) says carry the predicate over verbatim. Keeping `lowercased()` is behaviourally identical under the kernel and matches DeepSeek's descriptor (DeepSeekWebSessionDescriptor.swift:10-12, which also double-lowercases), so keep it.
- **`extractionScript`** — verbatim from KimiWebLoginController.swift:284-298 (the body of the literal at :283-299). This is the localStorage+sessionStorage dump; the old `logBrowserState` script (:253-260) was diagnostic only and is not the extraction script.
- **`encodeCredential`** — reproduces KimiWebLoginController.swift:163-169: `storageCredential ?? KimiWebSessionCredential()`, then `cookieHeader` assignment, then `!isEmpty` gate, then `encodedForStorage()`. Fields set from the extraction: `accessToken` (recursive scan), `trafficID`/`deviceID`/`sessionID` (from the embedded `volcano-token-info`), `planName` (`PlanNameExtractor().find(in: object)`). Account name: none exists — the name-derivation concept from DeepSeek does not apply (`pageTitle` is unused). "Empty" means `accessToken` empty AND `cookieHeader` empty (credential file :11-13), so a cookie-only import must stay possible; note also the pre-gate inside `sessionCredential` (:351-354) that turns an all-empty extraction (no token, no traffic/device/session ids) into a bare credential instead.
- **`usageFetchScript`** — verbatim from KimiWebLoginController.swift:183-211 (literal delimiters :182/:212). The same script byte-for-byte is in the bridge at :39-67. No month/year interpolation, so `context` stays unused — do not add Day/month joins.
- **`usageData`** — the old code returned the **envelope's `text` field**, not the whole envelope: KimiWebLoginController.swift:214-233 (`let text = object["text"] as? String`, then `text.data(using: .utf8)` at :230-233); identical in the bridge :70-89. So `usageData` extracts `envelope.text`. Per plan :1836-1838 the non-empty check is mandatory (the kernel's `WebSessionScriptEnvelope.text` defaults to `""`). The downstream `KimiCodeBillingParser` receives exactly the same bytes as today.
- **`accountLabel(fromCredential:)`** — decodes and returns the credential's label; always nil for Kimi because the struct has no account name (spec §5.1 table line 101 explicitly maps Kimi to `nil`).
- **`isAuthenticationFailure`** — not overridden; the kernel default (401/403, WebSessionDescriptor.swift:87-93) applies, matching spec ("all six providers are 401/403, no exceptions").
- **Comments all in English** — as above. (The repo's single pre-existing Chinese comment is Models.swift:65, untouched.)

**Provenance used in this section:** KimiWebLoginController.swift :9-21 (LoginError), :84, :124, :146, :155-176 (import), :171, :182-234 (fetch script + unwrap), :252-280 (log-only), :282-334 (extraction + cookie filter), :336-443 (helpers); KimiWebUsageBridge.swift :23, :39-67, :70-89, :108; WebSessionController.swift :374, :380-384; WebSessionDescriptor.swift :81-93; Models.swift :25. Shape reference: DeepSeekWebSessionDescriptor.swift :3-177.

---

## 2. Credential

Whole file `Sources/TokenHealth/KimiWebSessionCredential.swift` in its new form. Field set, `isEmpty` and `debugSummary` semantics unchanged; hand-rolled codec deleted in favour of the protocol extension (byte-compatible storage: same prefix, same JSON keys — spec line 109).

```swift
import Foundation

struct KimiWebSessionCredential: WebSessionCredential, Codable, Equatable, Sendable {
    static let storagePrefix = "kimi-web-session:"

    var accessToken: String?
    var cookieHeader: String?
    var trafficID: String?
    var deviceID: String?
    var sessionID: String?
    var planName: String?

    var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (cookieHeader ?? "").isEmpty
    }

    /// Kimi's credential carries no account identifier (design spec §5.1 maps it to `nil`): a
    /// `planName` is a plan, not an account, so settings shows no "<account>" suffix for Kimi.
    var accountLabel: String? {
        nil
    }

    var debugSummary: String {
        let accessTokenStatus = (accessToken ?? "").isEmpty ? "no" : "yes"
        let cookieStatus = (cookieHeader ?? "").isEmpty ? "no" : "yes"
        let trafficStatus = (trafficID ?? "").isEmpty ? "no" : "yes"
        let deviceStatus = (deviceID ?? "").isEmpty ? "no" : "yes"
        let sessionStatus = (sessionID ?? "").isEmpty ? "no" : "yes"
        let planStatus = (planName ?? "").isEmpty ? "no" : "yes"
        return "accessToken=\(accessTokenStatus) cookie=\(cookieStatus) trafficID=\(trafficStatus) deviceID=\(deviceStatus) sessionID=\(sessionStatus) plan=\(planStatus)"
    }
}
```

Notes: `Codable, Equatable, Sendable` are redundant once `WebSessionCredential` (which refines them, WebSessionCredential.swift:10) is listed, but `DeepSeekWebSessionCredential` keeps them listed (file :3) — keep for identical shape. Deleting `encodedForStorage()`/`decode(from:)` (:25-42 today) is the point of the protocol extension; the produced strings are identical. `Providers.swift`'s 5 direct `KimiWebSessionCredential.decode(from:)` calls (571, 629, 650, 679, 691) keep working because the extension is on the concrete type.

---

## 3. Call sites

Everything outside the two files' own scopes. Repo-wide grep (excluding the stale worktree): only `Providers.swift` and `SettingsView.swift`; no test references those classes.

`KimiWebLoginController` outside its file: **2 call sites** (SettingsView.swift:535, Providers.swift:665).
`KimiWebUsageBridge` outside its file: **11 call sites** — the 9 `debugLog` calls in Providers.swift the plan claims (spec :292-293, plan :1821), plus `.shared.fetchUsageData()` at Providers.swift:668 and `javascriptAuthSummary` at KimiWebLoginController.swift:223 (which dies with the controller file).

**`KimiWebUsageBridge.debugLog` count verified: exactly 9 in Providers.swift** — lines **572, 577, 630, 636, 640, 643, 667, 672, 773**. (For completeness: 14 more bridge `debugLog` calls live inside KimiWebLoginController.swift — :27, :49, :52, :151, :165, :179, :224, :228, :263, :279, :303, :307, :321, :327 — and are deleted with that file, not migrated.)

| file:line | current code | proposed replacement |
|---|---|---|
| SettingsView.swift:535 | `KimiWebLoginController.shared.startLogin(completion: completion)` | `case .kimiCode, .deepSeek:` merged with the existing `.deepSeek` body (SettingsView.swift:539-545): `guard let config = appState.configs.first(where: { $0.id == selectedID }), let controller = WebSessionRegistry.shared.controller(for: config) else { isWebLoginInProgress = false; appState.lastError = WebSessionError.unsupportedProvider.localizedDescription; return }` then `controller.startLogin(completion: completion)` |
| Providers.swift:572 | `KimiWebUsageBridge.debugLog("stored Kimi session found, trying native request first: \(session.debugSummary)")` | `WebSessionLog.debugLog("stored Kimi session found, trying native request first: \(session.debugSummary)", providerTitle: "Kimi")` |
| Providers.swift:577 | `KimiWebUsageBridge.debugLog("native request failed: \(nativeSnapshot.statusMessage); falling back to active WebView")` | `WebSessionLog.debugLog("native request failed: \(nativeSnapshot.statusMessage); falling back to own session", providerTitle: "Kimi")` — keep the old message text if you want zero log churn (DeepSeek's equivalent says "own session", DeepSeekUsageProvider.swift:36, because "active WebView" is no longer accurate) |
| Providers.swift:630 | `KimiWebUsageBridge.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)")` | `WebSessionLog.debugLog("native request endpoint=\(url.absoluteString), \(session.debugSummary)", providerTitle: "Kimi")` |
| Providers.swift:636 | `KimiWebUsageBridge.debugLog("native request failed HTTP \(httpResponse.statusCode), body=\(body.prefix(220))")` | `WebSessionLog.debugLog("native request failed HTTP …", providerTitle: "Kimi")` (message unchanged) |
| Providers.swift:640 | `KimiWebUsageBridge.debugLog("native request succeeded, bytes=\(data.count)")` | `WebSessionLog.debugLog("native request succeeded, bytes=\(data.count)", providerTitle: "Kimi")` |
| Providers.swift:643 | `KimiWebUsageBridge.debugLog("native response body=\(body.prefix(1200))")` | `WebSessionLog.debugLog("native response body=\(body.prefix(1200))", providerTitle: "Kimi")` |
| Providers.swift:665 | `data = try await KimiWebLoginController.shared.fetchUsageDataFromActiveSession()` | replaced by the registry fetch — full before/after in Section 4 |
| Providers.swift:667 | `KimiWebUsageBridge.debugLog("active session fetch failed: …; falling back to hidden WebView")` | **deleted, no replacement** — the two-stage fallback no longer exists; the kernel logs its own failures (WebSessionController.swift:114-124, 135-138) |
| Providers.swift:668 | `data = try await KimiWebUsageBridge.shared.fetchUsageData()` | replaced by the registry fetch — Section 4 |
| Providers.swift:672 | `KimiWebUsageBridge.debugLog("web response body=\(body.prefix(1200))")` | `WebSessionLog.debugLog("web response body=\(body.prefix(1200))", providerTitle: "Kimi")` |
| Providers.swift:773 | `KimiWebUsageBridge.debugLog("parser found no reset for …")` (inside `KimiCodeBillingParser.quotaUsage`) | `WebSessionLog.debugLog("parser found no reset for …", providerTitle: "Kimi")` — same message; the literal `"Kimi"` is used because this type is outside `KimiCodeUsageProvider`'s private constant (if you add `private static let providerTitle = "Kimi"` to the provider, mirroring DeepSeekUsageProvider.swift:4, rows 572-672 can say `Self.providerTitle` instead; log output identical). `WebSessionLog.debugLog` is `nonisolated`, callable from the parser (WebSessionLog.swift:4) |

**Thrown-error mapping** (old cases vs `WebSessionError`, user-visible text):

| old case (file:line) | old message | new case thrown by the kernel | new message | verdict |
|---|---|---|---|---|
| `KimiWebLoginController.LoginError.cancelled` (:13-15) | "Kimi login cancelled" | `WebSessionError.cancelled(providerTitle: "Kimi")` (WebSessionController.swift:43, :66-69) | "Kimi login cancelled" (WebSessionError.swift:16-17) | byte-identical (already asserted at Tests/TokenHealthTests/WebSessionDescriptorTests.swift:132) |
| `LoginError.noSessionFound` (:16-19) | "Kimi login session was not found. Log in first, wait for the console page, then click Import Session." | `requestFailed(providerTitle: "Kimi", message: descriptor.missingSessionMessage)` (WebSessionController.swift:57-63) | "No session found. Make sure Kimi Console is logged in." | label text preserved byte-for-byte; the long sentence is dropped — exactly what phase 1 did for DeepSeek (deleted file's identical long sentence vs DeepSeekWebSessionDescriptor.swift:7) |
| `KimiWebUsageBridge.BridgeError.missingWebView` (:15-16) | "Kimi WebView session is unavailable" | registry returns nil → `WebSessionError.unsupportedProvider` | "This provider does not support web login" (WebSessionError.swift:13-14) | mirrors DeepSeekUsageProvider.swift:39-41; only reachable during account deletion / non-login provider |
| `BridgeError.loadFailed` (:17-18) | "Kimi Console failed to load" | `WebSessionError.loadTimeout(providerTitle: "Kimi", seconds: 20)` (WebSessionController.swift:196-205) | "Kimi page did not load within 20 seconds." | new capability (the bridge had no timeout; `loadFailed` itself was never thrown) |
| `BridgeError.requestFailed(msg)` (:19-21, thrown at :81, controller :225) | "Kimi Web fetch HTTP \(status): \(text.prefix(160))" | `WebSessionError.requestFailed` (WebSessionController.swift:142-145) | `"\(providerTitle) Web fetch HTTP \(status): \(text.prefix(160))"` → identical with "Kimi" | byte-identical for all non-auth failures |
| `BridgeError.invalidResponse` (:22-23, thrown at :74, :87; controller :218, :231) | "Kimi usage response was invalid" | `WebSessionError.invalidResponse(providerTitle: "Kimi")` | "Kimi usage response was invalid" | byte-identical |
| (none — old code treated 401/403 like any HTTP error) | "Kimi Web fetch HTTP 401: …" | `WebSessionError.sessionExpired(providerTitle: "Kimi")` (WebSessionController.swift:139-141) | "Kimi session expired. Log in again for this account." | intentional improvement via the kernel's default rule; already asserted at WebSessionDescriptorTests.swift:133 |
| `BridgeError.missingWebView` also thrown by `fetchUsageDataFromActiveSession` (controller :48-51) | same as above | same as above | same as above | — |

---

## 4. Wiring

**Factory** — `WebSessionDescriptor.swift:100-110`. Exact change: move `.kimiCode` out of the nil list into its own case.

```swift
struct WebSessionDescriptorFactory {
    func descriptor(for kind: ProviderKind) -> (any WebSessionDescriptor)? {
        switch kind {
        case .deepSeek:
            DeepSeekWebSessionDescriptor()
        case .kimiCode:
            KimiWebSessionDescriptor()
        case .zhipuCode, .miniMax, .volcengineArk, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
    }
}
```

Knock-on: `Tests/TokenHealthTests/WebSessionDescriptorTests.swift:117` asserts `factory.descriptor(for: .kimiCode) == nil` (test `factoryOnlyKnowsDeepSeekForNow`, :113-119) — must flip to `!= nil` and rename the test. Everything else about the registry already accommodates Kimi: `evict` will now clear a deleted Kimi config's profile via the factory check (WebSessionRegistry.swift:78) plus the `configuredProfileIDs` bookkeeping; `AppState.deleteConfig` (AppState.swift:95) needs no change.

**Provider fallback call** — `Providers.swift:661-688` (`fetchConsoleUsageViaWebView`, reached from the native-first branch at :578).

Before (verbatim, :661-688):

```swift
    private func fetchConsoleUsageViaWebView(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        do {
            let data: Data
            do {
                data = try await KimiWebLoginController.shared.fetchUsageDataFromActiveSession()
            } catch {
                KimiWebUsageBridge.debugLog("active session fetch failed: \(error.localizedDescription); falling back to hidden WebView")
                data = try await KimiWebUsageBridge.shared.fetchUsageData()
            }
            if ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1",
               let body = String(data: data, encoding: .utf8) {
                KimiWebUsageBridge.debugLog("web response body=\(body.prefix(1200))")
            }
            let usages = try KimiCodeBillingParser().parse(data: data)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: KimiWebSessionCredential.decode(from: secrets.apiKey)?.planName ?? PlanNameExtractor().find(in: data) ?? "Allegretto",
                usages: usages,
                state: .ready,
                statusMessage: "Kimi Web session",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }
```

After:

```swift
    private func fetchConsoleUsageViaWebView(config: ServiceConfig, secrets: ProviderSecrets) async -> ProviderUsageSnapshot {
        do {
            guard let controller = await WebSessionRegistry.shared.controller(for: config) else {
                throw WebSessionError.unsupportedProvider
            }
            // Kimi's usage script asks for the current FEATURE_CODING window and takes no
            // year/month, so the context values are inert; the kernel still requires one.
            let now = Date()
            let calendar = Calendar(identifier: .gregorian)
            let data = try await controller.fetchUsage(
                context: WebSessionFetchContext(
                    year: calendar.component(.year, from: now),
                    month: calendar.component(.month, from: now)
                )
            )
            if ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1",
               let body = String(data: data, encoding: .utf8) {
                WebSessionLog.debugLog("web response body=\(body.prefix(1200))", providerTitle: "Kimi")
            }
            let usages = try KimiCodeBillingParser().parse(data: data)
            return ProviderUsageSnapshot(
                id: config.id,
                serviceName: config.displayName,
                providerTitle: config.providerKind.title,
                planName: KimiWebSessionCredential.decode(from: secrets.apiKey)?.planName ?? PlanNameExtractor().find(in: data) ?? "Allegretto",
                usages: usages,
                state: .ready,
                statusMessage: "Kimi Web session",
                updatedAt: Date()
            )
        } catch {
            return ProviderUsageSnapshot.unavailable(config: config, message: error.localizedDescription)
        }
    }
```

The `guard`/`throw` mirrors DeepSeekUsageProvider.swift:39-44, including the required `await` (the registry is `@MainActor`). The `secrets` parameter stays for the `planName` line; the outer catch at :685-687 already funnels every new error into `unavailable`.

**What the single registry call replaces.** Stage 1 (`fetchUsageDataFromActiveSession`, controller :47-54) fetched from the *login window's* live WebView, requiring the window to still exist (`missingWebView` otherwise). Stage 2 (`KimiWebUsageBridge.shared.fetchUsageData()`) was a hidden WebView on `WKWebsiteDataStore.default()`. The registry call uses the config's cached kernel — the same per-config profile the login window wrote into — headless, with or without the window open, plus a 20 s load timeout. Nothing bridge-specific needs keeping: its two static log helpers already exist in `WebSessionLog` (`debugLog(_:providerTitle:)`, `javascriptAuthSummary(from:)` — the phase-1 home named by spec :293-295), its lazy "already on kimi.com" check is replaced by the kernel's origin check, and its `.default()` store is intentionally abandoned. So `KimiWebUsageBridge.swift` is deleted wholesale, as are `KimiWebLoginController.swift` and its `LoginError` (the phase-1 `DeepSeekWebLoginController.swift` deletion, commit `ddc2306`, is the precedent).

---

## 5. Surprises

Things that do not fit the DeepSeek pattern:

1. **Five fields must survive import, not two.** `trafficID`, `deviceID`, `sessionID`, `planName` ride along with `accessToken`/`cookieHeader` and are consumed by `applyKimiAuthentication` (Providers.swift:690-717, native path headers `X-Traffic-Id` / `x-msh-device-id` / `x-msh-session-id`) and the snapshot's `planName` (:650, :679). The descriptor therefore needs the three moved static helpers (~110 lines, including embedded-JSON recursion) — DeepSeek's descriptor had nothing comparable, and its `encodeCredential` is not a template beyond the outer shape.
2. **Kimi's `isEmpty` differs from DeepSeek's.** Kimi: `accessToken` empty AND `cookieHeader` empty (credential :11-13), so a cookie-only import is legal and must remain legal; DeepSeek's `isEmpty` ignores cookies entirely. Also `sessionCredential(from:)` has its own pre-gate (:351-354) that nulls an all-empty extraction but keeps a trafficID-only one — those two "empty" notions must both survive for byte-identical behaviour.
3. **`accountLabel` is intentionally nil** (spec §5.1 line 101). Consequences: settings keeps showing "Kimi Code web session stored locally" (never "connected: <account>") after migration — that is the designed outcome, not a missing piece. Kimi's `planName` must not be repurposed as a label (spec :316-319 says plan fallbacks are not account identifiers).
4. **Two cookie domains, substring match** — `"kimi"` OR `"moonshot"` (controller :315-318). `moonshot.cn`/`moonshot.com` cookies ride the same header. Kimi is *not* one of the named-cookie providers (Zhipu `bigmodel_token_production`, MiniMax `minimax_group_id_v2`, Volcengine Ark `csrfToken`) — the joined header approach is correct for Kimi; no protocol change needed on that axis.
5. **Origin check is stricter than the bridge's.** The bridge accepted any host *containing* `"kimi.com"` (KimiWebUsageBridge.swift:101); the kernel requires `webView.url?.host == descriptor.originHost` exactly (WebSessionController.swift:192) with the default `"www.kimi.com"`. If the console SPA ever settles on a different host (e.g. bare `kimi.com` after a redirect), `ensureOriginLoaded` re-issues `webView.load(loginURL)` on every fetch — a possible reload loop. This cannot be loosened through the descriptor; it is the one place worth an on-device check during acceptance. (Overriding `originHost` to `"kimi.com"` is not a fix — the usage POST is a relative path, so the headless page must stay on `www.kimi.com`.)
6. **Two login URLs exist, the descriptor can hold one.** Window: `…?from=kfc_overview_topbar` (:146); bridge: `…?from=token_health` (:108). Recommended: the window's (window behaviour is byte-preserved; the headless load now uses it too — attribution query only). The bridge variant disappears.
7. **`usageFetchScript` ignores the fetch context** — no month/year (unlike DeepSeek's `month=…&year=…`). The provider must still construct a `WebSessionFetchContext`; values are inert, so pick anything deterministic (Section 4 uses the current Gregorian date).
8. **`usageData` empty-`text` handling is a deliberate improvement.** Old code returned empty `Data` when `text` was `""` (the `as? String` guard passes for empty strings), and the parser then threw a raw `JSONSerialization` error; the plan (:1836-1838) mandates `invalidResponse` instead — whose text matches old `BridgeError.invalidResponse` exactly. Related kernel-vs-old leniency: the kernel treats a missing/non-bool `ok` as failure (WebSessionDescriptor.swift:27), the old controller only failed on explicit `ok == false` — unreachable in practice since the script always emits `ok`.
9. **Import-time debug output shrinks.** The old controller logged, per import, the storage-key snapshot length (:307), cookie names+domains (:327), and the per-field summary (:165); at fetch time it logged the browser state (localStorage/sessionStorage keys, cookie names) via `logBrowserState` (:252-280) and the window URL (:179). The kernel only logs "session imported" (WebSessionController.swift:390), the headless load URL, and envelope failures. The descriptor has no logging hook, so this is lost — debug-only, but it was the primary diagnostic for Kimi session problems. Also `WebSessionLog.javascriptAuthSummary` emits sorted `has*` keys in a different order/labels than the bridge's version ("AccessToken=yes DeviceID=no …" vs "accessToken=… deviceID=…") — again debug-only.
10. **Profile migration discontinuity.** Old Kimi login and bridge both used `WKWebsiteDataStore.default()` (controller :80, bridge :94); existing users' Kimi cookies live there. The kernel profile (`WKWebsiteDataStore(forIdentifier: config.id)`) starts empty, so after the upgrade each Kimi account needs one fresh login before the web fallback works again — the native path (headers from the stored Keychain credential) keeps working meanwhile. This is the same one-time cost DeepSeek's phase-1 migration accepted.
11. **Singleton semantics disappear (by design).** `KimiWebLoginController.shared` and `KimiWebUsageBridge.shared` serialized everything globally and `fetchUsageDataFromActiveSession` depended on the one open window. Per-config kernels now allow two Kimi accounts to log in and fetch concurrently — the point of the feature, but it is a concurrency-behaviour change, and the two-stage "active session first, hidden WebView second" retry never had a per-config notion of "active".
12. **Pre-existing quirk preserved, not fixed:** the native path prefers `PlanNameExtractor().find(in: data)` then the credential (:650) while the web path prefers the credential then the parser (:679) — opposite precedence. The migration should not touch it.
13. **Dead helper:** `findAccessToken(in json: String)` (controller :383-389) has no callers — drop it when moving the helpers (or keep it; it is not part of the extraction path).
14. **Test expectations to update:** `WebSessionDescriptorTests.swift:117` (factory parity) plus, per spec :405-412, new Kimi assertions: `accountLabel == nil`, `shouldIncludeCookie` fixtures (`kimi.com`, `moonshot.cn`, negatives), `usageData` returning the `text` body. No test currently references `KimiWebLoginController`/`KimiWebUsageBridge` directly, so nothing else breaks from the deletions. No kernel change is needed for Kimi — every difference above is either descriptor-expressible or an accepted/one-time behavioural change except item 5, which needs runtime verification rather than code.

**Provenance for this section:** spec §5.1 :98-109, §5.2 :131-135/:148-150, §5.3/:5.5 :281-295, :405-412,:438; plan :1821, :1826-1843; plan phase-1 deletion commit `ddc2306` and routing commit `83b8070`; KimiWebLoginController.swift :47-54, :80, :146, :165, :179, :252-280, :307, :327, :351-354, :383-389; KimiWebUsageBridge.swift :94, :101, :108; WebSessionController.swift :114-152, :192, :196-205, :374, :390; WebSessionDescriptor.swift :27, :81-93; WebSessionLog.swift :4, :19-29; Providers.swift :650, :679, :690-717; SettingsView.swift :533-545.
