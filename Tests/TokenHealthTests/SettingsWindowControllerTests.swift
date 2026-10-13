import AppKit
import Foundation
import Testing
@testable import TokenHealth

/// 设置窗口的装配。
///
/// 这里要钉住的是「开设置窗口」这件事本身还成立：以前它靠
/// `NSApp.sendAction("showSettingsWindow:")` 打给 responder chain，macOS 26 上那条路
/// 已经没人接了，`sendAction` 静默返回 false，窗口根本不出现。改成自己管 `NSWindow`
/// 之后，「点了设置有没有窗口」就变成一个能直接断言的事实。
@MainActor
struct SettingsWindowControllerTests {
    @Test
    func theWindowCarriesTheExpectedTitleAndChrome() {
        let controller = SettingsWindowController(appState: AppState())
        let window = controller.makeWindow()

        #expect(window.title == "Token Health Settings")
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
    }

    /// 窗口尺寸不能小于内容的下限，否则侧边栏会被切掉。
    @Test
    func theWindowIsAtLeastTheSizeTheContentViewNeeds() {
        let controller = SettingsWindowController(appState: AppState())
        let window = controller.makeWindow()

        #expect(window.contentMinSize.width >= SettingsWindowController.minimumSize.width)
        #expect(window.contentMinSize.height >= SettingsWindowController.minimumSize.height)
    }

    /// 关掉再开要复用同一个窗口：`isReleasedWhenClosed` 一旦是默认的 true，
    /// 窗口在关闭那刻就被释放，控制器手里就是一条悬垂引用。
    @Test
    func closingDoesNotReleaseTheWindow() {
        let controller = SettingsWindowController(appState: AppState())
        let window = controller.makeWindow()

        #expect(window.isReleasedWhenClosed == false)
    }

    /// 连开两次只有一个窗口，且第二次是把它重新置前，不是再造一个。
    @Test
    func showingTwiceReusesOneWindow() {
        let controller = SettingsWindowController(appState: AppState())

        controller.show()
        let first = try? #require(controller.settingsWindow)
        controller.show()

        #expect(first != nil)
        #expect(controller.settingsWindow === first)
        #expect(controller.settingsWindow?.isVisible == true)
    }
}
