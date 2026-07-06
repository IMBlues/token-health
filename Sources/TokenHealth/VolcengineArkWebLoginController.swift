import AppKit
import Foundation
import WebKit

@MainActor
final class VolcengineArkWebLoginController: NSObject {
    static let shared = VolcengineArkWebLoginController()

    enum LoginError: LocalizedError {
        case cancelled
        case noSessionFound
        case missingWebView
        case invalidResponse
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "Volcengine Ark login cancelled"
            case .noSessionFound:
                "Volcengine Ark session was not found. Log in first, wait for the Agent Plan page to load, then click Import Session."
            case .missingWebView:
                "Volcengine Ark WebView session is unavailable"
            case .invalidResponse:
                "Volcengine Ark usage response was invalid"
            case let .requestFailed(message):
                message
            }
        }
    }

    private var windowController: VolcengineArkLoginWindowController?
    private var completion: ((Result<String, Error>) -> Void)?

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        VolcengineArkWebLoginController.debugLog("startLogin")
        self.completion = completion

        let controller = windowController ?? VolcengineArkLoginWindowController()
        controller.onImport = { [weak self] credential in
            self?.finish(.success(credential))
        }
        controller.onCancel = { [weak self] in
            self?.finish(.failure(LoginError.cancelled))
        }
        controller.onImportFailed = { [weak self] in
            self?.finish(.failure(LoginError.noSessionFound), keepWindowOpen: true)
        }
        windowController = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func fetchAFPUsageFromActiveSession() async throws -> Data {
        guard let windowController else {
            VolcengineArkWebLoginController.debugLog("active session missing windowController")
            throw LoginError.missingWebView
        }
        return try await windowController.fetchAFPUsage()
    }

    private func finish(_ result: Result<String, Error>, keepWindowOpen: Bool = false) {
        let completion = completion
        self.completion = nil
        completion?(result)

        guard !keepWindowOpen else {
            return
        }

        windowController?.window?.orderOut(nil)
    }

    nonisolated static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["TOKEN_HEALTH_DEBUG"] == "1" else {
            return
        }
        print("[TokenHealth][VolcengineArk] \(message)")
    }

    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let csrf = (object["hasCSRF"] as? Bool) == true ? "yes" : "no"
        return "jsAuth csrf=\(csrf)"
    }
}

private final class VolcengineArkLoginWindowController: NSWindowController, NSWindowDelegate {
    var onImport: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onImportFailed: (() -> Void)?

