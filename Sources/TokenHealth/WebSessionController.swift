import AppKit
import Foundation
import WebKit

@MainActor
final class WebSessionController: NSObject, WKNavigationDelegate {
    static let loadTimeoutSeconds = 20

    let configID: UUID

    /// Set on the first `teardown()`; afterwards both entry points refuse to run, so a torn-down
    /// kernel can never touch its store again.
    private(set) var isTornDown = false

    private let descriptor: any WebSessionDescriptor
    private let dataStore: WKWebsiteDataStore
    private var loginWindow: WebSessionLoginWindowController?
    private var headlessWebView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var evaluationContinuation: CheckedContinuation<String, Error>?
    private var isFetching = false
    private var completion: ((Result<String, Error>) -> Void)?

    init(configID: UUID, descriptor: any WebSessionDescriptor, dataStore: WKWebsiteDataStore) {
        self.configID = configID
        self.descriptor = descriptor
        self.dataStore = dataStore
        super.init()
    }

    // MARK: - Login

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        guard !isTornDown else {
            completion(.failure(WebSessionError.requestFailed(
                providerTitle: descriptor.providerTitle,
                message: "\(descriptor.providerTitle) session was removed"
            )))
            return
        }
        if let pending = self.completion {
            self.completion = nil
            pending(.failure(WebSessionError.cancelled(providerTitle: descriptor.providerTitle)))
        }
        self.completion = completion

        let controller = loginWindow ?? WebSessionLoginWindowController(
            descriptor: descriptor,
            dataStore: dataStore
        )
        controller.onImport = { [weak self] credential in
            self?.finish(.success(credential))
        }
        controller.onImportFailed = { [weak self] in
            guard let self else {
                return
            }
            self.finish(
                .failure(WebSessionError.requestFailed(
                    providerTitle: self.descriptor.providerTitle,
                    message: self.descriptor.missingSessionMessage
                )),
                keepWindowOpen: true
            )
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

        if !keepWindowOpen {
            loginWindow?.window?.orderOut(nil)
        }
        completion?(result)
    }

    // MARK: - Headless usage fetch

    func fetchUsage(context: WebSessionFetchContext) async throws -> Data {
        guard !isTornDown, !isFetching, loadContinuation == nil, evaluationContinuation == nil else {
            throw WebSessionError.requestFailed(
                providerTitle: descriptor.providerTitle,
                message: "\(descriptor.providerTitle) session is already fetching usage"
            )
        }
        isFetching = true
        defer { isFetching = false }

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
            if let sessionError = error as? WebSessionError {
                throw sessionError
            }
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

    /// Drops the kernel's references so the registry can remove this config's data store.
    /// Unblocks any in-flight load or script evaluation first, then yields once to give those tasks
    /// a chance to unwind and release their WebView. Not a hard drain barrier: the caller must not
    /// treat this as meaning the store is already released.
    func teardown() async {
        isTornDown = true

        let removed = WebSessionError.requestFailed(
            providerTitle: descriptor.providerTitle,
            message: "\(descriptor.providerTitle) session was removed"
        )
        resumeLoad(throwing: removed)
        resumeEvaluation(with: .failure(removed))

        // close(), not orderOut(): closing fires windowWillClose, which delivers a cancellation to a
        // pending login completion, and releases the window (and with it the login WebView) instead
        // of leaving it alive on the store we are about to remove.
        loginWindow?.close()
        loginWindow = nil
        headlessWebView?.navigationDelegate = nil
        headlessWebView = nil
        completion = nil

        await Task.yield()
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
            evaluationContinuation = continuation
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    self.resumeEvaluation(with: .failure(error))
                } else if let string = value as? String {
                    self.resumeEvaluation(with: .success(string))
                } else {
                    self.resumeEvaluation(with: .failure(
                        WebSessionError.invalidResponse(providerTitle: self.descriptor.providerTitle)
                    ))
                }
            }
        }
    }

    /// Single-resume slot for the script evaluation, mirroring `resumeLoad`.
    private func resumeEvaluation(with result: Result<String, Error>) {
        guard let continuation = evaluationContinuation else {
            return
        }
        evaluationContinuation = nil
        continuation.resume(with: result)
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
        guard webView === headlessWebView else {
            return
        }
        resumeLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === headlessWebView else {
            return
        }
        resumeLoad(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === headlessWebView else {
            return
        }
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
