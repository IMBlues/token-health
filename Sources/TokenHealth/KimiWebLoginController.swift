import AppKit
import Foundation
import WebKit

@MainActor
final class KimiWebLoginController: NSObject {
    static let shared = KimiWebLoginController()

    enum LoginError: LocalizedError {
        case cancelled
        case noSessionFound

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "Kimi login cancelled"
            case .noSessionFound:
                "Kimi login session was not found. Log in first, wait for the console page, then click Import Session."
            }
        }
    }

    private var windowController: KimiLoginWindowController?
    private var completion: ((Result<String, Error>) -> Void)?

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        KimiWebUsageBridge.debugLog("startLogin")
        self.completion = completion

        let controller = windowController ?? KimiLoginWindowController()
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
            KimiWebUsageBridge.debugLog("active session missing windowController")
            throw KimiWebUsageBridge.BridgeError.missingWebView
        }
        KimiWebUsageBridge.debugLog("fetchUsageDataFromActiveSession")
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
}

private final class KimiLoginWindowController: NSWindowController, NSWindowDelegate {
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
        statusLabel = NSTextField(labelWithString: "Log in with Kimi, wait for Console to load, then import.")

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
        window.title = "Login with Kimi"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        loadKimiConsole()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    private func loadKimiConsole() {
        let url = URL(string: "https://www.kimi.com/code/console?from=kfc_overview_topbar")!
        webView.load(URLRequest(url: url))
    }

    @objc private func importSession() {
        KimiWebUsageBridge.debugLog("Import Session clicked, url=\(webView.url?.absoluteString ?? "<nil>")")
        statusLabel.stringValue = "Importing Kimi session..."
        importButton.isEnabled = false

        extractStorageCredential { [weak self] storageCredential in
            guard let self else {
                return
            }

            self.extractCookieCredential { cookieHeader in
                self.importButton.isEnabled = true

                var credential = storageCredential ?? KimiWebSessionCredential()
                credential.cookieHeader = cookieHeader
                KimiWebUsageBridge.debugLog("import storage accessToken=\((credential.accessToken ?? "").isEmpty ? "no" : "yes") trafficID=\((credential.trafficID ?? "").isEmpty ? "no" : "yes") deviceID=\((credential.deviceID ?? "").isEmpty ? "no" : "yes") sessionID=\((credential.sessionID ?? "").isEmpty ? "no" : "yes") plan=\((credential.planName ?? "").isEmpty ? "no" : "yes") cookieLength=\(cookieHeader?.count ?? 0)")

                if !credential.isEmpty {
                    self.statusLabel.stringValue = "Session imported."
                    self.onImport?(credential.encodedForStorage())
                } else {
                    self.statusLabel.stringValue = "No session found. Make sure Kimi Console is logged in."
                    self.onImportFailed?()
                }
            }
        }
    }

    func fetchUsageData() async throws -> Data {
        KimiWebUsageBridge.debugLog("active WebView usage fetch url=\(webView.url?.absoluteString ?? "<nil>")")
        try await logBrowserState()

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

        let raw = try await evaluate(script)
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw KimiWebUsageBridge.BridgeError.invalidResponse
        }

        if let ok = object["ok"] as? Bool, !ok {
            let status = object["status"] as? Int ?? 0
            let authSummary = KimiWebUsageBridge.javascriptAuthSummary(from: object)
            KimiWebUsageBridge.debugLog("active WebView request failed HTTP \(status), \(authSummary), body=\(text.prefix(220))")
            throw KimiWebUsageBridge.BridgeError.requestFailed("Kimi Web fetch HTTP \(status): \(text.prefix(160))")
        }

        KimiWebUsageBridge.debugLog("active WebView usage fetch succeeded, bytes=\(text.utf8.count)")

        guard let responseData = text.data(using: .utf8) else {
            throw KimiWebUsageBridge.BridgeError.invalidResponse
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
                    continuation.resume(throwing: KimiWebUsageBridge.BridgeError.invalidResponse)
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
            KimiWebUsageBridge.debugLog("active WebView browserState=\(raw)")
        }

