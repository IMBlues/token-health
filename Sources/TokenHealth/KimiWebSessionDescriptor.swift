import Foundation

@MainActor
struct KimiWebSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "Kimi"
    let loginInstructions = "Log in with Kimi, wait for Console to load, then import."
    let missingSessionMessage = "No session found. Make sure Kimi Console is logged in."
    let loginURL = URL(string: "https://www.kimi.com/code/console?from=kfc_overview_topbar")!

    /// Verbatim predicate from the old login controller's cookie filter: a cookie belongs
    /// to Kimi when its domain mentions "kimi" or "moonshot". The kernel lowercases `domain`
    /// before calling, so the `lowercased()` here is redundant — kept anyway as the exact
    /// carry-over (DeepSeekWebSessionDescriptor keeps the same redundancy).
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

    /// Composition of the old login controller's import: the storage dump becomes a
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

    /// Kimi returns the envelope's `text` field as the payload. The non-empty check matters
    /// because the kernel defaults a missing `text` to `""`, not nil.
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        guard let envelope = WebSessionScriptEnvelope.parse(scriptResultJSON),
              !envelope.text.isEmpty,
              let data = envelope.text.data(using: .utf8) else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return data
    }

    /// Kimi's credential has no account name, so this always returns nil today. It goes through
    /// the concrete codec for shape parity with DeepSeek.
    func accountLabel(fromCredential credential: String) -> String? {
        KimiWebSessionCredential.decode(from: credential)?.accountLabel
    }

    // MARK: - Import helpers (moved verbatim from the old login controller)

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
