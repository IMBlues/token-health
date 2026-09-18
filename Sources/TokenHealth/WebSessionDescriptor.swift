import Foundation

struct WebSessionFetchContext {
    let year: Int
    let month: Int
}

/// All six providers' usage scripts return the same envelope shape.
struct WebSessionScriptEnvelope {
    let ok: Bool
    let status: Int
    let text: String

    static func object(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func parse(_ json: String) -> WebSessionScriptEnvelope? {
        guard let object = object(from: json) else {
            return nil
        }
        return WebSessionScriptEnvelope(
            ok: (object["ok"] as? Bool) ?? false,
            status: (object["status"] as? Int) ?? 0,
            text: (object["text"] as? String) ?? ""
        )
    }
}

@MainActor
protocol WebSessionDescriptor {
    /// Brand name used in window titles, error copy and logs — "Kimi", not `ProviderKind.title`
    /// ("Kimi Code"). Every provider's existing window title is "Login with <this>".
    var providerTitle: String { get }

    /// Footer hint in the login window, before anything is imported. Provider-specific, because
    /// each console's landing page differs.
    var loginInstructions: String { get }

    /// Shown when Import found nothing to import.
    var missingSessionMessage: String { get }

    /// Page the login window loads, and the origin the headless WebView must be on.
    var loginURL: URL { get }

    /// Host the headless WebView must already be on before `usageFetchScript` runs. Defaults to
    /// `loginURL.host`; override only if a provider's fetch legitimately runs from another host.
    var originHost: String { get }

    /// Whether a cookie belongs to this provider. The kernel lowercases `domain` before calling.
    func shouldIncludeCookie(domain: String) -> Bool

    /// Executed on the login page, returns a JSON string; the kernel does not parse it
    var extractionScript: String { get }

    /// Builds the Keychain credential string. `cookieHeader` is the matching cookies joined as
    /// `name=value` pairs with `"; "`, in WebKit's own order, unencoded. Five phase-2 providers must
    /// pull a specifically-named cookie out of it (Zhipu's `bigmodel_token_production`, MiniMax's
    /// `minimax_group_id_v2`, Volcengine Ark's `csrfToken`), so match on the full name before the
    /// first `=`, never on a prefix.
    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String?

    /// Executed in the authenticated page, returns the script envelope
    func usageFetchScript(context: WebSessionFetchContext) -> String

    /// Extracts the bytes the provider's parser needs from the script envelope
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data

    /// Decodes the account identifier from the Keychain ciphertext for display in settings; nil when it cannot be decoded
    func accountLabel(fromCredential credential: String) -> String?

    /// Whether an `ok == false` envelope means the session is gone rather than a site error.
    func isAuthenticationFailure(scriptResultJSON: String) -> Bool
}

extension WebSessionDescriptor {
    var originHost: String {
        loginURL.host ?? ""
    }

    /// Default: the envelope reports a failure with a 401 or 403 status. Override when a site
    /// signals an expired session differently.
    func isAuthenticationFailure(scriptResultJSON: String) -> Bool {
        guard let envelope = WebSessionScriptEnvelope.parse(scriptResultJSON),
              !envelope.ok else {
            return false
        }
        return envelope.status == 401 || envelope.status == 403
    }

    func accountLabel(fromCredential credential: String) -> String? {
        nil
    }
}

struct WebSessionDescriptorFactory {
    func descriptor(for kind: ProviderKind) -> (any WebSessionDescriptor)? {
        switch kind {
        case .deepSeek:
            DeepSeekWebSessionDescriptor()
        case .kimiCode, .zhipuCode, .miniMax, .volcengineArk, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
    }
}
