import AppKit
import Foundation
import Testing
@testable import TokenHealth

@MainActor
struct MenuBarPanelControllerTests {
    @Test
    func thePanelDoesNotRaceAppKitForOutsideClickDismissal() {
        let popover = StatusItemPopoverController.makePopover(content: NSViewController(), delegate: nil)

        #expect(popover.behavior == .applicationDefined)
    }
}
