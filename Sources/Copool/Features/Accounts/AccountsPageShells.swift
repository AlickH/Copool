import SwiftUI

struct AccountsPageShell: View {
    let contentStore: AccountsPageViewStore
    let chromeStore: AccountsPageChromeStore
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
            contentStore: contentStore,
            chromeStore: chromeStore,
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
            contentStore: contentStore,
            chromeStore: chromeStore,
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
    let contentStore: AccountsPageViewStore
    let chromeStore: AccountsPageChromeStore
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
                contentStore: contentStore,
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
                    chromeStore: chromeStore,
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
    let contentStore: AccountsPageViewStore
    let chromeStore: AccountsPageChromeStore
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
                chromeStore: chromeStore,
                onTriggerAction: onTriggerAction,
                onToggleCollapse: onToggleCollapse
            )
            .padding(.horizontal, LayoutRules.pagePadding)
            .frame(width: pageContentWidth, alignment: .leading)

            AccountsMacContentHost(
                contentStore: contentStore,
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
    @ObservedObject var chromeStore: AccountsPageChromeStore
    let onTriggerAction: (AccountsPageActionIntent) -> Void
    let onToggleCollapse: () -> Void

    var body: some View {
        AccountsActionBarView(
            presentation: chromeStore.macActionBarPresentation,
            onTriggerAction: onTriggerAction,
            onToggleCollapse: onToggleCollapse
        )
    }
}

#if os(iOS)
private struct AccountsIOSContentHost: View {
    @ObservedObject var contentStore: AccountsPageViewStore
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
                    presentation: contentStore.contentPresentation,
                    cardStoreProvider: contentStore.cardStore(for:),
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
    @ObservedObject var contentStore: AccountsPageViewStore
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
                    presentation: contentStore.contentPresentation,
                    cardStoreProvider: contentStore.cardStore(for:),
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
    @ObservedObject var chromeStore: AccountsPageChromeStore
    let currentLocale: AppLocale
    let onSelectLocale: (AppLocale) -> Void
    let onTriggerAction: (AccountsPageActionIntent) -> Void
    let onToggleCollapse: () -> Void

    var body: some ToolbarContent {
        AccountsToolbarActions(
            leadingButtons: chromeStore.leadingToolbarButtons,
            trailingButtons: chromeStore.trailingToolbarButtons,
            currentLocale: currentLocale,
            onSelectLocale: onSelectLocale,
            onTriggerAction: onTriggerAction,
            onToggleCollapse: onToggleCollapse
        )
    }
}
#endif