        let cookieSummary = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let summary = cookies
                    .filter { cookie in
                        let domain = cookie.domain.lowercased()
                        return domain.contains("kimi") || domain.contains("moonshot")
                    }
                    .map { "\($0.name)@\($0.domain)" }
                    .sorted()
                    .joined(separator: ",")
                continuation.resume(returning: summary)
            }
        }
        KimiWebUsageBridge.debugLog("active WebView httpCookieStore=\(cookieSummary)")
    }

    private func extractStorageCredential(completion: @escaping (KimiWebSessionCredential?) -> Void) {
        let script = """
        (() => {
          const copyStorage = (storage) => {
            const result = {};
            for (let i = 0; i < storage.length; i++) {
              const key = storage.key(i);
              result[key] = storage.getItem(key);
            }
            return result;
          };
          return JSON.stringify({
            href: location.href,
            localStorage: copyStorage(localStorage),
            sessionStorage: copyStorage(sessionStorage)
          });
        })();
        """

        webView.evaluateJavaScript(script) { value, _ in
            guard let json = value as? String else {
                KimiWebUsageBridge.debugLog("extractStorageCredential no json")
                completion(nil)
                return
            }
            KimiWebUsageBridge.debugLog("extractStorageCredential storage keys snapshot length=\(json.count)")
            completion(Self.sessionCredential(from: json))
        }
    }

    private func extractCookieCredential(completion: @escaping (String?) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let kimiCookies = cookies
                .filter { cookie in
                    let domain = cookie.domain.lowercased()
                    return domain.contains("kimi") || domain.contains("moonshot")
                }

            guard !kimiCookies.isEmpty else {
                KimiWebUsageBridge.debugLog("extractCookieCredential found no kimi cookies")
                completion(nil)
                return
            }

            let summary = kimiCookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ",")
            KimiWebUsageBridge.debugLog("extractCookieCredential cookies=\(summary)")

            let cookieHeader = kimiCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            completion(cookieHeader)
        }
    }

    private static func sessionCredential(from json: String) -> KimiWebSessionCredential? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let tokenInfo = findVolcanoTokenInfo(in: object)
        let credential = KimiWebSessionCredential(
            accessToken: findAccessToken(in: object, keyPath: []),
            cookieHeader: nil,
            trafficID: tokenInfo?["userId"] as? String,
            deviceID: tokenInfo?["webId"] as? String,
            sessionID: tokenInfo?["ssid"] as? String,
            planName: PlanNameExtractor().find(in: object)
        )
        return credential.isEmpty
            && (credential.trafficID ?? "").isEmpty
            && (credential.deviceID ?? "").isEmpty
            && (credential.sessionID ?? "").isEmpty ? nil : credential
    }

    private static func findVolcanoTokenInfo(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "volcano-token-info",
                   let string = child as? String,
                   let parsed = parseEmbeddedJSON(string) as? [String: Any] {
                    return parsed
                }

                if let found = findVolcanoTokenInfo(in: child) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let found = findVolcanoTokenInfo(in: child) {
                    return found
                }
            }
        }

        return nil
    }

    private static func findAccessToken(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return findAccessToken(in: object, keyPath: [])
    }

    private static func findAccessToken(in value: Any, keyPath: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if let token = findAccessToken(in: child, keyPath: keyPath + [key]) {
                    return token
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let token = findAccessToken(in: child, keyPath: keyPath) {
                    return token
                }
            }
        }

        guard let string = value as? String else {
            return nil
        }

        if let parsed = parseEmbeddedJSON(string),
           let token = findAccessToken(in: parsed, keyPath: keyPath) {
            return token
        }

        let joinedKey = keyPath.joined(separator: "_").lowercased()
        let looksLikeAccessTokenKey = joinedKey.contains("access") && joinedKey.contains("token")
        let looksLikeBearer = string.lowercased().hasPrefix("bearer ")
        let looksLikeJWT = string.range(
            of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#,
            options: .regularExpression
        ) != nil

        if string.count > 20,
           !joinedKey.contains("refresh"),
           looksLikeAccessTokenKey || looksLikeBearer || looksLikeJWT {
            return string.replacingOccurrences(of: "Bearer ", with: "")
        }

        return nil
    }

    private static func parseEmbeddedJSON(_ string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
