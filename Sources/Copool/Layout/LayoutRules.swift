import CoreGraphics

/// Centralized layout inputs to avoid duplicated sizing logic across pages.
enum LayoutRules {
    static let pagePadding = CGFloat(16)
    static let sectionSpacing = CGFloat(16)
    static let cardRadius = CGFloat(14)
    static let liquidProgressHeight = CGFloat(12)
    static let liquidProgressInset = CGFloat(2)
    static let listRowSpacing = CGFloat(10)
    static let tabSwitcherMaxWidth = CGFloat(260)
    static let minimumPanelHeight = CGFloat(520)
    static let defaultPanelHeight = CGFloat(620)
    static let accountsRowSpacing = CGFloat(10)
    static let accountsExpandedColumns = 2
    static let accountsCollapsedColumns = 3
    static let accountsCardWidth = CGFloat(250)
    static let iOSAccountsExpandedColumns = 1
    static let iOSAccountsCollapsedColumns = 2
    static let iOSAccountsScrollBottomPadding = CGFloat(28)
    static let iOSBottomBarHorizontalPadding = CGFloat(16)
    static let iOSBottomBarTopInset = CGFloat(8)
    static let iOSBottomBarBottomInset = CGFloat(10)
    static let iOSNoticeCornerRadius = CGFloat(14)
    static let iOSToolbarButtonSize = CGFloat(44)
    static let toolbarIconPointSize = CGFloat(18)
    static let toolbarRefreshIconOpticalScale = CGFloat(0.82)
    static let proxyDetailCardSpacing = CGFloat(12)
    static let proxyHeroPortFieldWidth = CGFloat(108)
    static let proxyRemoteFieldMinWidth = CGFloat(160)
    static let proxyRemoteActionMinWidth = CGFloat(118)
    static let proxyRemoteMetricMinWidth = CGFloat(108)
    static let proxyRemoteMetricHeight = CGFloat(68)
    static let proxyRemoteDetailMinWidth = CGFloat(220)
    static let proxyRemoteLogsHeight = CGFloat(120)
    static let proxyPublicModeMinWidth = CGFloat(240)
    static let proxyPublicFieldMinWidth = CGFloat(220)
    static let proxyPublicStatusCardMinWidth = CGFloat(170)
    static let inviteToolEditorHeight = CGFloat(180)
    static let inviteToolEditorCornerRadius = CGFloat(12)
    static let inviteToolEditorTextHorizontalInset = CGFloat(12)
    static let inviteToolEditorTextVerticalInset = CGFloat(10)

    static var accountsTwoColumnContentWidth: CGFloat {
        accountsCardWidth * CGFloat(accountsExpandedColumns) + accountsRowSpacing
    }

    static var accountsPageTargetWidth: CGFloat {
        accountsTwoColumnContentWidth + pagePadding * 2
    }

    static var accountsCollapsedCardWidth: CGFloat {
        (accountsPageTargetWidth - pagePadding * 2 - accountsRowSpacing * 2) / CGFloat(accountsCollapsedColumns)
    }

    static var minimumPanelWidth: CGFloat {
        accountsPageTargetWidth
    }

    static var defaultPanelWidth: CGFloat {
        accountsPageTargetWidth
    }

    static var maximumPanelWidth: CGFloat {
        accountsPageTargetWidth
    }

    static func iOSAccountsContentTopPadding(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop + pagePadding
    }

    static func iOSAccountsContentBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        safeAreaBottom + iOSAccountsScrollBottomPadding
    }
}
