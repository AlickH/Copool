import SwiftUI

struct AccountsPageContentSection: View {
    let presentation: AccountsPageContentPresentation
    let cardStoreProvider: (String) -> AccountCardStore?
    let availableViewportSize: CGSize
    let areCardsPresented: Bool
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void
    let onDeleteAccount: (String) -> Void

    var body: some View {
        switch presentation.state {
        case .loading:
            ProgressView(L10n.tr("accounts.loading.message"))
                .frame(maxWidth: .infinity, minHeight: 180)
        case .empty(let message):
            EmptyStateView(title: L10n.tr("accounts.empty.title"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .error(let message):
            EmptyStateView(title: L10n.tr("accounts.error.load_failed"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .content(let cards):
            VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
                if presentation.shouldShowPendingWorkspaceSection {
                    PendingWorkspaceAuthorizationSection(
                        cards: presentation.pendingWorkspaceCards,
                        errorMessage: presentation.pendingWorkspaceError,
                        areCardsPresented: areCardsPresented,
                        onAuthorizeWorkspace: onAuthorizeWorkspace,
                        onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
                        onDeletePendingWorkspace: onDeletePendingWorkspace
                    )
                }

                AccountsGridSection(
                    cardIDs: cards,
                    cardStoreProvider: cardStoreProvider,
                    isOverviewMode: presentation.isOverviewMode,
                    availableViewportSize: availableViewportSize,
                    areCardsPresented: areCardsPresented,
                    onSwitchAccount: onSwitchAccount,
                    onRefreshAccountUsage: onRefreshAccountUsage,
                    onReauthenticateAccount: onReauthenticateAccount,
                    onDeleteAccount: onDeleteAccount
                )
            }
        }
    }
}

private struct AccountsGridSection: View {
    let cardIDs: [String]
    let cardStoreProvider: (String) -> AccountCardStore?
    let isOverviewMode: Bool
    let availableViewportSize: CGSize
    let areCardsPresented: Bool
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onDeleteAccount: (String) -> Void

    private var gridContext: LayoutRules.AccountsGridContext {
        #if os(iOS)
        LayoutRules.accountsGridContext(
            isOverviewMode: isOverviewMode,
            viewportSize: availableViewportSize
        )
        #else
        LayoutRules.AccountsGridContext(
            platform: .macOS,
            isOverviewMode: isOverviewMode,
            viewportSize: availableViewportSize
        )
        #endif
    }

    private var columns: [GridItem] {
        LayoutRules.accountsGridColumns(context: gridContext)
    }

    private var cardFrameWidth: CGFloat? {
        LayoutRules.accountsCardFrameWidth(context: gridContext)
    }

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: LayoutRules.accountsRowSpacing
        ) {
            ForEach(Array(cardIDs.enumerated()), id: \.element) { index, cardID in
                if let store = cardStoreProvider(cardID) {
                    AccountCardGridItem(
                        store: store,
                        areCardsPresented: areCardsPresented,
                        frameWidth: cardFrameWidth,
                        index: index,
                        onSwitch: { onSwitchAccount(cardID) },
                        onRefresh: { onRefreshAccountUsage(cardID) },
                        onReauthenticate: { onReauthenticateAccount(cardID) },
                        onDelete: { onDeleteAccount(cardID) }
                    )
                }
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountCardGridItem: View {
    @ObservedObject var store: AccountCardStore
    let areCardsPresented: Bool
    let frameWidth: CGFloat?
    let index: Int
    let onSwitch: () -> Void
    let onRefresh: () -> Void
    let onReauthenticate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        AccountCardView(
            card: store.presentation,
            onSwitch: onSwitch,
            onRefresh: onRefresh,
            onReauthenticate: onReauthenticate,
            onDelete: onDelete
        )
        .frame(width: frameWidth)
        .copoolCardEntrance(index: index, isPresented: areCardsPresented)
        .modifier(AccountCardFrameModifier())
    }
}

private struct CardEntranceModifier: ViewModifier {
    let index: Int
    let isPresented: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented ? 0 : 22)
            .animation(
                AccountsAnimationRules.cardEntrance(index: index),
                value: isPresented
            )
    }
}

private extension View {
    func copoolCardEntrance(index: Int, isPresented: Bool) -> some View {
        modifier(CardEntranceModifier(index: index, isPresented: isPresented))
    }
}

private struct AccountCardFrameModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct PendingWorkspaceAuthorizationSection: View {
    let cards: [PendingWorkspaceAuthorizationCardViewState]
    let errorMessage: String?
    let areCardsPresented: Bool
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("accounts.pending.title"))
                    .font(.headline)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(L10n.tr("accounts.pending.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, LayoutRules.pagePadding)

            if let errorMessage, cards.isEmpty {
                PendingWorkspaceAuthorizationFailureCard(message: errorMessage)
                    .copoolCardEntrance(index: 0, isPresented: areCardsPresented)
                    .modifier(AccountCardFrameModifier())
                    .padding(.horizontal, LayoutRules.pagePadding)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: LayoutRules.accountsRowSpacing, alignment: .top)],
                    alignment: .leading,
                    spacing: LayoutRules.accountsRowSpacing
                ) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        PendingWorkspaceAuthorizationCard(
                            card: card,
                            onAuthorize: { onAuthorizeWorkspace(card.id) },
                            onCancelAuthorize: onCancelAuthorizeWorkspace,
                            onDelete: { onDeletePendingWorkspace(card.id) }
                        )
                        .copoolCardEntrance(index: index, isPresented: areCardsPresented)
                        .modifier(AccountCardFrameModifier())
                    }
                }
                .animation(
                    AccountsAnimationRules.contentReorder,
                    value: cards.map(\.id)
                )
                .padding(.horizontal, LayoutRules.pagePadding)
            }
        }
    }
}

