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
    private let settingsController: SettingsWindowController
    private let pinnedItemController: PinnedStatusItemController
    private let panelController: MenuBarPanelController

    init() {
        // 两个控制器都要伴随 AppState 的整个生命周期。它们是 AppKit 对象、自己管状态项，
        // 不挂在任何 SwiftUI 视图上 —— 挂在视图的 onAppear 上会让状态项直到面板被打开过才出现。
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        let settings = SettingsWindowController(appState: state)
        settingsController = settings
        let pinned = PinnedStatusItemController(appState: state, settings: settings)
        pinnedItemController = pinned
        let panel = MenuBarPanelController(appState: state, settings: settings)
        panelController = panel

        // App.init 在 NSApplicationMain 完成之前就跑；控制器自己会等 didFinishLaunching，
        // 这里只是把启动推迟到当前 runloop 之后。
        DispatchQueue.main.async {
            pinned.start()
            panel.start()
        }
    }

    var body: some Scene {
        // 设置窗口由 `SettingsWindowController` 自己拿 `NSWindow` 托管（见那个类的注释：
        // SwiftUI 的 `showSettingsWindow:` 在 macOS 26 上已经不响了）。这里的 `Settings`
        // scene 只有两个用处：满足 App 必须有 scene 的要求，以及万一有哪条系统路径还能
        // 开它时内容与自管窗口一致。⌘, 由下面的命令组接管，走的是同一个控制器。
        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    settingsController.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
