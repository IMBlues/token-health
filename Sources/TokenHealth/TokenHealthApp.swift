import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyApplicationIcon()
        // 亮/暗版是两张图，跟着系统外观换。
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.applyApplicationIcon()
        }
    }

    private func applyApplicationIcon() {
        if let icon = AppIcon.applicationImage(for: NSApp.effectiveAppearance) {
            NSApp.applicationIconImage = icon
        }
    }
}

struct TokenHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    private let pinnedItemController: PinnedStatusItemController
    private let panelController: MenuBarPanelController

    init() {
        // 两个控制器都要伴随 AppState 的整个生命周期。它们是 AppKit 对象、自己管状态项，
        // 不挂在任何 SwiftUI 视图上 —— 挂在视图的 onAppear 上会让状态项直到面板被打开过才出现。
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        let pinned = PinnedStatusItemController(appState: state)
        pinnedItemController = pinned
        let panel = MenuBarPanelController(appState: state)
        panelController = panel

        // App.init 在 NSApplicationMain 完成之前就跑；控制器自己会等 didFinishLaunching，
        // 这里只是把启动推迟到当前 runloop 之后。
        DispatchQueue.main.async {
            pinned.start()
            panel.start()
        }
    }

    var body: some Scene {
        // 主面板是 AppKit 的 NSStatusItem + NSPopover（见 MenuBarPanelController），不是
        // MenuBarExtra：后者在 .accessory 的 app 里收不到外部点击，面板点别处不会关。
        // 这里就只剩设置窗口一个 scene。
        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 460)
        }
    }
}
