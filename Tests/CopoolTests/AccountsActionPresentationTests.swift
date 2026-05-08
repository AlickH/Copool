import XCTest
@testable import Copool

final class AccountsActionPresentationTests: XCTestCase {
    func testDesktopButtonsReflectBusyState() {
        let buttons = AccountsActionPresentation.desktopButtons(
            isImporting: true,
            isAdding: false,
            switchingAccountID: nil,
            canRefreshUsage: true,
            isRefreshSpinnerActive: false
        )

        XCTAssertEqual(
            buttons.map(\.intent),
            [.importCurrentAuth, .addAccount, .smartSwitch, .refreshUsage]
        )
        XCTAssertEqual(buttons.first?.title, L10n.tr("accounts.action.importing"))
        XCTAssertFalse(buttons.first?.isEnabled ?? true)
        XCTAssertEqual(buttons.first?.menuItems.map(\.intent), [.importCurrentAuth, .importAuthFile, .pasteImport])
        XCTAssertFalse(buttons[1].isEnabled)
        XCTAssertFalse(buttons[2].isEnabled)
    }

    func testDesktopButtonsSwapAddActionForCancelWhileWaitingForLogin() {
        let buttons = AccountsActionPresentation.desktopButtons(
            isImporting: false,
            isAdding: true,
            switchingAccountID: nil,
            canRefreshUsage: true,
            isRefreshSpinnerActive: false
        )

        XCTAssertEqual(
            buttons.map(\.intent),
            [.importCurrentAuth, .cancelAddAccount, .smartSwitch, .refreshUsage]
        )
        XCTAssertEqual(buttons[0].title, L10n.tr("accounts.action.import_account"))
        XCTAssertEqual(buttons[0].menuItems.map(\.title), [
            L10n.tr("accounts.action.import_current_auth"),
            L10n.tr("accounts.action.import_auth_file"),
            L10n.tr("accounts.action.paste_import")
        ])
        XCTAssertEqual(buttons[1].title, L10n.tr("common.cancel"))
        XCTAssertTrue(buttons[1].isEnabled)
        XCTAssertEqual(buttons[1].systemImage, "xmark")
    }

    func testTrailingToolbarButtonsReflectCollapseStateAndSpinner() {
        let buttons = AccountsActionPresentation.trailingToolbarButtons(
            canRefreshUsage: true,
            isRefreshSpinnerActive: true,
            areAllAccountsCollapsed: true
        )

        XCTAssertEqual(buttons.map(\.intent), [.refreshUsage, .toggleCollapse])
        XCTAssertTrue(buttons[0].isSpinning)
        XCTAssertEqual(buttons[1].systemImage, "chevron.down")
        XCTAssertEqual(
            buttons[1].accessibilityLabel,
            L10n.tr("accounts.action.expand_all")
        )
    }

    func testLeadingToolbarButtonsIncludeUsageToggleIconOnIOS() {
        let buttons = AccountsActionPresentation.leadingToolbarButtons(
            isImporting: false,
            isAdding: false
        )

        XCTAssertEqual(buttons.map(\.intent), [.toggleUsageProgressDisplay, .importCurrentAuth, .addAccount])
        XCTAssertEqual(buttons[0].systemImage, "switch.2")
        XCTAssertEqual(buttons[0].accessibilityLabel, L10n.tr("accounts.action.toggle_usage_progress_display"))
        XCTAssertEqual(buttons[1].accessibilityLabel, L10n.tr("accounts.action.import_account"))
        XCTAssertEqual(buttons[1].menuItems.map(\.intent), [.importCurrentAuth, .importAuthFile, .pasteImport])
    }
}
