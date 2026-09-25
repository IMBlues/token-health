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

    /// The console usage endpoints take a fixed 30-day window; the context is intentionally unused.
    func usageFetchScript(context: WebSessionFetchContext) -> String {
        """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const request = (path, headers) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', path, false);
            xhr.withCredentials = true;
            xhr.setRequestHeader('Accept', 'application/json');
            if (headers) {
              for (const name of Object.keys(headers)) {
                xhr.setRequestHeader(name, headers[name]);
              }
            }
            xhr.send();
            return {
              ok: xhr.status >= 200 && xhr.status < 300,
              status: xhr.status,
              text: xhr.responseText || '',
              json: parseJSON(xhr.responseText || '')
            };
          };
          const session = request('/auth/session');
          const orgs = request('/api/me/orgs');
          const workspaces = Array.isArray(orgs.json)
            ? orgs.json.map((item) => item && item.id).filter(Boolean)
            : [];
          // Scoped console endpoints need x-org-id; pick the first workspace that has a Go
          // subscription, else keep the first workspace's response so "not subscribed" survives.
          // A failed probe is skipped, matching the native path. The 5 must stay in sync with the
          // provider's workspaceProbeLimit.
          const hasAccess = (json) => {
            if (!json) return false;
            const go = json.goStatus || json;
            if (go.access) return true;
            return go.subscriptionStatus === 'active' || go.subscriptionStatus === 'grace';
          };
          let chosen = null;
          let workspaceId = workspaces.length > 0 ? workspaces[0] : null;
          for (const id of workspaces.slice(0, 5)) {
            const attempt = request('/api/go/status', { 'x-org-id': id });
            if (chosen === null) {
              chosen = attempt;
              workspaceId = id;
            }
            if (hasAccess(attempt.json)) {
              chosen = attempt;
              workspaceId = id;
              break;
            }
          }
          // No probe ran (the workspace list itself failed or was empty). Carry the orgs request's
          // auth failure through untouched so the kernel still maps an expired session; anything
          // else is a plain "no workspace" with a 400.
          const orgsFailed = orgs.status === 401 || orgs.status === 403;
          const status = chosen || {
            ok: false,
            status: orgsFailed ? orgs.status : 400,
            text: orgsFailed && orgs.text ? orgs.text : 'OpenCode Go has no workspace',
            json: null
          };
          const scoped = (path) => workspaceId
            ? request(path, { 'x-org-id': workspaceId })
            : { ok: false, status: 0, text: '', json: null };
          const summary = scoped('/api/usage/summary?range=30d');
          const byDay = scoped('/api/usage/cost-by-day?range=30d&bucket=day');
          const models = scoped('/api/usage/models?range=30d&pageSize=100&costOrder=desc');
          // ok/status/text describe the go/status request alone: the kernel throws on ok == false.
          // A 2xx with an unparseable body (HTML from an expired session) is a failure too — it
          // must not reach the parser, which would read it as "not subscribed".
          const statusOk = status.ok && status.json !== null;
          const failed = !statusOk;
          return JSON.stringify({
            ok: !failed,
            status: status.status,
            text: failed ? (status.text || 'OpenCode Go status response was not JSON') : '',
            hasSession: Boolean(session.ok && session.json && session.json.user),
            goStatus: status.json,
            session: session.ok ? session.json : null,
            orgs: Array.isArray(orgs.json) ? orgs.json : null,
            workspaceId: workspaceId,
            usageSummary: summary.ok ? summary.json : null,
            usageByDay: byDay.ok ? byDay.json : null,
            usageModels: models.ok ? models.json : null
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
