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
    /// That matches the old controller, which fell through to the cookie/page-title fallbacks
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
