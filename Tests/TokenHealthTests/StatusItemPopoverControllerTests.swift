import AppKit
import Foundation
import Testing
@testable import TokenHealth

@MainActor
struct StatusItemPopoverControllerTests {
    private func makeWindow() -> (NSWindow, NSButton, NSButton) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let first = NSButton(frame: NSRect(x: 20, y: 30, width: 80, height: 24))
        let second = NSButton(frame: NSRect(x: 120, y: 30, width: 80, height: 24))
        window.contentView!.addSubview(first)
        window.contentView!.addSubview(second)
        window.orderFront(nil)
        return (window, first, second)
    }

    private func makeContent() -> NSViewController {
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        return content
    }

    private func mouseDown(in window: NSWindow, at location: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!
    }

    @Test
    func aSecondClickClosesAndAThirdClickImmediatelyReopens() {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        var built = 0
        let content = { built += 1; return makeContent() }

        #expect(controller.toggle(relativeTo: anchor, content: content))
        #expect(controller.isShown)
        #expect(!controller.toggle(relativeTo: anchor, content: content))
        #expect(!controller.isShown)
        #expect(built == 1, "closing must not rebuild a new popover")
        #expect(controller.toggle(relativeTo: anchor, content: content))
        #expect(controller.isShown)
        #expect(built == 2, "there must be no timed suppression after a real close")
    }

    @Test
    func switchingAnchorsClosesOnlyThePreviousContent() {
        let (window, first, second) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        var firstClosed = 0
        var secondClosed = 0
        controller.toggle(relativeTo: first, content: makeContent, onClose: { firstClosed += 1 })

        controller.toggle(relativeTo: second, content: makeContent, onClose: { secondClosed += 1 })

        #expect(controller.isShown)
        #expect(firstClosed == 1)
        #expect(secondClosed == 0)
        controller.close(ifAnchoredTo: first)
        #expect(controller.isShown, "removing an unrelated status item must not close the current one")
        controller.close(ifAnchoredTo: second)
        #expect(!controller.isShown)
        #expect(secondClosed == 1)
        controller.close()
        #expect(secondClosed == 1)
    }

    @Test
    func theAnchorMouseDownIsLeftForTheButtonToToggle() {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        controller.toggle(relativeTo: anchor, content: makeContent)

        let event = mouseDown(in: window, at: NSPoint(x: 50, y: 40))
        #expect(controller.handleLocalEvent(event) === event)
        #expect(controller.isShown)
        #expect(!controller.toggle(relativeTo: anchor, content: makeContent))
        #expect(!controller.isShown)
    }

    @Test
    func clickingInsideKeepsContentOpenButClickingAnotherWindowClosesIt() throws {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        let content = makeContent()
        controller.toggle(relativeTo: anchor, content: { content })
        let contentWindow = try #require(content.view.window)
        let inside = mouseDown(in: contentWindow, at: NSPoint(x: 30, y: 30))

        #expect(controller.handleLocalEvent(inside) === inside)
        #expect(controller.isShown)

        let outside = mouseDown(in: window, at: NSPoint(x: 400, y: 50))
        #expect(controller.handleLocalEvent(outside) === outside, "the outside click must still reach its target")
        #expect(!controller.isShown)
    }

    @Test
    func escapeClosesAndIsConsumedOnlyWhileAPopoverIsOpen() {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        controller.toggle(relativeTo: anchor, content: makeContent)
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        )!

        #expect(controller.handleLocalEvent(escape) == nil)
        #expect(!controller.isShown)
        #expect(controller.handleLocalEvent(escape) === escape)
    }

    @Test
    func losingApplicationFocusClosesAndDoesNotRetainAnOldCloseCallback() {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        var closed = 0
        controller.toggle(relativeTo: anchor, content: makeContent, onClose: { closed += 1 })

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(!controller.isShown)
        #expect(closed == 1)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(closed == 1)
    }

    @Test
    func changingSpacesClosesThePopover() {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        controller.toggle(relativeTo: anchor, content: makeContent)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        #expect(!controller.isShown)
    }

    @Test
    func anotherWindowTakingFocusClosesButAPopoverChildDoesNot() throws {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer {
            controller.close()
            child.close()
            other.close()
            window.close()
        }
        let content = makeContent()
        controller.toggle(relativeTo: anchor, content: { content })
        let contentWindow = try #require(content.view.window)
        contentWindow.addChildWindow(child, ordered: .above)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: child)
        #expect(controller.isShown)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(!controller.isShown, "keyboard focus can move to Settings without deactivating the app")
    }

    @Test
    func globalClicksUseTheEventPositionInsteadOfTheCurrentPointer() {
        let (window, anchor, _) = makeWindow()
        let controller = StatusItemPopoverController()
        defer { controller.close(); window.close() }
        controller.toggle(relativeTo: anchor, content: makeContent)
        let anchorPoint = window.convertPoint(toScreen: NSPoint(x: 50, y: 40))
        let anchorEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: anchorPoint, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!

        controller.handleGlobalEvent(anchorEvent)
        #expect(controller.isShown, "the triggering anchor click belongs to the button's toggle")

        let outsideEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: -1000, y: -1000), modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        )!
        controller.handleGlobalEvent(outsideEvent)
        #expect(!controller.isShown)
    }
}
