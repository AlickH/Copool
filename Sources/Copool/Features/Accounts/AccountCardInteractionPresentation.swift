enum AccountCardInteractionPlatform {
    case macOS
}

struct AccountCardInteractionPresentation: Equatable {
    let canHoverSwitchOverlay: Bool
    let canRevealCollapsedSwitchOverlay: Bool
    let isCollapsedSwitchOverlayVisible: Bool

    init(
        isCollapsed: Bool,
        isCurrent: Bool,
        switching: Bool,
        isHoveringCollapsedSwitch: Bool,
        isCollapsedSwitchOverlayPresented: Bool,
        platform: AccountCardInteractionPlatform
    ) {
        canHoverSwitchOverlay = platform == .macOS && isCollapsed && !isCurrent
        canRevealCollapsedSwitchOverlay = isCollapsed && !isCurrent && !switching

        guard isCollapsed && !isCurrent else {
            isCollapsedSwitchOverlayVisible = false
            return
        }

        isCollapsedSwitchOverlayVisible = isHoveringCollapsedSwitch || switching
    }
}
