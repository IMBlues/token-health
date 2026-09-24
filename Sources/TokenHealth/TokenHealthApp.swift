import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokenHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    private let pinnedItemController: PinnedStatusItemController

    init() {
        // 控制器要伴随 AppState 的整个生命周期，而 MenuBarExtra 的内容视图是懒加载的，
        // 挂在视图的 onAppear 上会让钉住项直到菜单被打开过才出现。
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        let controller = PinnedStatusItemController(appState: state)
        pinnedItemController = controller

        // App.init 在 NSApplicationMain 完成之前就跑；控制器自己会等 didFinishLaunching，
        // 这里只是把启动推迟到当前 runloop 之后。
        DispatchQueue.main.async {
            controller.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView()
                .environmentObject(appState)
                .frame(width: 360)
        } label: {
            Image(systemName: "bolt.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 760, height: 500)
        }
    }
}
