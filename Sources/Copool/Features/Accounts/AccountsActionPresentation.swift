import Foundation

enum AccountsPageActionIntent: String, Hashable {
    case importCurrentAuth
    case importAuthFile
    case addAccount
    case cancelAddAccount
    case toggleUsageProgressDisplay
    case smartSwitch
    case refreshUsage
    case toggleCollapse
}

enum AccountsActionContentStyle: Equatable {
    case label
    case icon
}

enum AccountsActionSurfaceStyle: Equatable {
    case neutral
    case prominent
    case mint
}

struct AccountsActionButtonDescriptor<Intent: Hashable>: Identifiable, Equatable {
    let intent: Intent
    let title: String?
    let systemImage: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let isSpinning: Bool
    let contentStyle: AccountsActionContentStyle
    let surfaceStyle: AccountsActionSurfaceStyle
    let menuItems: [AccountsActionMenuItem<Intent>]

    var id: String {
        String(describing: intent)
    }
}

struct AccountsActionMenuItem<Intent: Hashable>: Identifiable, Equatable {
    let intent: Intent
    let title: String
    let systemImage: String

    var id: String {
        "\(String(describing: intent))-\(title)"
    }
}

struct AccountsCollapsePresentation: Equatable {
    let isExpanded: Bool
    let accessibilityLabel: String
}

enum AccountsActionPresentation {
    static func desktopButtons(
        isImporting: Bool,
        isAdding: Bool,
        switchingAccountID: String?,
        canRefreshUsage: Bool,
        isRefreshSpinnerActive: Bool
    ) -> [AccountsActionButtonDescriptor<AccountsPageActionIntent>] {
        [
            AccountsActionButtonDescriptor(
                intent: .importCurrentAuth,
                title: isImporting
                    ? L10n.tr("accounts.action.importing")
                    : L10n.tr("accounts.action.import_account"),
                systemImage: "square.and.arrow.down",
                accessibilityLabel: isImporting
                    ? L10n.tr("accounts.action.importing")
                    : L10n.tr("accounts.action.import_account"),
                isEnabled: !isImporting && !isAdding,
                isSpinning: false,
                contentStyle: .label,
                surfaceStyle: .prominent,
                menuItems: [
                    AccountsActionMenuItem(
                        intent: .importCurrentAuth,
                        title: L10n.tr("accounts.action.import_current_auth"),
                        systemImage: "square.and.arrow.down"
                    ),
                    AccountsActionMenuItem(
                        intent: .importAuthFile,
                        title: L10n.tr("accounts.action.import_auth_file"),
                        systemImage: "doc.badge.plus"
                    )
                ]
            ),
            AccountsActionButtonDescriptor(
                intent: isAdding ? .cancelAddAccount : .addAccount,
                title: isAdding
                    ? L10n.tr("common.cancel")
                    : L10n.tr("accounts.action.add_account"),
                systemImage: isAdding ? "xmark" : "plus",
                accessibilityLabel: isAdding
                    ? L10n.tr("common.cancel")
                    : L10n.tr("accounts.action.add_account"),
                isEnabled: isAdding || (!isImporting && !isAdding),
                isSpinning: false,
                contentStyle: .label,
                surfaceStyle: .prominent,
                menuItems: []
            ),
            AccountsActionButtonDescriptor(
                intent: .smartSwitch,
                title: L10n.tr("accounts.action.smart_switch"),
                systemImage: "wand.and.stars",
                accessibilityLabel: L10n.tr("accounts.action.smart_switch"),
                isEnabled: !isImporting && !isAdding && switchingAccountID == nil,
                isSpinning: false,
                contentStyle: .label,
                surfaceStyle: .prominent,
                menuItems: []
            ),
            AccountsActionButtonDescriptor(
                intent: .refreshUsage,
                title: nil,
                systemImage: "arrow.trianglehead.clockwise.rotate.90",
                accessibilityLabel: L10n.tr("common.refresh_usage"),
                isEnabled: canRefreshUsage,
                isSpinning: isRefreshSpinnerActive,
                contentStyle: .icon,
                surfaceStyle: .mint,
                menuItems: []
            )
        ]
    }

    static func leadingToolbarButtons(
        isImporting: Bool,
        isAdding: Bool
    ) -> [AccountsActionButtonDescriptor<AccountsPageActionIntent>] {
        [
            AccountsActionButtonDescriptor(
                intent: .toggleUsageProgressDisplay,
                title: nil,
                systemImage: "switch.2",
                accessibilityLabel: L10n.tr("accounts.action.toggle_usage_progress_display"),
                isEnabled: !isImporting && !isAdding,
                isSpinning: false,
                contentStyle: .icon,
                surfaceStyle: .neutral,
                menuItems: []
            ),
            AccountsActionButtonDescriptor(
                intent: .importCurrentAuth,
                title: nil,
                systemImage: "square.and.arrow.down",
                accessibilityLabel: L10n.tr("accounts.action.import_account"),
                isEnabled: !isImporting && !isAdding,
                isSpinning: false,
                contentStyle: .icon,
                surfaceStyle: .neutral,
                menuItems: [
                    AccountsActionMenuItem(
                        intent: .importCurrentAuth,
                        title: L10n.tr("accounts.action.import_current_auth"),
                        systemImage: "square.and.arrow.down"
                    ),
                    AccountsActionMenuItem(
                        intent: .importAuthFile,
                        title: L10n.tr("accounts.action.import_auth_file"),
                        systemImage: "doc.badge.plus"
                    )
                ]
            ),
            AccountsActionButtonDescriptor(
                intent: isAdding ? .cancelAddAccount : .addAccount,
                title: nil,
                systemImage: isAdding ? "xmark" : "plus",
                accessibilityLabel: isAdding
                    ? L10n.tr("common.cancel")
                    : L10n.tr("accounts.action.add_account"),
                isEnabled: isAdding || (!isImporting && !isAdding),
                isSpinning: false,
                contentStyle: .icon,
                surfaceStyle: .neutral,
                menuItems: []
            )
        ]
    }

    static func trailingToolbarButtons(
        canRefreshUsage: Bool,
        isRefreshSpinnerActive: Bool,
        areAllAccountsCollapsed: Bool
    ) -> [AccountsActionButtonDescriptor<AccountsPageActionIntent>] {
        [
            AccountsActionButtonDescriptor(
                intent: .refreshUsage,
                title: nil,
                systemImage: "arrow.trianglehead.clockwise.rotate.90",
                accessibilityLabel: L10n.tr("common.refresh_usage"),
                isEnabled: canRefreshUsage,
                isSpinning: isRefreshSpinnerActive,
                contentStyle: .icon,
                surfaceStyle: .neutral,
                menuItems: []
            ),
            AccountsActionButtonDescriptor(
                intent: .toggleCollapse,
                title: nil,
                systemImage: areAllAccountsCollapsed ? "chevron.down" : "chevron.up",
                accessibilityLabel: areAllAccountsCollapsed
                    ? L10n.tr("accounts.action.expand_all")
                    : L10n.tr("accounts.action.collapse_all"),
                isEnabled: true,
                isSpinning: false,
                contentStyle: .icon,
                surfaceStyle: .neutral,
                menuItems: []
            )
        ]
    }

    static func collapseControl(
        areAllAccountsCollapsed: Bool
    ) -> AccountsCollapsePresentation {
        AccountsCollapsePresentation(
            isExpanded: !areAllAccountsCollapsed,
            accessibilityLabel: areAllAccountsCollapsed
                ? L10n.tr("accounts.action.expand_all")
                : L10n.tr("accounts.action.collapse_all")
        )
    }
}
