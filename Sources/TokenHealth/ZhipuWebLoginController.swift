import AppKit
import Foundation
import WebKit

@MainActor
final class ZhipuWebLoginController: NSObject {
    static let shared = ZhipuWebLoginController()

    enum LoginError: LocalizedError {
        case cancelled
        case noSessionFound
        case missingWebView
        case invalidResponse
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "Zhipu login cancelled"
            case .noSessionFound:
                "Zhipu login session was not found. Log in first, wait for usage stats to load, then click Import Session."
            case .missingWebView:
                "Zhipu WebView session is unavailable"
            case .invalidResponse:
                "Zhipu usage response was invalid"
            case let .requestFailed(message):
                message
            }
        }
    }

    private var windowController: ZhipuLoginWindowController?
    private var completion: ((Result<String, Error>) -> Void)?

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        Self.debugLog("startLogin")
        self.completion = completion

        let controller = windowController ?? ZhipuLoginWindowController()
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

    func fetchUsageDataFromActiveSession() async throws -> Data {
        guard let windowController else {
            Self.debugLog("active session missing windowController")
            throw LoginError.missingWebView
        }
        return try await windowController.fetchUsageData()
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
        print("[TokenHealth][Zhipu] \(message)")
    }

    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let accessToken = (object["hasAccessToken"] as? Bool) == true ? "yes" : "no"
        let org = (object["hasOrganizationID"] as? Bool) == true ? "yes" : "no"
        let project = (object["hasProjectID"] as? Bool) == true ? "yes" : "no"
        return "jsAuth accessToken=\(accessToken) org=\(org) project=\(project)"
    }
}

private final class ZhipuLoginWindowController: NSWindowController, NSWindowDelegate {
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
        statusLabel = NSTextField(labelWithString: "Log in with Zhipu, wait for usage stats to load, then import.")

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
        window.title = "Login with Zhipu"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        loadZhipuUsageStats()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    private func loadZhipuUsageStats() {
        let url = URL(string: "https://bigmodel.cn/coding-plan/team/usage-stats")!
        webView.load(URLRequest(url: url))
    }

    @objc private func importSession() {
        Self.debugLog("Import Session clicked, url=\(webView.url?.absoluteString ?? "<nil>")")
        statusLabel.stringValue = "Importing Zhipu session..."
        importButton.isEnabled = false

        extractStorageCredential { [weak self] storageCredential in
            guard let self else {
                return
            }

            self.extractCookieCredential { cookieHeader, accessToken in
                self.importButton.isEnabled = true

                var credential = storageCredential ?? ZhipuWebSessionCredential()
                credential.cookieHeader = cookieHeader
                credential.accessToken = credential.accessToken ?? accessToken
                credential.planName = credential.planName ?? Self.planNameFromPageTitle(self.webView.title)
                Self.debugLog("import storage \(credential.debugSummary)")

                if !credential.isEmpty {
                    self.statusLabel.stringValue = "Session imported."
                    self.onImport?(credential.encodedForStorage())
                } else {
                    self.statusLabel.stringValue = "No session found. Make sure Zhipu is logged in."
                    self.onImportFailed?()
                }
            }
        }
    }

    func fetchUsageData() async throws -> Data {
        Self.debugLog("active WebView usage fetch url=\(webView.url?.absoluteString ?? "<nil>")")
        try await logBrowserState()

        let script = Self.usageFetchScript()
        let raw = try await evaluate(script)
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw ZhipuWebLoginController.LoginError.invalidResponse
        }

        if let ok = object["ok"] as? Bool, !ok {
            let status = object["status"] as? Int ?? 0
            let authSummary = ZhipuWebLoginController.javascriptAuthSummary(from: object)
            Self.debugLog("active WebView request failed HTTP \(status), \(authSummary), body=\(text.prefix(220))")
            throw ZhipuWebLoginController.LoginError.requestFailed("Zhipu Web fetch HTTP \(status): \(text.prefix(160))")
        }

        Self.debugLog("active WebView usage fetch succeeded, bytes=\(text.utf8.count)")
        guard let responseData = text.data(using: .utf8) else {
            throw ZhipuWebLoginController.LoginError.invalidResponse
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
                    continuation.resume(throwing: ZhipuWebLoginController.LoginError.invalidResponse)
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
                    .filter { $0.domain.lowercased().contains("bigmodel") }
                    .map { "\($0.name)@\($0.domain)" }
                    .sorted()
                    .joined(separator: ",")
                continuation.resume(returning: summary)
            }
        }
        Self.debugLog("active WebView httpCookieStore=\(cookieSummary)")
    }

    private func extractStorageCredential(completion: @escaping (ZhipuWebSessionCredential?) -> Void) {
        let script = """
        (() => JSON.stringify({
          href: location.href,
          organizationID: localStorage.getItem('Bigmodel-Organization') || '',
          projectID: localStorage.getItem('Bigmodel-Project') || ''
        }))();
        """

        webView.evaluateJavaScript(script) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.debugLog("extractStorageCredential no json")
                completion(nil)
                return
            }
            let credential = ZhipuWebSessionCredential(
                accessToken: nil,
                cookieHeader: nil,
                organizationID: object["organizationID"] as? String,
                projectID: object["projectID"] as? String,
                planName: PlanNameExtractor().find(in: object)
            )
            completion(credential)
        }
    }

    private static func planNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("智谱AI开放平台") else {
            return nil
        }
        return title
    }

    private func extractCookieCredential(completion: @escaping (String?, String?) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let zhipuCookies = cookies.filter { $0.domain.lowercased().contains("bigmodel") }
            guard !zhipuCookies.isEmpty else {
                Self.debugLog("extractCookieCredential found no bigmodel cookies")
                completion(nil, nil)
                return
            }

            let summary = zhipuCookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ",")
            Self.debugLog("extractCookieCredential cookies=\(summary)")
            let token = zhipuCookies.first(where: { $0.name == "bigmodel_token_production" })?.value
            let cookieHeader = zhipuCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            completion(cookieHeader, token)
        }
    }

    private static func usageFetchScript() -> String {
        """
        (() => {
          const tokenCookie = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('bigmodel_token_production='));
          const token = tokenCookie ? decodeURIComponent(tokenCookie.split('=').slice(1).join('=')) : '';
          const org = localStorage.getItem('Bigmodel-Organization') || '';
          const project = localStorage.getItem('Bigmodel-Project') || '';
          const xhr = new XMLHttpRequest();
          xhr.open('GET', '/api/monitor/usage/quota/limit?type=2', false);
          xhr.withCredentials = true;
          xhr.setRequestHeader('Accept', 'application/json');
          xhr.setRequestHeader('Content-Type', 'application/json;charset=utf-8');
          xhr.setRequestHeader('Set-Language', 'zh');
          xhr.setRequestHeader('Accept-Language', 'zh-CN');
          if (token) xhr.setRequestHeader('Authorization', token);
          if (org) xhr.setRequestHeader('Bigmodel-Organization', org);
          if (project) xhr.setRequestHeader('Bigmodel-Project', project);
          xhr.send();
          return JSON.stringify({
            ok: xhr.status >= 200 && xhr.status < 300,
            status: xhr.status,
            hasAccessToken: Boolean(token),
            hasOrganizationID: Boolean(org),
            hasProjectID: Boolean(project),
            text: xhr.responseText || ''
          });
        })();
        """
    }

    private static func debugLog(_ message: String) {
        ZhipuWebLoginController.debugLog(message)
    }
}
