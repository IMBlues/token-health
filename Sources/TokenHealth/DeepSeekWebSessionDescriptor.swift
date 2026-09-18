import Foundation

@MainActor
struct DeepSeekSessionDescriptor: WebSessionDescriptor {
    let providerTitle = "DeepSeek"
    let loginURL = URL(string: "https://platform.deepseek.com/usage")!
    let originHost = "platform.deepseek.com"

    func shouldIncludeCookie(domain: String) -> Bool {
        domain.lowercased().contains("deepseek")
    }

    var extractionScript: String {
        """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const tokenRecord = parseJSON(localStorage.getItem('userToken'));
          const token = tokenRecord && typeof tokenRecord.value === 'string' ? tokenRecord.value : '';
          let userSummary = null;
          try {
            const summary = new XMLHttpRequest();
            summary.open('GET', '/api/v0/users/get_user_summary', false);
            summary.withCredentials = true;
            summary.setRequestHeader('Accept', 'application/json');
            if (token) summary.setRequestHeader('Authorization', token.startsWith('Bearer ') ? token : `Bearer ${token}`);
            summary.send();
            userSummary = summary.status >= 200 && summary.status < 300 ? parseJSON(summary.responseText || '') : null;
          } catch (_) {
            userSummary = null;
          }
          return JSON.stringify({
            href: location.href,
            accessToken: token,
            userSummary: userSummary
          });
        })();
        """
    }

    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String? {
        guard let data = extractionJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let credential = DeepSeekWebSessionCredential(
            accessToken: object["accessToken"] as? String,
            cookieHeader: cookieHeader,
            accountName: Self.accountLabel(fromSummary: object["userSummary"])
                ?? Self.accountNameFromPageTitle(pageTitle)
        )
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
          const tokenRecord = parseJSON(localStorage.getItem('userToken'));
          const token = tokenRecord && typeof tokenRecord.value === 'string' ? tokenRecord.value : '';
          const request = (path) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', path, false);
            xhr.withCredentials = true;
            xhr.setRequestHeader('Accept', 'application/json');
            if (token) xhr.setRequestHeader('Authorization', token.startsWith('Bearer ') ? token : `Bearer ${token}`);
            xhr.send();
            return {
              ok: xhr.status >= 200 && xhr.status < 300,
              status: xhr.status,
              text: xhr.responseText || '',
              json: parseJSON(xhr.responseText || '')
            };
          };
          const summary = request('/api/v0/users/get_user_summary');
          const amount = request('/api/v0/usage/amount?month=\(context.month)&year=\(context.year)');
          const cost = request('/api/v0/usage/cost?month=\(context.month)&year=\(context.year)');
          const firstFailure = [summary, amount, cost].find(item => !item.ok);
          return JSON.stringify({
            ok: !firstFailure,
            status: firstFailure ? firstFailure.status : 200,
            text: firstFailure ? firstFailure.text : '',
            hasAccessToken: Boolean(token),
            summary: summary.json,
            amount: amount.json,
            cost: cost.json
          });
        })();
        """
    }

    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data {
        guard let data = scriptResultJSON.data(using: .utf8) else {
            throw WebSessionError.invalidResponse(providerTitle: providerTitle)
        }
        return data
    }

    func accountLabel(fromCredential credential: String) -> String? {
        DeepSeekWebSessionCredential.decode(from: credential)?.accountLabel
    }

    /// The site's response body has no stable public field documentation, so pick by
    /// "email first, then plain numeric id"; returns nil when nothing is found and the
    /// caller falls back to the page title.
    nonisolated static func accountLabel(fromSummary summary: Any?) -> String? {
        guard let summary else {
            return nil
        }
        var candidates: [String] = []
        collectStrings(from: summary, into: &candidates)
        // Email first: purely numeric fields like created_at / id are plentiful, so they must
        // not displace the email.
        if let email = candidates.first(where: looksLikeEmail) {
            return email
        }
        return candidates.first(where: looksLikeNumericIdentifier)
    }

    private nonisolated static func collectStrings(from value: Any, into result: inout [String]) {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
            return
        }
        if let array = value as? [Any] {
            for item in array {
                collectStrings(from: item, into: &result)
            }
            return
        }
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                collectStrings(from: object[key] as Any, into: &result)
            }
        }
    }

    private nonisolated static func looksLikeEmail(_ value: String) -> Bool {
        guard let atIndex = value.firstIndex(of: "@") else {
            return false
        }
        let domain = value[value.index(after: atIndex)...]
        return domain.contains(".") && !value.hasPrefix("@") && !value.hasSuffix("@")
    }

    private nonisolated static func looksLikeNumericIdentifier(_ value: String) -> Bool {
        value.count >= 6 && value.allSatisfy(\.isNumber)
    }

    private nonisolated static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("DeepSeek") else {
            return nil
        }
        return title
    }
}
