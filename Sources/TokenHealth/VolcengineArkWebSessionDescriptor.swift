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
