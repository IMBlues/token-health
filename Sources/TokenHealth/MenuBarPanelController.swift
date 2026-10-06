import AppKit
import Combine
import SwiftUI

/// 主菜单栏项：点葫芦图标弹出账号面板。
///
/// 不用 SwiftUI 的 `MenuBarExtra` + `.menuBarExtraStyle(.window)`：那种面板要靠 app 处于活跃
/// 状态才收得到全局鼠标事件，而本 app 是 `.accessory`（无 Dock 图标，见 `TokenHealthApp`），
/// 系统不会把它自动提升为 active —— 于是点面板外面它不关，只能再点一次图标。`.window` 风格
/// 至今也没有公开的关闭接口，补不了这一刀。
///
/// 自己管 `NSStatusItem` + `NSPopover` 就能像 `PinnedStatusItemController` 那样，在弹出前显式
/// `NSApp.activate` 把这条补齐。两个控制器是同一套写法，行为也就一致了。
@MainActor
final class MenuBarPanelController: NSObject, NSPopoverDelegate {
    /// 面板宽度。与它当 `MenuBarExtra` 内容时用的值一致。
    static let panelWidth: CGFloat = 360

    /// 关闭之后多久内的再次点击算「同一轮点击」，不重开。
    ///
    /// `.transient` 的浮层在点状态项按钮时会**先**被系统关掉，按钮的 action 才轮到 ——
    /// 没有这个窗口，那次点击会被读成「想开」，面板就再也关不掉了。
    static let reopenGrace: TimeInterval = 0.25

    enum PanelAction: Equatable {
        case show
        case close
        /// 这次点击已经被系统当成「关闭」消化掉了，不该再开一次。
        case ignore
    }

    /// 一次点击该做什么。
    ///
    /// 抽成纯函数是为了能直接断言：这条判断错了的表现是「面板关不掉」，
    /// 而那是没法在无窗口测试里点出来的。
    static func action(isShown: Bool, lastCloseAt: Date?, now: Date) -> PanelAction {
        if isShown {
            return .close
        }
        if let lastCloseAt, now.timeIntervalSince(lastCloseAt) < reopenGrace {
            return .ignore
        }
        return .show
    }

    /// 浮层的配置。抽出来是为了能在测试里断言 `behavior` —— 失焦关闭全靠它。
    static func makePopover(content: NSViewController, delegate: NSPopoverDelegate?) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = delegate
        popover.contentViewController = content
        return popover
    }

    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// 上一次浮层关闭的时刻，用来识别「这次点击其实是刚才那一下的关闭」。
    private var lastCloseAt: Date?
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        if NSRunningApplication.current.isFinishedLaunching {
            installStatusItem()
            return
        }
        // 状态项在 NSApplication 启动完成前创建会被系统丢掉。
        NotificationCenter.default
            .publisher(for: NSApplication.didFinishLaunchingNotification)
            .first()
            .sink { [weak self] _ in
                Task { @MainActor in self?.installStatusItem() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        popover?.close()
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        cancellables.removeAll()
    }

    private func installStatusItem() {
        guard statusItem == nil else {
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 位置由系统记住，用户也可以 ⌘ 拖拽调整。
        item.autosaveName = "TokenHealthMain"
        // 图标是模板图，系统按菜单栏外观着色，换壁纸/深浅色都不用重画。
        let icon = AppIcon.menuBarImage()
            ?? NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Token Health")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        statusItem = item
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        switch Self.action(isShown: popover?.isShown == true, lastCloseAt: lastCloseAt, now: Date()) {
        case .close:
            popover?.performClose(nil)
        case .ignore:
            break
        case .show:
            showPanel(anchor: sender)
        }
    }

    private func showPanel(anchor: NSStatusBarButton) {
        let content = NSHostingController(
            rootView: StatusMenuView()
                .environmentObject(appState)
                .frame(width: Self.panelWidth)
        )
        let popover = Self.makePopover(content: content, delegate: self)
        self.popover = popover

        // `.transient` 要能响应外部点击关闭，得先让 App 拿到焦点。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// 用户点别处或按 Esc 关掉浮层时走这里 —— 不接这一下，`lastCloseAt` 就永远是 nil，
    /// 「刚被关掉的那次点击」会被读成「想开」。
    func popoverDidClose(_ notification: Notification) {
        lastCloseAt = Date()
        popover = nil
    }
}
