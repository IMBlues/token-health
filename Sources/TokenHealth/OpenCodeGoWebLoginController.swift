import AppKit
import Foundation
import WebKit

@MainActor
final class OpenCodeGoWebLoginController: NSObject {
    static let shared = OpenCodeGoWebLoginController()

    enum LoginError: LocalizedError {
        case cancelled
        case noSessionFound
        case missingWebView
        case invalidResponse
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "OpenCode Go login cancelled"
            case .noSessionFound:
                "OpenCode Go login session was not found. Log in with GitHub or Google, wait for the console to load, then click Import Session."
            case .missingWebView:
                "OpenCode Go WebView session is unavailable"
            case .invalidResponse:
                "OpenCode Go usage response was invalid"
            case let .requestFailed(message):
                message
            }
        }
    }

    private var windowController: OpenCodeGoLoginWindowController?
    private var completion: ((Result<String, Error>) -> Void)?

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        Self.debugLog("startLogin")
        self.completion = completion

        let controller = windowController ?? OpenCodeGoLoginWindowController()
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

    func fetchUsageBundleFromActiveSession() async throws -> Data {
        guard let windowController else {
            Self.debugLog("active session missing windowController")
            throw LoginError.missingWebView
        }
        return try await windowController.fetchUsageBundle()
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
        print("[TokenHealth][OpenCodeGo] \(message)")
    }

    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let hasSession = (object["hasSession"] as? Bool) == true ? "yes" : "no"
        return "jsAuth session=\(hasSession)"
    }
}

private final class OpenCodeGoLoginWindowController: NSWindowController, NSWindowDelegate {
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
        statusLabel = NSTextField(labelWithString: "Log in with GitHub or Google at opencode.ai/auth, wait for the console to load, then import.")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
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
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Login with OpenCode Go"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        loadConsole()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    private func loadConsole() {
        let url = URL(string: "https://console.opencode.ai/")!
        webView.load(URLRequest(url: url))
    }

    @objc private func importSession() {
        Self.debugLog("Import Session clicked, url=\(webView.url?.absoluteString ?? "<nil>")")
        statusLabel.stringValue = "Importing OpenCode Go session..."
        importButton.isEnabled = false

        extractCookieCredential { [weak self] cookieHeader in
            guard let self else {
                return
            }

            self.importButton.isEnabled = true
            var credential = OpenCodeGoWebSessionCredential()
            credential.cookieHeader = cookieHeader
            credential.accountName = credential.accountName ?? Self.accountNameFromPageTitle(self.webView.title)
            Self.debugLog("import credential \(credential.debugSummary)")

            if !credential.isEmpty {
                self.statusLabel.stringValue = "Session imported."
                self.onImport?(credential.encodedForStorage())
            } else {
                self.statusLabel.stringValue = "No session found. Make sure the OpenCode console is logged in."
                self.onImportFailed?()
            }
        }
    }

    func fetchUsageBundle() async throws -> Data {
        Self.debugLog("active WebView usage fetch url=\(webView.url?.absoluteString ?? "<nil>")")
        try await logBrowserState()

        let raw = try await evaluate(Self.usageFetchScript())
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeGoWebLoginController.LoginError.invalidResponse
        }

        if let ok = object["ok"] as? Bool, !ok {
            let status = object["status"] as? Int ?? 0
            let authSummary = OpenCodeGoWebLoginController.javascriptAuthSummary(from: object)
            let text = object["text"] as? String ?? ""
            Self.debugLog("active WebView request failed HTTP \(status), \(authSummary), body=\(text.prefix(220))")
            throw OpenCodeGoWebLoginController.LoginError.requestFailed("OpenCode Go Web fetch HTTP \(status): \(text.prefix(160))")
        }

        Self.debugLog("active WebView usage fetch succeeded, bytes=\(data.count)")
        return data
    }

    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let string = value as? String else {
                    continuation.resume(throwing: OpenCodeGoWebLoginController.LoginError.invalidResponse)
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
          cookieNames: document.cookie.split(';').map(s => s.trim().split('=')[0]).filter(Boolean)
        }))();
        """

        if let raw = try? await evaluate(storageScript) {
            Self.debugLog("active WebView browserState=\(raw)")
        }

        let cookieSummary = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let summary = cookies
                    .filter(Self.isOpenCodeAuthCookie)
                    .map { "\($0.name)@\($0.domain)" }
                    .sorted()
                    .joined(separator: ",")
                continuation.resume(returning: summary)
            }
        }
        Self.debugLog("active WebView httpCookieStore=\(cookieSummary)")
    }

    private func extractCookieCredential(completion: @escaping (String?) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let openCodeCookies = cookies.filter(Self.isOpenCodeAuthCookie)
            guard !openCodeCookies.isEmpty else {
                Self.debugLog("extractCookieCredential found no opencode cookies")
                completion(nil)
                return
            }

            let summary = openCodeCookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ",")
            Self.debugLog("extractCookieCredential cookies=\(summary)")
            let cookieHeader = openCodeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            completion(cookieHeader)
        }
    }

    private static func isOpenCodeAuthCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain == "opencode.ai" || domain.hasSuffix(".opencode.ai")
    }

    private static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("OpenCode") else {
            return nil
        }
        return title
    }

    private static func usageFetchScript() -> String {
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

    private static func debugLog(_ message: String) {
        OpenCodeGoWebLoginController.debugLog(message)
    }
}