private struct PendingWorkspaceAuthorizationCard: View {
    let card: PendingWorkspaceAuthorizationCardViewState
    let onAuthorize: () -> Void
    let onCancelAuthorize: () -> Void
    let onDelete: () -> Void

    private var isDeactivated: Bool {
        card.status == .deactivated
    }

    private var planLabel: String {
        AccountPlanLabel.normalized(from: card.planType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AccountTagView(
                            text: planLabel,
                            backgroundColor: Color.indigo.opacity(0.18),
                            foregroundColor: .indigo
                        )
                        AccountTagView(
                            text: card.workspaceName,
                            backgroundColor: Color.indigo.opacity(0.18),
                            foregroundColor: .indigo,
                            allowsCompression: true
                        )
                    }

                    if let email = card.email, !email.isEmpty {
                        Text(email)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                AccountTagView(
                    text: isDeactivated ? L10n.tr("accounts.card.status.deactivated") : L10n.tr("accounts.pending.tag"),
                    backgroundColor: isDeactivated ? Color.red.opacity(0.18) : Color.orange.opacity(0.18),
                    foregroundColor: isDeactivated ? .red : .orange
                )
            }

            Text(isDeactivated ? L10n.tr("error.accounts.workspace_deactivated") : L10n.tr("accounts.pending.hint"))
                .font(.caption)
                .foregroundStyle(isDeactivated ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                if !isDeactivated {
                    Button(action: card.authorizing ? onCancelAuthorize : onAuthorize) {
                        Label(
                            card.authorizing ? L10n.tr("common.cancel") : L10n.tr("accounts.pending.action.authorize"),
                            systemImage: card.authorizing ? "xmark.circle" : "checkmark.shield"
                        )
                        .lineLimit(1)
                    }
                    .copoolActionButtonStyle(
                        prominent: !card.authorizing,
                        tint: card.authorizing ? .secondary : .indigo,
                        density: .compact,
                        iOSStyle: .liquidGlass
                    )
                }

                Spacer(minLength: 0)

                AccountDeleteButton(action: onDelete, isDisabled: card.authorizing)
                    .accessibilityLabel(L10n.tr("accounts.pending.action.delete"))
            }
        }
        .padding(12)
        .frostedRoundedSurface(
            cornerRadius: 12,
            prominent: true,
            tint: isDeactivated ? .red.opacity(0.18) : .indigo.opacity(0.2)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDeactivated ? Color.red.opacity(0.18) : Color.indigo.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct PendingWorkspaceAuthorizationFailureCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                AccountTagView(
                    text: L10n.tr("accounts.pending.error.tag"),
                    backgroundColor: Color.red.opacity(0.18),
                    foregroundColor: .red
                )
                Spacer(minLength: 0)
            }

            Text(L10n.tr("accounts.pending.error.title"))
                .font(.headline)
                .foregroundStyle(.primary)

            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.tr("accounts.pending.error.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frostedRoundedSurface(cornerRadius: 12, prominent: true, tint: .red.opacity(0.18))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
        }
    }
}
