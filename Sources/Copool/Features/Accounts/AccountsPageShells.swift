import SwiftUI

struct AccountsPageShell: View {
    @ObservedObject var model: AccountsPageModel
    let currentLocale: AppLocale
    let onSelectLocale: (AppLocale) -> Void
    let areCardsPresented: Bool
    let onTriggerAction: (AccountsPageActionIntent) -> Void
    let onToggleCollapse: () -> Void
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void
    let onDeleteAccount: (String) -> Void

    var body: some View {
        #if os(iOS)
        AccountsIOSPageShell(
            model: model,
            currentLocale: currentLocale,
            onSelectLocale: onSelectLocale,
            areCardsPresented: areCardsPresented,
            onTriggerAction: onTriggerAction,
            onToggleCollapse: onToggleCollapse,
            onSwitchAccount: onSwitchAccount,
            onRefreshAccountUsage: onRefreshAccountUsage,
            onReauthenticateAccount: onReauthenticateAccount,
            onAuthorizeWorkspace: onAuthorizeWorkspace,
            onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
            onDeletePendingWorkspace: onDeletePendingWorkspace,
            onDeleteAccount: onDeleteAccount
        )
        #else
        AccountsMacPageShell(
            model: model,
            areCardsPresented: areCardsPresented,
            onTriggerAction: onTriggerAction,
            onToggleCollapse: onToggleCollapse,
            onSwitchAccount: onSwitchAccount,
            onRefreshAccountUsage: onRefreshAccountUsage,
            onReauthenticateAccount: onReauthenticateAccount,
            onAuthorizeWorkspace: onAuthorizeWorkspace,
            onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
            onDeletePendingWorkspace: onDeletePendingWorkspace,
            onDeleteAccount: onDeleteAccount
        )
        #endif
    }
}

#if os(iOS)
private struct AccountsIOSPageShell: View {
    @ObservedObject var model: AccountsPageModel
    let currentLocale: AppLocale
    let onSelectLocale: (AppLocale) -> Void
    let areCardsPresented: Bool
    let onTriggerAction: (AccountsPageActionIntent) -> Void
    let onToggleCollapse: () -> Void
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void
    let onDeleteAccount: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            AccountsIOSContentHost(
                model: model,
                safeAreaInsets: proxy.safeAreaInsets,
                viewportSize: proxy.size,
                areCardsPresented: areCardsPresented,
                onSwitchAccount: onSwitchAccount,
                onRefreshAccountUsage: onRefreshAccountUsage,
                onReauthenticateAccount: onReauthenticateAccount,
                onAuthorizeWorkspace: onAuthorizeWorkspace,
                onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
                onDeletePendingWorkspace: onDeletePendingWorkspace,
                onDeleteAccount: onDeleteAccount
            )
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: [.top, .bottom])
            .refreshable {
                onTriggerAction(.refreshUsage)
            }
            .toolbar {
                AccountsToolbarHost(
                    model: model,
                    currentLocale: currentLocale,
                    onSelectLocale: onSelectLocale,
                    onTriggerAction: onTriggerAction,
                    onToggleCollapse: onToggleCollapse
                )
            }
        }
    }
}
#endif

private struct AccountsMacPageShell: View {
    @ObservedObject var model: AccountsPageModel
    let areCardsPresented: Bool
    let onTriggerAction: (AccountsPageActionIntent) -> Void
    let onToggleCollapse: () -> Void
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void
    let onDeleteAccount: (String) -> Void

