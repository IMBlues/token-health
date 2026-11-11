import AppKit
import Combine
import SwiftUI

/// 主菜单栏项；与钉住的账号共用浮层的开关和失焦关闭逻辑。
@MainActor
final class MenuBarPanelController: NSObject {
    /// 面板宽度。与它当 `MenuBarExtra` 内容时用的值一致。
    static let panelWidth: CGFloat = 360

    private let appState: AppState
    private let settings: SettingsWindowController
    private let popoverController: StatusItemPopoverController
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    init(
        appState: AppState,
        settings: SettingsWindowController,
        popoverController: StatusItemPopoverController = StatusItemPopoverController()
    ) {
        self.appState = appState
        self.settings = settings
        self.popoverController = popoverController
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
        if let button = statusItem?.button {
            popoverController.close(ifAnchoredTo: button)
        }
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
        // 不给 autosaveName：带着它建出来的项会被系统摆到屏幕外（Accessibility 报出来的 x 是 -4150），
        // 用户既看不到也拖不回来。让它走默认位置，用户再自己 ⌘ 拖。
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
        popoverController.toggle(relativeTo: sender) {
            NSHostingController(
                rootView: StatusMenuView(openSettings: { [settings] in settings.show() })
                    .environmentObject(appState)
                    .frame(width: Self.panelWidth)
            )
        }
    }
}
