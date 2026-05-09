import SwiftUI

struct AccountCardView: View {
    let card: AccountCardViewState
    let onSwitch: () -> Void
    let onRefresh: () -> Void
    let onReauthenticate: () -> Void
    let onDelete: () -> Void

    @State private var isHoveringCollapsedSwitch = false
    @State private var isCollapsedSwitchOverlayPresented = false

    init(
        card: AccountCardViewState,
        onSwitch: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onReauthenticate: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.card = card
        self.onSwitch = onSwitch
        self.onRefresh = onRefresh
        self.onReauthenticate = onReauthenticate
        self.onDelete = onDelete
    }

    private var palette: AccountCardPalette {
        AccountCardPalette(accent: card.presentation.accent, isCurrent: card.account.isCurrent)
    }

    private var interactionPresentation: AccountCardInteractionPresentation {
        AccountCardInteractionPresentation(
            isCollapsed: card.isCollapsed,
            isCurrent: card.account.isCurrent,
            switching: card.switching,
            isHoveringCollapsedSwitch: isHoveringCollapsedSwitch,
            isCollapsedSwitchOverlayPresented: isCollapsedSwitchOverlayPresented,
            platform: accountCardInteractionPlatform
        )
    }

    private var presentation: AccountCardPresentation {
        card.presentation
    }

    private var accountCardInteractionPlatform: AccountCardInteractionPlatform {
        .macOS
    }

    var body: some View {
        cardBody
            .copoolCollapsedSwitchHover(
                enabled: interactionPresentation.canHoverSwitchOverlay,
                isHoveringCollapsedSwitch: $isHoveringCollapsedSwitch
            )
            .onChange(of: card.isCollapsed) { _, collapsed in
                if !collapsed {
                    dismissCollapsedSwitchOverlay()
                }
            }
            .onChange(of: card.account.isCurrent) { _, isCurrent in
                if isCurrent {
                    dismissCollapsedSwitchOverlay()
                }
            }
    }

    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.isCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    AccountCompactHeaderContent(
                        planLabel: presentation.planLabel,
                        workspaceLabel: presentation.teamNameTag,
                        statusLabel: presentation.statusLabel,
                        accountName: presentation.displayAccountName,
                        accentColor: palette.toneColor,
                        titleFont: .headline,
                        titleColor: card.account.isCurrent ? palette.toneColor : .primary,
                        spacing: 8
                    )
                    AccountCardCompactUsageSection(presentation: presentation)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    AccountCardHeaderSection(
                        presentation: presentation,
                        isCollapsed: card.isCollapsed,
                        isCurrent: card.account.isCurrent,
                        palette: palette,
                        onDelete: onDelete
                    )

                    Text(presentation.displayAccountName)
                        .font(.headline)
                        .foregroundStyle(card.account.isCurrent ? palette.toneColor : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    AccountCardExpandedUsageSection(presentation: presentation)
                }
            }
        }
        .padding(card.isCollapsed ? 8 : 10)
        .accountCardSurface(cornerRadius: 12, tint: palette.surfaceTint)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.selectionBorderColor ?? .clear, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            AccountCardBottomOverlay(
                isCollapsed: card.isCollapsed,
                isCurrent: card.account.isCurrent,
                switching: card.switching,
                refreshing: card.refreshing,
                showsRefreshButton: card.showsRefreshButton,
                showsReauthenticateButton: card.showsReauthenticateButton,
                isRefreshEnabled: card.isRefreshEnabled,
                usageError: card.isUsageRefreshActive ? nil : card.account.usageError,
                palette: palette,
                onSwitch: onSwitch,
                onRefresh: onRefresh,
                onReauthenticate: onReauthenticate
            )
        }
        .animation(AccountCardMorphRules.animation, value: card.isCollapsed)
        .animation(AccountCardMorphRules.animation, value: card.account.isCurrent)
        .overlay {
            AccountCollapsedSwitchOverlay(
                isVisible: interactionPresentation.isCollapsedSwitchOverlayVisible,
                switching: card.switching,
                onDismiss: dismissCollapsedSwitchOverlay,
                onSwitch: onSwitch
            )
        }
    }

    private func dismissCollapsedSwitchOverlay() {
        guard isCollapsedSwitchOverlayPresented else { return }
        withAnimation(AccountsAnimationRules.cardHoverOverlay) {
            isCollapsedSwitchOverlayPresented = false
        }
    }
}

private struct CollapsedSwitchHoverModifier: ViewModifier {
    let enabled: Bool
    @Binding var isHoveringCollapsedSwitch: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onHover { hovering in
                guard isHoveringCollapsedSwitch != hovering else { return }
                withAnimation(AccountsAnimationRules.cardHoverOverlay) {
                    isHoveringCollapsedSwitch = hovering
                }
            }
        } else {
            content
                .onAppear {
                    isHoveringCollapsedSwitch = false
                }
        }
    }
}

private extension View {
    func copoolCollapsedSwitchHover(
        enabled: Bool,
        isHoveringCollapsedSwitch: Binding<Bool>
    ) -> some View {
        modifier(
            CollapsedSwitchHoverModifier(
                enabled: enabled,
                isHoveringCollapsedSwitch: isHoveringCollapsedSwitch
            )
        )
    }
}
