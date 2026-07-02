import AppKit
import Foundation
import WebKit

@MainActor
final class DeepSeekWebLoginController: NSObject {
    static let shared = DeepSeekWebLoginController()

    enum LoginError: LocalizedError {
        case cancelled
        case noSessionFound
        case missingWebView
        case invalidResponse
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "DeepSeek login cancelled"
            case .noSessionFound:
                "DeepSeek login session was not found. Log in first, wait for the usage page to load, then click Import Session."
            case .missingWebView:
                "DeepSeek WebView session is unavailable"
            case .invalidResponse:
                "DeepSeek usage response was invalid"
            case let .requestFailed(message):
                message
            }
        }
    }

    private var windowController: DeepSeekLoginWindowController?
    private var completion: ((Result<String, Error>) -> Void)?

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        Self.debugLog("startLogin")
        self.completion = completion

        let controller = windowController ?? DeepSeekLoginWindowController()
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

    func fetchUsageBundleFromActiveSession(month: Int, year: Int) async throws -> Data {
        guard let windowController else {
            Self.debugLog("active session missing windowController")
            throw LoginError.missingWebView
        }
        return try await windowController.fetchUsageBundle(month: month, year: year)
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
        print("[TokenHealth][DeepSeek] \(message)")
    }

    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let accessToken = (object["hasAccessToken"] as? Bool) == true ? "yes" : "no"
        return "jsAuth accessToken=\(accessToken)"
    }
}

private final class DeepSeekLoginWindowController: NSWindowController, NSWindowDelegate {
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
        statusLabel = NSTextField(labelWithString: "Log in with DeepSeek Platform, wait for Usage to load, then import.")

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
        window.title = "Login with DeepSeek"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        loadDeepSeekUsage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    private func loadDeepSeekUsage() {
        let url = URL(string: "https://platform.deepseek.com/usage")!
        webView.load(URLRequest(url: url))
    }

    @objc private func importSession() {
        Self.debugLog("Import Session clicked, url=\(webView.url?.absoluteString ?? "<nil>")")
        statusLabel.stringValue = "Importing DeepSeek session..."
        importButton.isEnabled = false

        extractStorageCredential { [weak self] storageCredential in
            guard let self else {
                return
            }

            self.extractCookieCredential { cookieHeader in
                self.importButton.isEnabled = true

                var credential = storageCredential ?? DeepSeekWebSessionCredential()
                credential.cookieHeader = cookieHeader
                credential.accountName = credential.accountName ?? Self.accountNameFromPageTitle(self.webView.title)
                Self.debugLog("import storage \(credential.debugSummary)")

                if !credential.isEmpty {
                    self.statusLabel.stringValue = "Session imported."
                    self.onImport?(credential.encodedForStorage())
                } else {
                    self.statusLabel.stringValue = "No session found. Make sure DeepSeek Platform is logged in."
                    self.onImportFailed?()
                }
            }
        }
    }

    func fetchUsageBundle(month: Int, year: Int) async throws -> Data {
        Self.debugLog("active WebView usage fetch url=\(webView.url?.absoluteString ?? "<nil>")")
        try await logBrowserState()

        let script = Self.usageFetchScript(month: month, year: year)
        let raw = try await evaluate(script)
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekWebLoginController.LoginError.invalidResponse
        }

        if let ok = object["ok"] as? Bool, !ok {
            let status = object["status"] as? Int ?? 0
            let authSummary = DeepSeekWebLoginController.javascriptAuthSummary(from: object)
            let text = object["text"] as? String ?? ""
            Self.debugLog("active WebView request failed HTTP \(status), \(authSummary), body=\(text.prefix(220))")
            throw DeepSeekWebLoginController.LoginError.requestFailed("DeepSeek Web fetch HTTP \(status): \(text.prefix(160))")
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
                    continuation.resume(throwing: DeepSeekWebLoginController.LoginError.invalidResponse)
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
                    .filter { $0.domain.lowercased().contains("deepseek") }
                    .map { "\($0.name)@\($0.domain)" }
                    .sorted()
                    .joined(separator: ",")
                continuation.resume(returning: summary)
            }
        }
        Self.debugLog("active WebView httpCookieStore=\(cookieSummary)")
    }

    private func extractStorageCredential(completion: @escaping (DeepSeekWebSessionCredential?) -> Void) {
        let script = """
        (() => {
          const parseJSON = (value) => {
            try { return value ? JSON.parse(value) : null; } catch (_) { return null; }
          };
          const tokenRecord = parseJSON(localStorage.getItem('userToken'));
          const token = tokenRecord && typeof tokenRecord.value === 'string' ? tokenRecord.value : '';
          return JSON.stringify({
            href: location.href,
            accessToken: token
          });
        })();
        """

        webView.evaluateJavaScript(script) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.debugLog("extractStorageCredential no json")
                completion(nil)
                return
            }
            let credential = DeepSeekWebSessionCredential(
                accessToken: object["accessToken"] as? String,
                cookieHeader: nil,
                accountName: Self.accountNameFromPageTitle(nil)
            )
            completion(credential)
        }
    }

    private func extractCookieCredential(completion: @escaping (String?) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let deepSeekCookies = cookies.filter { $0.domain.lowercased().contains("deepseek") }
            guard !deepSeekCookies.isEmpty else {
                Self.debugLog("extractCookieCredential found no deepseek cookies")
                completion(nil)
                return
            }

            let summary = deepSeekCookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ",")
            Self.debugLog("extractCookieCredential cookies=\(summary)")
            let cookieHeader = deepSeekCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            completion(cookieHeader)
        }
    }

    private static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("DeepSeek") else {
            return nil
        }
        return title
    }

    private static func usageFetchScript(month: Int, year: Int) -> String {
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
          const amount = request('/api/v0/usage/amount?month=\(month)&year=\(year)');
          const cost = request('/api/v0/usage/cost?month=\(month)&year=\(year)');
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

    private static func debugLog(_ message: String) {
        DeepSeekWebLoginController.debugLog(message)
    }
}
