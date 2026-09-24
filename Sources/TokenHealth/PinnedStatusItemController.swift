import AppKit
import Combine
import SwiftUI

/// 拥有那些钉住的菜单栏项：订阅 AppState，为每个被钉住的账号维护一个状态项，
/// 重算指标、重绘、并在点击时弹出该账号的内容。
///
/// 支持详情的 Provider 点下去弹浮层（余额、按天趋势、按模型拆分…），
/// 不支持的就是原来的 Unpin / Settings / Quit 小菜单。
@MainActor
final class PinnedStatusItemController: NSObject {
    /// 详情超过这个岁数就在打开时顺手拉一次。
    static let detailStaleness: TimeInterval = 5 * 60

    private let appState: AppState
    private var statusItems: [UUID: NSStatusItem] = [:]
    private var popovers: [UUID: NSPopover] = [:]
    private var detailHosts: [UUID: NSHostingController<DetailPopoverView>] = [:]
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
        // 排队中的重绘会把刚移除的状态项又建回来。
        pendingRedraw?.cancel()
        pendingRedraw = nil
        removeAllStatusItems()
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

    /// 把状态项的集合对账成「启用中的、被钉住的账号」，顺序按账号列表。
    /// 只增删差集，已有项原地更新，免得每次重绘都把位置打乱。
    private func redraw() {
        guard hasLaunched else {
            removeAllStatusItems()
            return
        }

        let visible = appState.pinnedConfigs.filter(\.isEnabled)
        let visibleIDs = Set(visible.map(\.id))

        for id in statusItems.keys where !visibleIDs.contains(id) {
            removeStatusItem(for: id)
        }
        for config in visible {
            updateStatusItem(for: config)
        }
    }

    private func updateStatusItem(for config: ServiceConfig) {
        let snapshot = appState.snapshots[config.id]
        let metrics = MenuBarMetrics.metrics(
            for: snapshot,
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

        let item = statusItem(for: config.id)
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
            statusMessage: snapshot?.statusMessage
        )

        // 两个方向都必须**显式赋值**：menu 非空时按钮点击根本不会触发 action，
        // 只在需要时跳过赋值会留下过期的菜单（比如账号从登录模式改成了 API 模式）。
        if ProviderFactory.producesUsageDetail(for: config) {
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(showDetail(_:))
        } else {
            item.button?.target = nil
            item.button?.action = nil
            item.menu = makeMenu(for: config)
        }

        refreshOpenPopover(for: config)
    }

    private func statusItem(for id: UUID) -> NSStatusItem {
        if let existing = statusItems[id] {
            return existing
        }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 每个账号一个稳定的自动保存名：系统据此记住位置，用户也可以 ⌘ 拖拽调整。
        created.autosaveName = "TokenHealthPinned-\(id.uuidString)"
        // 按钮没有 representedObject，靠 identifier 认领它是哪个账号。设一次就够，重绘间不变。
        created.button?.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        statusItems[id] = created
        return created
    }

    private func removeStatusItem(for id: UUID) {
        closePopover(for: id)
        guard let item = statusItems.removeValue(forKey: id) else {
            return
        }
        NSStatusBar.system.removeStatusItem(item)
    }

    private func removeAllStatusItems() {
        for id in Array(statusItems.keys) {
            removeStatusItem(for: id)
        }
    }

    /// 菜单栏外观决定 logo 画成白还是黑 —— 这正是「单色模板」想要的效果，
    /// 但整张图必须保留竖条的颜色，所以只能自己解析。
    private static func iconColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    // MARK: - 详情浮层

    @objc private func showDetail(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = UUID(uuidString: raw),
              let config = appState.configs.first(where: { $0.id == id }) else {
            return
        }

        closePopover(for: id)

        let host = NSHostingController(rootView: makeDetailView(for: config))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host
        detailHosts[id] = host
        popovers[id] = popover

        // .transient 要能响应外部点击关闭，得先让 App 拿到焦点。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)

        if isStale(config) {
            Task { await appState.refresh(configID: id) }
        }
    }

    private func isStale(_ config: ServiceConfig) -> Bool {
        guard let updatedAt = appState.snapshots[config.id]?.updatedAt else {
            return true
        }
        return Date().timeIntervalSince(updatedAt) >= Self.detailStaleness
    }

    private func makeDetailView(for config: ServiceConfig) -> DetailPopoverView {
        let snapshot = appState.snapshots[config.id]
        return DetailPopoverView(
            serviceName: config.displayName,
            detail: snapshot?.detail,
            // ready 快照的 statusMessage 是「DeepSeek Platform」这类正常状态，不能当成错误显示。
            statusMessage: snapshot?.state == .ready ? nil : snapshot?.statusMessage,
            updatedAt: snapshot?.updatedAt,
            onRefresh: { [weak self] in
                Task { await self?.appState.refresh(configID: config.id) }
            },
            onUnpin: { [weak self] in
                self?.closePopover(for: config.id)
                self?.appState.setPinned(config.id, false)
            },
            onOpenSettings: { [weak self] in
                self?.closePopover(for: config.id)
                self?.openSettings()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
    }

    /// 浮层开着时数据刷新完成 → 重新赋 `rootView`，内容就地更新，浮层不关闭。
    private func refreshOpenPopover(for config: ServiceConfig) {
        guard ProviderFactory.producesUsageDetail(for: config),
              let host = detailHosts[config.id] else {
            return
        }
        host.rootView = makeDetailView(for: config)
    }

    private func closePopover(for id: UUID) {
        popovers.removeValue(forKey: id)?.close()
        detailHosts.removeValue(forKey: id)
    }

    // MARK: - 菜单

    private func makeMenu(for config: ServiceConfig) -> NSMenu {
        let menu = NSMenu()

        let unpin = NSMenuItem(
            title: "Unpin \(config.displayName)",
            action: #selector(unpin(_:)),
            keyEquivalent: ""
        )
        unpin.target = self
        // 一个控制器服务多个状态项，靠 representedObject 分辨是哪一个。
        unpin.representedObject = config.id.uuidString
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

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else {
            return
        }
        appState.setPinned(id, false)
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
