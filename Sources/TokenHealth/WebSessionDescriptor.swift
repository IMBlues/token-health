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
    /// Provider name used for window titles, error copy, and logs, e.g. "DeepSeek"
    var providerTitle: String { get }

    /// Address loaded by the login window; it also defines the origin the headless WebView must be on
    var loginURL: URL { get }

    /// Host the headless WebView compares against to decide it is "already on the right site"
    var originHost: String { get }

    /// Whether a cookie belongs to this provider
    func shouldIncludeCookie(domain: String) -> Bool

    /// Executed on the login page, returns a JSON string; the kernel does not parse it
    var extractionScript: String { get }

    /// Assembles the Keychain credential string from the extraction result, cookies, and page title; nil when it cannot be assembled
    func encodeCredential(extractionJSON: String, cookieHeader: String?, pageTitle: String?) -> String?

    /// Executed in the authenticated page, returns the script envelope
    func usageFetchScript(context: WebSessionFetchContext) -> String

    /// Extracts the bytes the provider's parser needs from the script envelope
    func usageData(fromScriptResult scriptResultJSON: String) throws -> Data

    /// Decodes the account identifier from the Keychain ciphertext for display in settings; nil when it cannot be decoded
    func accountLabel(fromCredential credential: String) -> String?
}

extension WebSessionDescriptor {
    /// Default rule: the envelope has `ok == false` and `status` is 401 / 403.
    /// Deliberately a protocol extension (static dispatch, not overridable): all six providers
    /// currently report unauthenticated as 401/403.
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
            DeepSeekSessionDescriptor()
        case .kimiCode, .zhipuCode, .miniMax, .volcengineArk, .openCodeGo,
             .openAI, .anthropic, .cursor, .codex, .genericHTTP, .demo:
            nil
        }
    }
}