    private let webView: WKWebView
    private let importButton: NSButton
    private let statusLabel: NSTextField

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: configuration)
        importButton = NSButton(title: "Import Session", target: nil, action: nil)
        statusLabel = NSTextField(labelWithString: "Log in with Volcengine Ark, wait for Agent Plan to load, then import.")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780))
        let footer = NSView()

        webView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        importButton.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(webView)
        container.addSubview(footer)
        footer.addSubview(statusLabel)
        footer.addSubview(importButton)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),

            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: importButton.leadingAnchor, constant: -12),

            importButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            importButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Login with Volcengine Ark"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        loadAgentPlan()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    private func loadAgentPlan() {
        let url = URL(string: "https://console.volcengine.com/ark/region:cn-beijing/subscription/agent-plan")!
        webView.load(URLRequest(url: url))
    }

    @objc private func importSession() {
        VolcengineArkWebLoginController.debugLog("Import Session clicked, url=\(webView.url?.absoluteString ?? "<nil>")")
        statusLabel.stringValue = "Importing Volcengine Ark session..."
        importButton.isEnabled = false

        extractStorageCredential { [weak self] storageCredential in
            guard let self else {
                return
            }

            self.extractCookieCredential { cookieHeader, cookieCSRF in
                self.importButton.isEnabled = true

                var credential = storageCredential ?? VolcengineArkWebSessionCredential()
                credential.cookieHeader = cookieHeader
                credential.csrfToken = credential.csrfToken ?? cookieCSRF
                credential.accountName = credential.accountName ?? Self.accountNameFromPageTitle(self.webView.title)
                VolcengineArkWebLoginController.debugLog("import \(credential.debugSummary)")

                if !credential.isEmpty {
                    self.statusLabel.stringValue = "Session imported."
                    self.onImport?(credential.encodedForStorage())
                } else {
                    self.statusLabel.stringValue = "No session found. Make sure Volcengine Ark is logged in."
                    self.onImportFailed?()
                }
            }
        }
    }

    func fetchAFPUsage() async throws -> Data {
        VolcengineArkWebLoginController.debugLog("active WebView AFP usage fetch url=\(webView.url?.absoluteString ?? "<nil>")")
        try await logBrowserState()

        let raw = try await evaluate(Self.afpUsageFetchScript())
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw VolcengineArkWebLoginController.LoginError.invalidResponse
        }

        if let ok = object["ok"] as? Bool, !ok {
            let status = object["status"] as? Int ?? 0
            let authSummary = VolcengineArkWebLoginController.javascriptAuthSummary(from: object)
            VolcengineArkWebLoginController.debugLog("active WebView request failed HTTP \(status), \(authSummary), body=\(text.prefix(220))")
            throw VolcengineArkWebLoginController.LoginError.requestFailed("Volcengine Ark Web fetch HTTP \(status): \(text.prefix(160))")
        }

        VolcengineArkWebLoginController.debugLog("active WebView AFP usage fetch succeeded, bytes=\(text.utf8.count)")
        guard let responseData = text.data(using: .utf8) else {
            throw VolcengineArkWebLoginController.LoginError.invalidResponse
        }
        return responseData
    }

    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let string = value as? String else {
                    continuation.resume(throwing: VolcengineArkWebLoginController.LoginError.invalidResponse)
                    return
                }
                continuation.resume(returning: string)
            }
        }
    }

    private func logBrowserState() async throws {
        let storageScript = """
        (() => JSON.stringify({
          href: location.href,
          localStorageKeys: Object.keys(localStorage),
          sessionStorageKeys: Object.keys(sessionStorage),
          cookieNames: document.cookie.split(';').map(s => s.trim().split('=')[0]).filter(Boolean)
        }))();
        """

        if let raw = try? await evaluate(storageScript) {
            VolcengineArkWebLoginController.debugLog("active WebView browserState=\(raw)")
        }

        let cookieSummary = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let summary = cookies
                    .filter(Self.isVolcengineCookie)
                    .map { "\($0.name)@\($0.domain)" }
                    .sorted()
                    .joined(separator: ",")
                continuation.resume(returning: summary)
            }
        }
        VolcengineArkWebLoginController.debugLog("active WebView httpCookieStore=\(cookieSummary)")
    }

    private func extractStorageCredential(completion: @escaping (VolcengineArkWebSessionCredential?) -> Void) {
        webView.evaluateJavaScript(Self.sessionExtractionScript()) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                VolcengineArkWebLoginController.debugLog("extractStorageCredential no json")
                completion(nil)
                return
            }
            let credential = VolcengineArkWebSessionCredential(
                cookieHeader: nil,
                csrfToken: object["csrfToken"] as? String,
                accountName: object["accountName"] as? String
            )
            completion(credential)
        }
    }

    private func extractCookieCredential(completion: @escaping (String?, String?) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let volcCookies = cookies.filter(Self.isVolcengineCookie)
            guard !volcCookies.isEmpty else {
                VolcengineArkWebLoginController.debugLog("extractCookieCredential found no Volcengine cookies")
                completion(nil, nil)
                return
            }

            let summary = volcCookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ",")
            VolcengineArkWebLoginController.debugLog("extractCookieCredential cookies=\(summary)")

            let cookieHeader = volcCookies
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            let csrfToken = volcCookies.first { $0.name == "csrfToken" }?.value
            completion(cookieHeader, csrfToken)
        }
    }

    private static func isVolcengineCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain.contains("volcengine")
    }

    private static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return title == "火山方舟" ? "Agent Plan" : title
    }

    private static func sessionExtractionScript() -> String {
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

    private static func afpUsageFetchScript() -> String {
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
}
