import Foundation
import WebKit

@MainActor
final class KimiWebUsageBridge: NSObject, WKNavigationDelegate {
    static let shared = KimiWebUsageBridge()

    enum BridgeError: LocalizedError {
        case missingWebView
        case loadFailed
        case requestFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingWebView:
                "Kimi WebView session is unavailable"
            case .loadFailed:
                "Kimi Console failed to load"
            case let .requestFailed(message):
                message
            case .invalidResponse:
                "Kimi usage response was invalid"
            }
        }
    }

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    func fetchUsageData() async throws -> Data {
        Self.debugLog("fetchUsageData using hidden WebView")
        let webView = webView ?? makeWebView()
        self.webView = webView

        try await ensureKimiOriginLoaded(webView)

        let script = """
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

        let raw = try await evaluate(script, in: webView)
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw BridgeError.invalidResponse
        }

        if let ok = object["ok"] as? Bool, !ok {
            let status = object["status"] as? Int ?? 0
            let authSummary = Self.javascriptAuthSummary(from: object)
            Self.debugLog("hidden WebView request failed HTTP \(status), \(authSummary), body=\(text.prefix(220))")
            throw BridgeError.requestFailed("Kimi Web fetch HTTP \(status): \(text.prefix(160))")
        }

        Self.debugLog("hidden WebView usage fetch succeeded, bytes=\(text.utf8.count)")

        guard let responseData = text.data(using: .utf8) else {
            throw BridgeError.invalidResponse
        }
        return responseData
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        return webView
    }

    private func ensureKimiOriginLoaded(_ webView: WKWebView) async throws {
        if webView.url?.host?.contains("kimi.com") == true {
            Self.debugLog("hidden WebView already on \(webView.url?.absoluteString ?? "<nil>")")
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            let url = URL(string: "https://www.kimi.com/code/console?from=token_health")!
            Self.debugLog("hidden WebView loading \(url.absoluteString)")
            webView.load(URLRequest(url: url))
        }
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let string = value as? String else {
                    continuation.resume(throwing: BridgeError.invalidResponse)
                    return
                }
                continuation.resume(returning: string)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.debugLog("hidden WebView didFinish url=\(webView.url?.absoluteString ?? "<nil>")")
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.debugLog("hidden WebView didFail \(error.localizedDescription)")
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.debugLog("hidden WebView didFailProvisional \(error.localizedDescription)")
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    nonisolated static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1" else {
            return
        }
        print("[TokenHealth][Kimi] \(message)")
    }

    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let accessToken = (object["hasAccessToken"] as? Bool) == true ? "yes" : "no"
        let trafficID = (object["hasTrafficID"] as? Bool) == true ? "yes" : "no"
        let deviceID = (object["hasDeviceID"] as? Bool) == true ? "yes" : "no"
        let sessionID = (object["hasSessionID"] as? Bool) == true ? "yes" : "no"
        return "jsAuth accessToken=\(accessToken) trafficID=\(trafficID) deviceID=\(deviceID) sessionID=\(sessionID)"
    }
}
