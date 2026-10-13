import AppKit
import SwiftUI

/// 设置窗口。
///
/// 这个窗口原本是 SwiftUI 的 `Settings` scene，靠 `NSApp.sendAction("showSettingsWindow:")`
/// 打开。那条路要 SwiftUI 把 responder action 挂在 responder chain 上才响；到 macOS 26
/// 上两个 selector 都没人接了，`sendAction` 返回 false —— 不报错、不弹窗，表现就是
/// 「点了齿轮没反应」（2026-10-13 在 macOS 26.5.2 上复现并确认）。
///
/// 所以改成自己拿 `NSWindow` 托管 `SettingsView`：窗口建不建、什么时候开、有没有提到
/// 最前，全由这里说了算，不再依赖 SwiftUI 的私有接线。
@MainActor
final class SettingsWindowController {
    /// 窗口尺寸下限，与原来 `Settings` scene 上的 `.frame(minWidth:minHeight:)` 一致。
    static let minimumSize = NSSize(width: 720, height: 460)
    /// 首次打开时的窗口尺寸。
    static let defaultSize = NSSize(width: 900, height: 560)
    /// 位置记忆的键。用户把窗口拖到哪，下次就还开在哪。
    static let frameAutosaveName = "TokenHealthSettingsWindow"

    private let appState: AppState
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    /// 已经建出来的设置窗口；从没开过就是 nil。
    var settingsWindow: NSWindow? { window }

    /// 打开（或再次置前）设置窗口。
    func show() {
        let window = window ?? makeWindow()
        self.window = window

        // `.accessory` 的 app 没有 Dock 图标，系统不会把它自动提到最前：不显式激活的话，
        // 窗口会开在当前 app 后面，用户那边看起来仍然是「没打开」。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 造窗口。只造不管开 —— 开窗口的顺序在 `show()` 里。
    func makeWindow() -> NSWindow {
        let host = NSHostingController(
            rootView: SettingsView()
                .environmentObject(appState)
                .frame(
                    minWidth: Self.minimumSize.width,
                    minHeight: Self.minimumSize.height
                )
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Token Health Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 窗口的下限要自己设：以前这是 SwiftUI 的 `Settings` scene，它会替我们把内容上的
        // `.frame(minWidth:minHeight:)` 抬成窗口约束；自己管窗口就得自己抬，否则用户能把
        // 窗口缩到侧边栏挤成一团。
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.defaultSize)
        // 关掉不能把窗口释放掉：控制器还要留着它，下次点设置原地重开。
        window.isReleasedWhenClosed = false
        // 有存过的位置就照用，没有才居中 —— 反过来会把用户摆好的位置又拽回屏幕中间。
        if !window.setFrameAutosaveName(Self.frameAutosaveName) {
            window.center()
        }
        return window
    }
}
