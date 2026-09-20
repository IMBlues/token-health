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
