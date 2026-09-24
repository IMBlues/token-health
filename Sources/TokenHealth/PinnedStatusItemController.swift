import AppKit
import Combine

/// 拥有那个钉住的菜单栏项：订阅 AppState，重算指标，重绘，弹菜单。
@MainActor
final class PinnedStatusItemController: NSObject {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var pendingRedraw: DispatchWorkItem?

    /// 状态项在 NSApplication 启动完成前创建会被系统丢掉，所以首次重绘挂在启动通知上。
    private var hasLaunched = false

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        NotificationCenter.default
            .publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.hasLaunched = true
                    self?.scheduleRedraw()
                }
            }
            .store(in: &cancellables)

        // 菜单栏外观变化时 logo 要跟着反色。AppKit 没有对应的通知，只能 KVO。
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.scheduleRedraw()
            }
        }

        // objectWillChange 在变更之前发出，所以只用来触发一次延后重绘。
        appState.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRedraw()
                }
            }
            .store(in: &cancellables)

        hasLaunched = NSRunningApplication.current.isFinishedLaunching
        redraw()
    }

    func stop() {
        cancellables.removeAll()
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        removeStatusItem()
    }

    // MARK: - 重绘

    /// 一次刷新会连着改好几个 @Published，去抖一下只画最后一帧。
    private func scheduleRedraw() {
        pendingRedraw?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.redraw()
            }
        }
        pendingRedraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func redraw() {
        guard hasLaunched, let config = appState.pinnedConfig, config.isEnabled else {
            removeStatusItem()
            return
        }

        let metrics = MenuBarMetrics.metrics(
            for: appState.pinnedSnapshot,
            kind: config.providerKind,
            displayCurrency: config.displayCurrency,
            rateTable: appState.exchangeRate
        )
        let displayMetrics = metrics.isEmpty ? [MenuBarMetrics.placeholder] : metrics
        let iconColor = Self.iconColor(for: NSApp.effectiveAppearance)
        let layout = MenuBarItemLayout.make(
            metrics: displayMetrics,
            hasIcon: true,
            amountWidth: MenuBarItemRenderer.amountWidth(for: displayMetrics)
        )

        let item = ensureStatusItem()
        let image = MenuBarItemRenderer.image(
            layout: layout,
            kind: config.providerKind,
            metrics: displayMetrics,
            iconColor: iconColor,
            scale: item.button?.window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
        )

        item.length = image.size.width + MenuBarItemLayout.statusItemPadding
        item.button?.image = image
        item.button?.toolTip = MenuBarMetrics.tooltipText(
            serviceName: config.displayName,
            metrics: metrics,
            statusMessage: appState.pinnedSnapshot?.statusMessage
        )
        item.menu = makeMenu(displayName: config.displayName)
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        created.autosaveName = "TokenHealthPinned"
        statusItem = created
        return created
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    /// 菜单栏外观决定 logo 画成白还是黑 —— 这正是「单色模板」想要的效果，
    /// 但整张图必须保留竖条的颜色，所以只能自己解析。
    private static func iconColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    // MARK: - 菜单

    private func makeMenu(displayName: String) -> NSMenu {
        let menu = NSMenu()

        let unpin = NSMenuItem(title: "Unpin \(displayName)", action: #selector(unpin), keyEquivalent: "")
        unpin.target = self
        menu.addItem(unpin)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Token Health", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func unpin() {
        appState.setPinnedConfigID(nil)
    }

    @objc private func openSettings() {
        // SwiftUI 的 openSettings 环境值只在 View 里可用，这里走同一套 responder action。
        // 两个选择器按系统版本依次尝试，都不认就只是没反应，不影响其余菜单项。
        for selector in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector(selector), to: nil, from: nil) {
                break
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
