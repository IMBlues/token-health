import AppKit
import Foundation
import WebKit

@MainActor
final class MiniMaxWebLoginController: NSObject {
    static let shared = MiniMaxWebLoginController()

    enum LoginError: LocalizedError {
        case cancelled
        case noSessionFound
        case missingWebView
        case invalidResponse
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "MiniMax login cancelled"
            case .noSessionFound:
                "MiniMax login session was not found. Log in first, wait for the usage page to load, then click Import Session."
            case .missingWebView:
                "MiniMax WebView session is unavailable"
            case .invalidResponse:
                "MiniMax usage response was invalid"
            case let .requestFailed(message):
                message
            }
        }
    }

    private var windowController: MiniMaxLoginWindowController?
    private var completion: ((Result<String, Error>) -> Void)?

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        Self.debugLog("startLogin")
        self.completion = completion

        let controller = windowController ?? MiniMaxLoginWindowController()
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
        print("[TokenHealth][MiniMax] \(message)")
    }

    nonisolated static func javascriptAuthSummary(from object: [String: Any]) -> String {
        let accessToken = (object["hasAccessToken"] as? Bool) == true ? "yes" : "no"
        let groupID = (object["hasGroupID"] as? Bool) == true ? "yes" : "no"
        return "jsAuth accessToken=\(accessToken) group=\(groupID)"
    }
}

private final class MiniMaxLoginWindowController: NSWindowController, NSWindowDelegate {
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
        statusLabel = NSTextField(labelWithString: "Log in with MiniMax Platform, wait for Usage to load, then import.")

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
        window.title = "Login with MiniMax"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        loadMiniMaxUsage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    private func loadMiniMaxUsage() {
        let url = URL(string: "https://platform.minimaxi.com/console/usage")!
        webView.load(URLRequest(url: url))
    }

    @objc private func importSession() {
        Self.debugLog("Import Session clicked, url=\(webView.url?.absoluteString ?? "<nil>")")
        statusLabel.stringValue = "Importing MiniMax session..."
        importButton.isEnabled = false

        extractStorageCredential { [weak self] storageCredential in
            guard let self else {
                return
            }

            self.extractCookieCredential { cookieHeader, cookieGroupID in
                self.importButton.isEnabled = true

                var credential = storageCredential ?? MiniMaxWebSessionCredential()
                credential.cookieHeader = cookieHeader
                credential.groupID = credential.groupID ?? cookieGroupID
                credential.accountName = credential.accountName ?? Self.accountNameFromPageTitle(self.webView.title)
                Self.debugLog("import storage \(credential.debugSummary)")

                if !credential.isEmpty {
                    self.statusLabel.stringValue = "Session imported."
                    self.onImport?(credential.encodedForStorage())
                } else {
                    self.statusLabel.stringValue = "No session found. Make sure MiniMax Platform is logged in."
                    self.onImportFailed?()
                }
            }
        }
    }

    func fetchUsageBundle() async throws -> Data {
        Self.debugLog("active WebView usage fetch url=\(webView.url?.absoluteString ?? "<nil>")")
        try await logBrowserState()

        let raw = try await evaluate(Self.usageFetchScript())
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiniMaxWebLoginController.LoginError.invalidResponse
        }

        if let ok = object["ok"] as? Bool, !ok {
            let status = object["status"] as? Int ?? 0
            let authSummary = MiniMaxWebLoginController.javascriptAuthSummary(from: object)
            let text = object["text"] as? String ?? ""
            Self.debugLog("active WebView request failed HTTP \(status), \(authSummary), body=\(text.prefix(220))")
            throw MiniMaxWebLoginController.LoginError.requestFailed("MiniMax Web fetch HTTP \(status): \(text.prefix(160))")
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
                    continuation.resume(throwing: MiniMaxWebLoginController.LoginError.invalidResponse)
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
                    .filter(Self.isMiniMaxAuthCookie)
                    .map { "\($0.name)@\($0.domain)" }
                    .sorted()
                    .joined(separator: ",")
                continuation.resume(returning: summary)
            }
        }
        Self.debugLog("active WebView httpCookieStore=\(cookieSummary)")
    }

    private func extractStorageCredential(completion: @escaping (MiniMaxWebSessionCredential?) -> Void) {
        let script = """
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

        webView.evaluateJavaScript(script) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.debugLog("extractStorageCredential no json")
                completion(nil)
                return
            }
            let credential = MiniMaxWebSessionCredential(
                accessToken: object["accessToken"] as? String,
                cookieHeader: nil,
                groupID: object["groupID"] as? String,
                accountName: object["accountName"] as? String
            )
            completion(credential)
        }
    }

    private func extractCookieCredential(completion: @escaping (String?, String?) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let miniMaxCookies = cookies.filter(Self.isMiniMaxAuthCookie)
            guard !miniMaxCookies.isEmpty else {
                Self.debugLog("extractCookieCredential found no minimax cookies")
                completion(nil, nil)
                return
            }

            let summary = miniMaxCookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ",")
            Self.debugLog("extractCookieCredential cookies=\(summary)")
            let cookieHeader = miniMaxCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            let groupID = miniMaxCookies.first(where: { $0.name == "minimax_group_id_v2" })?.value
            completion(cookieHeader, groupID)
        }
    }

    private static func isMiniMaxAuthCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain.contains("minimaxi.com") || domain.contains("minimax.io")
    }

    private static func accountNameFromPageTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty, !title.contains("MiniMax") else {
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

    private static func debugLog(_ message: String) {
        MiniMaxWebLoginController.debugLog(message)
    }
}