    private var pageContentWidth: CGFloat {
        LayoutRules.accountsPageContentWidth(isCompactWidth: false) ?? LayoutRules.accountsPageTargetWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
            AccountsMacActionBarHost(
                model: model,
                onTriggerAction: onTriggerAction,
                onToggleCollapse: onToggleCollapse
            )
            .padding(.horizontal, LayoutRules.pagePadding)
            .frame(width: pageContentWidth, alignment: .leading)

            AccountsMacContentHost(
                model: model,
                pageContentWidth: pageContentWidth,
                areCardsPresented: areCardsPresented,
                onSwitchAccount: onSwitchAccount,
                onRefreshAccountUsage: onRefreshAccountUsage,
                onReauthenticateAccount: onReauthenticateAccount,
                onAuthorizeWorkspace: onAuthorizeWorkspace,
                onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
                onDeletePendingWorkspace: onDeletePendingWorkspace,
                onDeleteAccount: onDeleteAccount
            )
            .scrollIndicators(.hidden)
        }
        .frame(width: pageContentWidth, alignment: .topLeading)
        .padding(.top, LayoutRules.pagePadding)
    }
}

private struct AccountsMacActionBarHost: View {
    @ObservedObject var model: AccountsPageModel
    let onTriggerAction: (AccountsPageActionIntent) -> Void
    let onToggleCollapse: () -> Void

    var body: some View {
        AccountsActionBarView(
            presentation: model.makeMacActionBarPresentation(),
            onTriggerAction: onTriggerAction,
            onToggleCollapse: onToggleCollapse
        )
    }
}

#if os(iOS)
private struct AccountsIOSContentHost: View {
    @ObservedObject var model: AccountsPageModel
    let safeAreaInsets: EdgeInsets
    let viewportSize: CGSize
    let areCardsPresented: Bool
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void
    let onDeleteAccount: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AccountsPageContentSection(
                    presentation: model.makeContentPresentation(),
                    cards: model.makeAccountCardViewStates(),
                    availableViewportSize: viewportSize,
                    areCardsPresented: areCardsPresented,
                    onSwitchAccount: onSwitchAccount,
                    onRefreshAccountUsage: onRefreshAccountUsage,
                    onReauthenticateAccount: onReauthenticateAccount,
                    onAuthorizeWorkspace: onAuthorizeWorkspace,
                    onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
                    onDeletePendingWorkspace: onDeletePendingWorkspace,
                    onDeleteAccount: onDeleteAccount
                )
            }
            .padding(.top, LayoutRules.iOSAccountsContentTopPadding(safeAreaTop: safeAreaInsets.top))
            .padding(.bottom, LayoutRules.iOSAccountsContentBottomPadding(safeAreaBottom: safeAreaInsets.bottom))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif

private struct AccountsMacContentHost: View {
    @ObservedObject var model: AccountsPageModel
    let pageContentWidth: CGFloat
    let areCardsPresented: Bool
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void
    let onDeleteAccount: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AccountsPageContentSection(
                    presentation: model.makeContentPresentation(),
                    cards: model.makeAccountCardViewStates(),
                    availableViewportSize: CGSize(
                        width: pageContentWidth,
                        height: LayoutRules.defaultPanelHeight
                    ),
                    areCardsPresented: areCardsPresented,
                    onSwitchAccount: onSwitchAccount,
                    onRefreshAccountUsage: onRefreshAccountUsage,
                    onReauthenticateAccount: onReauthenticateAccount,
                    onAuthorizeWorkspace: onAuthorizeWorkspace,
                    onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
                    onDeletePendingWorkspace: onDeletePendingWorkspace,
                    onDeleteAccount: onDeleteAccount
                )
            }
            .padding(.bottom, 12)
            .frame(width: pageContentWidth, alignment: .leading)
        }
    }
}

#if os(iOS)
private struct AccountsToolbarHost: ToolbarContent {
    @ObservedObject var model: AccountsPageModel
    let currentLocale: AppLocale
    let onSelectLocale: (AppLocale) -> Void
    let onTriggerAction: (AccountsPageActionIntent) -> Void
    let onToggleCollapse: () -> Void

    var body: some ToolbarContent {
        AccountsToolbarActions(
            leadingButtons: model.leadingToolbarButtons,
            trailingButtons: model.trailingToolbarButtons,
            currentLocale: currentLocale,
            onSelectLocale: onSelectLocale,
            onTriggerAction: onTriggerAction,
            onToggleCollapse: onToggleCollapse
        )
    }
}
#endif
