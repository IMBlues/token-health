import AppKit
import Foundation
import Testing
@testable import TokenHealth

/// 主菜单栏面板的编排逻辑。
///
/// `NSStatusItem` / `NSPopover` 的装配本身在无窗口进程里跑不起来，能测的是两件事：
/// 一次点击该开还是该关（纯函数），以及浮层的配置有没有做对 —— 失焦能关全靠它。
@MainActor
struct MenuBarPanelControllerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func aClickOnAnOpenPanelClosesIt() {
        #expect(MenuBarPanelController.action(isShown: true, lastCloseAt: nil, now: now) == .close)
    }

    @Test
    func aClickWithNoPanelOpenShowsIt() {
        #expect(MenuBarPanelController.action(isShown: false, lastCloseAt: nil, now: now) == .show)
    }

    /// `.transient` 的浮层在点状态项按钮时会**先**被系统关掉，按钮的 action 才轮到 ——
    /// 只看 `isShown` 会把「这次点击是想关」误判成「想开」，面板就再也关不掉了。
    @Test
    func aClickRightAfterTheSystemClosedThePanelIsIgnored() {
        let justClosed = now.addingTimeInterval(-0.05)

        #expect(MenuBarPanelController.action(isShown: false, lastCloseAt: justClosed, now: now) == .ignore)
    }

    @Test
    func aClickWellAfterThePanelClosedShowsItAgain() {
        let closedAWhileAgo = now.addingTimeInterval(-1)

        #expect(MenuBarPanelController.action(isShown: false, lastCloseAt: closedAWhileAgo, now: now) == .show)
    }

    /// 失焦关闭靠 `.transient`。`.accessory` 的 app 不会被系统自动激活，
    /// 这正是主面板要自己管浮层、而不是用 `MenuBarExtra(.window)` 的原因。
    @Test
    func thePanelPopoverIsTransient() {
        let popover = MenuBarPanelController.makePopover(content: NSViewController(), delegate: nil)

        #expect(popover.behavior == .transient)
    }
}
