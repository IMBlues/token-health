import AppKit
import Foundation
import WebKit

@MainActor
final class WebSessionController: NSObject, WKNavigationDelegate {
    static let loadTimeoutSeconds = 20

    let configID: UUID

    private let descriptor: any WebSessionDescriptor
    private let dataStore: WKWebsiteDataStore
    private var loginWindow: WebSessionLoginWindowController?
    private var headlessWebView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var completion: ((Result<String, Error>) -> Void)?

    init(configID: UUID, descriptor: any WebSessionDescriptor, dataStore: WKWebsiteDataStore) {
        self.configID = configID
        self.descriptor = descriptor
        self.dataStore = dataStore
        super.init()
    }

    // MARK: - Login

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion

        let controller = loginWindow ?? WebSessionLoginWindowController(
            descriptor: descriptor,
            dataStore: dataStore
        )
        controller.onImport = { [weak self] credential in
            self?.finish(.success(credential))
        }
        controller.onImportFailed = { [weak self] in
            let title = self?.descriptor.providerTitle ?? "Web"
            self?.finish(.failure(WebSessionError.invalidResponse(providerTitle: title)), keepWindowOpen: true)
        }
        controller.onCancel = { [weak self] in
            let title = self?.descriptor.providerTitle ?? "Web"
            self?.finish(.failure(WebSessionError.cancelled(providerTitle: title)))
        }
        loginWindow = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: Result<String, Error>, keepWindowOpen: Bool = false) {
        let completion = completion
        self.completion = nil
        completion?(result)

        guard !keepWindowOpen else {
            return
        }
        loginWindow?.window?.orderOut(nil)
    }

    // MARK: - Headless usage fetch

    func fetchUsage(context: WebSessionFetchContext) async throws -> Data {
        let webView = headlessWebView ?? makeHeadlessWebView()
        headlessWebView = webView

        try await ensureOriginLoaded(webView)

        let raw: String
        do {
            raw = try await evaluate(descriptor.usageFetchScript(context: context), in: webView)
        } catch {
            WebSessionLog.debugLog(
                "script failed: \(error.localizedDescription)",
                providerTitle: descriptor.providerTitle
            )
            throw WebSessionError.requestFailed(
                providerTitle: descriptor.providerTitle,
                message: error.localizedDescription
            )
        }

        guard let envelope = WebSessionScriptEnvelope.parse(raw) else {
            throw WebSessionError.invalidResponse(providerTitle: descriptor.providerTitle)
        }

        guard envelope.ok else {
            let authSummary = WebSessionLog.javascriptAuthSummary(
                from: WebSessionScriptEnvelope.object(from: raw) ?? [:]
            )
            WebSessionLog.debugLog(
                "web fetch failed HTTP \(envelope.status), \(authSummary), body=\(envelope.text.prefix(220))",
                providerTitle: descriptor.providerTitle
            )
            if descriptor.isAuthenticationFailure(scriptResultJSON: raw) {
                throw WebSessionError.sessionExpired(providerTitle: descriptor.providerTitle)
            }
            throw WebSessionError.requestFailed(
                providerTitle: descriptor.providerTitle,
                message: "\(descriptor.providerTitle) Web fetch HTTP \(envelope.status): \(envelope.text.prefix(160))"
            )
        }

        WebSessionLog.debugLog(
            "web fetch succeeded, bytes=\(raw.utf8.count)",
            providerTitle: descriptor.providerTitle
        )
        return try descriptor.usageData(fromScriptResult: raw)
    }

    // MARK: - Lifecycle

    func teardown() async {
        resumeLoad(throwing: WebSessionError.requestFailed(
            providerTitle: descriptor.providerTitle,
            message: "\(descriptor.providerTitle) session was removed"
        ))
        loginWindow?.window?.orderOut(nil)
        loginWindow = nil
        headlessWebView?.navigationDelegate = nil
        headlessWebView = nil
        completion = nil
    }

    private func makeHeadlessWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        return webView
    }

    private func ensureOriginLoaded(_ webView: WKWebView) async throws {
        guard webView.url?.host != descriptor.originHost else {
            return
        }

        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.loadTimeoutSeconds))
            guard !Task.isCancelled else {
                return
            }
            resumeLoad(throwing: WebSessionError.loadTimeout(
                providerTitle: descriptor.providerTitle,
                seconds: Self.loadTimeoutSeconds
            ))
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            WebSessionLog.debugLog(
                "headless load \(descriptor.loginURL.absoluteString)",
                providerTitle: descriptor.providerTitle
            )
            webView.load(URLRequest(url: descriptor.loginURL))
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
                    continuation.resume(throwing: WebSessionError.invalidResponse(providerTitle: self.descriptor.providerTitle))
                    return
                }
                continuation.resume(returning: string)
            }
        }
    }

    /// Guarantees the continuation is resumed only once: both the navigation callbacks and the
    /// timeout funnel through here.
    private func resumeLoad(throwing error: Error? = nil) {
        guard let continuation = loadContinuation else {
            return
        }
        loadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoad(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeLoad(throwing: error)
    }
}

@MainActor
private final class WebSessionLoginWindowController: NSWindowController, NSWindowDelegate {
    var onImport: ((String) -> Void)?
    var onImportFailed: (() -> Void)?
    var onCancel: (() -> Void)?

    private let descriptor: any WebSessionDescriptor
    private let dataStore: WKWebsiteDataStore
    private let webView: WKWebView
    private let importButton: NSButton
    private let statusLabel: NSTextField

    init(descriptor: any WebSessionDescriptor, dataStore: WKWebsiteDataStore) {
        self.descriptor = descriptor
        self.dataStore = dataStore

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore

        webView = WKWebView(frame: .zero, configuration: configuration)
        importButton = NSButton(title: "Import Session", target: nil, action: nil)
        statusLabel = NSTextField(labelWithString: descriptor.loginInstructions)

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
        window.title = "Login with \(descriptor.providerTitle)"
        window.contentView = container
        window.center()

        super.init(window: window)

        window.delegate = self
        importButton.target = self
        importButton.action = #selector(importSession)

        webView.load(URLRequest(url: descriptor.loginURL))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }

    @objc private func importSession() {
        statusLabel.stringValue = "Importing \(descriptor.providerTitle) session..."
        importButton.isEnabled = false

        webView.evaluateJavaScript(descriptor.extractionScript) { [weak self] value, _ in
            guard let self else {
                return
            }
            let extractionJSON = (value as? String) ?? ""

            self.dataStore.httpCookieStore.getAllCookies { cookies in
                let matching = cookies
                    .filter { self.descriptor.shouldIncludeCookie(domain: $0.domain.lowercased()) }
                    .map { "\($0.name)=\($0.value)" }
                let cookieHeader = matching.isEmpty ? nil : matching.joined(separator: "; ")

                self.importButton.isEnabled = true

                guard let credential = self.descriptor.encodeCredential(
                    extractionJSON: extractionJSON,
                    cookieHeader: cookieHeader,
                    pageTitle: self.webView.title
                ) else {
                    self.statusLabel.stringValue = self.descriptor.missingSessionMessage
                    self.onImportFailed?()
                    return
                }

                WebSessionLog.debugLog("session imported", providerTitle: self.descriptor.providerTitle)
                self.statusLabel.stringValue = "Session imported."
                self.onImport?(credential)
            }
        }
    }
}
