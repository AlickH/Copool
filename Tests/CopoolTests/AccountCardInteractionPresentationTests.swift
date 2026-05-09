import XCTest
@testable import Copool

final class AccountCardInteractionPresentationTests: XCTestCase {
    func testMacOSHoverControlsCollapsedOverlayVisibility() {
        let presentation = AccountCardInteractionPresentation(
            isCollapsed: true,
            isCurrent: false,
            switching: false,
            isHoveringCollapsedSwitch: true,
            isCollapsedSwitchOverlayPresented: false,
            platform: .macOS
        )

        XCTAssertTrue(presentation.canHoverSwitchOverlay)
        XCTAssertTrue(presentation.canRevealCollapsedSwitchOverlay)
        XCTAssertTrue(presentation.isCollapsedSwitchOverlayVisible)
    }

    func testSwitchingKeepsOverlayVisibleButPreventsReveal() {
        let presentation = AccountCardInteractionPresentation(
            isCollapsed: true,
            isCurrent: false,
            switching: true,
            isHoveringCollapsedSwitch: false,
            isCollapsedSwitchOverlayPresented: false,
            platform: .macOS
        )

        XCTAssertFalse(presentation.canRevealCollapsedSwitchOverlay)
        XCTAssertTrue(presentation.isCollapsedSwitchOverlayVisible)
    }
}
