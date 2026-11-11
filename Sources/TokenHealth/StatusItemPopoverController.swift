import AppKit
import Combine

/// AppKit's transient dismissal can precede the button action and reopen a closing popover.
/// One shared owner handles toggling and dismissal for both the main item and pinned accounts.
@MainActor
final class StatusItemPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var anchor: NSView?
    private var onClose: (() -> Void)?
    private var dismissalObservers = Set<AnyCancellable>()

    var isShown: Bool { popover?.isShown == true }

    static func makePopover(content: NSViewController, delegate: NSPopoverDelegate?) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = content
        popover.delegate = delegate
        return popover
    }

    @discardableResult
    func toggle(
        relativeTo anchor: NSView,
        content: () -> NSViewController,
        onClose: @escaping () -> Void = {}
    ) -> Bool {
        if self.anchor === anchor, popover != nil {
            close()
            return false
        }
        close()
        guard anchor.window != nil else { return false }

        let popover = Self.makePopover(content: content(), delegate: self)
        self.popover = popover
        self.anchor = anchor
        self.onClose = onClose
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        guard popover.isShown else {
            close()
            return false
        }
        popover.contentViewController?.view.window?.makeKey()
        observeDismissal(for: popover)
        return true
    }

    func close(ifAnchoredTo anchor: NSView) {
        if self.anchor === anchor { close() }
    }

    func close() {
        let popover = self.popover
        let onClose = self.onClose
        self.popover = nil
        self.anchor = nil
        self.onClose = nil
        dismissalObservers.removeAll()
        // Clear ownership first: an old close callback must never clear a newer session.
        popover?.delegate = nil
        popover?.close()
        onClose?()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        close()
    }

    private func observeDismissal(for popover: NSPopover) {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [mouseEvents, .keyDown], handler: { [weak self, weak popover] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let popover, self.popover === popover else { return false }
                return self.handleLocalEvent(event) == nil
            }
            return consumed ? nil : event
        }) {
            AnyCancellable { NSEvent.removeMonitor(monitor) }.store(in: &dismissalObservers)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self, weak popover] event in
            MainActor.assumeIsolated {
                guard let self, let popover, self.popover === popover else { return }
                self.handleGlobalEvent(event)
            }
        }) {
            AnyCancellable { NSEvent.removeMonitor(monitor) }.store(in: &dismissalObservers)
        }
        observe(NSApplication.didResignActiveNotification, center: .default, for: popover)
        observe(NSWindow.didBecomeKeyNotification, center: .default, for: popover)
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: NSWorkspace.shared.notificationCenter, for: popover)
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, for popover: NSPopover) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak popover] notification in
            let focusedWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let popover, self.popover === popover else { return }
                if name == NSWindow.didBecomeKeyNotification,
                   let window = focusedWindow,
                   window === self.anchor?.window || self.contains(window, in: popover) {
                    return
                }
                self.close()
            }
        }
        AnyCancellable { center.removeObserver(observer) }.store(in: &dismissalObservers)
    }

    func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard let popover else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                close()
                return nil
            }
            return event
        }

        let location = Self.screenLocation(of: event)
        // Leave anchor clicks for the button action, regardless of how long the click is held.
        if anchorContains(location) { return event }

        if let window = event.window, contains(window, in: popover) { return event }
        close()
        return event
    }

    func handleGlobalEvent(_ event: NSEvent) {
        if !anchorContains(Self.screenLocation(of: event)) { close() }
    }

    private static func screenLocation(of event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func contains(_ eventWindow: NSWindow, in popover: NSPopover) -> Bool {
        var window: NSWindow? = eventWindow
        while let candidate = window {
            if candidate === popover.contentViewController?.view.window { return true }
            window = candidate.parent
        }
        return false
    }

    private func anchorContains(_ screenPoint: NSPoint) -> Bool {
        guard let anchor, let window = anchor.window else { return false }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(screenPoint)
    }
}
