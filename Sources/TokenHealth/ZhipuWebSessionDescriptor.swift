import Foundation

@MainActor
struct ZhipuWebSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "Zhipu"
    let loginInstructions = "Log in with Zhipu, wait for usage stats to load, then import."
    let missingSessionMessage = "No session found. Make sure Zhipu is logged in."
    let loginURL = URL(string: "https://bigmodel.cn/coding-plan/team/usage-stats")!
    // originHost is deliberately omitted: the protocol default is `loginURL.host`, i.e.
    // "bigmodel.cn" — the site's login page, usage endpoint and native endpoints all share it.

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
    /// `=` as the value, because cookie values may contain `=`. No decoding: the old Swift import
    /// stored `WKHTTPCookie.value` undecoded.
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
