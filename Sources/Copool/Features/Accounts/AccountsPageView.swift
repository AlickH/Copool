import SwiftUI

struct AccountsPageView: View {
    @State private var areCardsPresented = false
    @State private var didRunInitialCardEntrance = false

    @ObservedObject var model: AccountsPageModel
    let currentLocale: AppLocale
    let onSelectLocale: (AppLocale) -> Void

    init(
        model: AccountsPageModel,
        currentLocale: AppLocale,
        onSelectLocale: @escaping (AppLocale) -> Void
    ) {
        self.model = model
        self.currentLocale = currentLocale
        self.onSelectLocale = onSelectLocale
        let hasResolvedInitialState = model.hasResolvedInitialState
        _areCardsPresented = State(initialValue: hasResolvedInitialState)
        _didRunInitialCardEntrance = State(initialValue: hasResolvedInitialState)
    }

    var body: some View {
        platformLayout
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await model.loadIfNeeded()
        }
        .onAppear {
            triggerInitialCardEntranceIfNeeded(for: contentAccountCount)
        }
        .onChange(of: contentAccountCount) { _, newValue in
            triggerInitialCardEntranceIfNeeded(for: newValue)
        }
    }

    @ViewBuilder
    private var platformLayout: some View {
        #if os(iOS)
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    contentView
                }
                .padding(.top, LayoutRules.iOSAccountsContentTopPadding(safeAreaTop: proxy.safeAreaInsets.top))
                .padding(.bottom, LayoutRules.iOSAccountsContentBottomPadding(safeAreaBottom: proxy.safeAreaInsets.bottom))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: [.top, .bottom])
            .refreshable {
                await model.refreshUsage()
            }
            .toolbar {
                iOSAccountsToolbar
            }
        }
        #else
        VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
            actionBar
                .padding(.horizontal, LayoutRules.pagePadding)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    contentView
                }
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, LayoutRules.pagePadding)
        #endif
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var iOSAccountsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            LanguageMenuButton(
                currentLocale: currentLocale,
                onSelectLocale: onSelectLocale
            ) {
                ToolbarIconLabel(systemImage: "globe")
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            Button {
                Task { await model.addAccountViaLogin() }
            } label: {
                ToolbarIconLabel(systemImage: "plus")
            }
            .disabled(!model.canAddAccountAction)
            .accessibilityLabel(
                Text(
                    model.isAdding
                        ? L10n.tr("accounts.action.waiting_for_login")
                        : L10n.tr("accounts.action.add_account")
                )
            )
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await model.refreshUsage() }
            } label: {
                ToolbarIconLabel(
                    systemImage: "arrow.trianglehead.clockwise.rotate.90",
                    isSpinning: model.isRefreshing,
                    opticalScale: LayoutRules.toolbarRefreshIconOpticalScale
                )
            }
            .disabled(!model.canRefreshUsageAction)
            .accessibilityLabel(Text("common.refresh_usage"))
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.toggleAllAccountsCollapsed()
                }
            } label: {
                ToolbarIconLabel(
                    systemImage: model.areAllAccountsCollapsed ? "chevron.down" : "chevron.up"
                )
            }
            .accessibilityLabel(
                Text(
                    model.areAllAccountsCollapsed
                        ? L10n.tr("accounts.action.expand_all")
                        : L10n.tr("accounts.action.collapse_all")
                )
            )
        }
    }
    #endif

    private var actionBar: some View {
        HStack(spacing: LayoutRules.listRowSpacing) {
            ScrollView(.horizontal) {
                HStack(spacing: LayoutRules.listRowSpacing) {
                    Button {
                        Task { await model.importCurrentAuth() }
                    } label: {
                        Label(model.isImporting ? L10n.tr("accounts.action.importing") : L10n.tr("accounts.action.import_current_auth"), systemImage: "square.and.arrow.down")
                            .lineLimit(1)
                    }
                    .disabled(!model.canImportCurrentAuthAction)
                    .copoolActionButtonStyle(prominent: true, density: .compact)

                    Button {
                        Task { await model.addAccountViaLogin() }
                    } label: {
                        Label(model.isAdding ? L10n.tr("accounts.action.waiting_for_login") : L10n.tr("accounts.action.add_account"), systemImage: "plus")
                            .lineLimit(1)
                    }
                    .disabled(!model.canAddAccountAction)
                    .copoolActionButtonStyle(prominent: true, density: .compact)

                    Button {
                        Task { await model.smartSwitch() }
                    } label: {
                        Label("accounts.action.smart_switch", systemImage: "wand.and.stars")
                            .lineLimit(1)
                    }
                    .copoolActionButtonStyle(prominent: true, density: .compact)
                    .disabled(!model.canSmartSwitchAction)

                    Button {
                        Task { await model.refreshUsage() }
                    } label: {
                        ToolbarIconLabel(
                            systemImage: "arrow.trianglehead.clockwise.rotate.90",
                            isSpinning: model.isRefreshing,
                            opticalScale: LayoutRules.toolbarRefreshIconOpticalScale
                        )
                    }
                    .disabled(!model.canRefreshUsageAction)
                    .copoolActionButtonStyle(prominent: true, tint: .mint, density: .compact)
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            CollapseChevronButton(isExpanded: !model.areAllAccountsCollapsed) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.toggleAllAccountsCollapsed()
                }
            }
            .accessibilityLabel(
                Text(
                    model.areAllAccountsCollapsed
                        ? L10n.tr("accounts.action.expand_all")
                        : L10n.tr("accounts.action.collapse_all")
                )
            )
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch model.state {
        case .loading:
            ProgressView(L10n.tr("accounts.loading.message"))
                .frame(maxWidth: .infinity, minHeight: 180)
        case .empty(let message):
            EmptyStateView(title: L10n.tr("accounts.empty.title"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .error(let message):
            EmptyStateView(title: L10n.tr("accounts.error.load_failed"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .content(let accounts):
            let isOverviewMode = model.areAllAccountsCollapsed
            let columns = accountGridColumns(isOverviewMode: isOverviewMode)
            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: LayoutRules.accountsRowSpacing
            ) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    AccountCardView(
                        account: account,
                        isCollapsed: model.isAccountCollapsed(account.id),
                        switching: model.switchingAccountID == account.id,
                        onSwitch: { Task { await model.switchAccount(id: account.id) } },
                        onDelete: { Task { await model.deleteAccount(id: account.id) } }
                    )
                    .copoolCardEntrance(index: index, isPresented: areCardsPresented)
                    #if os(iOS)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    #else
                    .frame(width: isOverviewMode ? LayoutRules.accountsCollapsedCardWidth : LayoutRules.accountsCardWidth)
                    #endif
                }
            }
            .padding(.horizontal, LayoutRules.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var contentAccountCount: Int? {
        guard case .content(let accounts) = model.state else { return nil }
        return accounts.count
    }

    private func triggerInitialCardEntranceIfNeeded(for count: Int?) {
        guard count != nil, !didRunInitialCardEntrance else { return }
        didRunInitialCardEntrance = true
        areCardsPresented = true
    }

    private func accountGridColumns(isOverviewMode: Bool) -> [GridItem] {
        #if os(iOS)
        let columnCount = isOverviewMode
            ? LayoutRules.iOSAccountsCollapsedColumns
            : LayoutRules.iOSAccountsExpandedColumns
        return Array(
            repeating: GridItem(
                .flexible(minimum: 0, maximum: .infinity),
                spacing: LayoutRules.accountsRowSpacing,
                alignment: .top
            ),
            count: columnCount
        )
        #else
        if isOverviewMode {
            return Array(
                repeating: GridItem(
                    .fixed(LayoutRules.accountsCollapsedCardWidth),
                    spacing: LayoutRules.accountsRowSpacing,
                    alignment: .top
                ),
                count: LayoutRules.accountsCollapsedColumns
            )
        }

        return Array(
            repeating: GridItem(
                .fixed(LayoutRules.accountsCardWidth),
                spacing: LayoutRules.accountsRowSpacing,
                alignment: .top
                ),
            count: LayoutRules.accountsExpandedColumns
        )
        #endif
    }
}

private struct CardEntranceModifier: ViewModifier {
    let index: Int
    let isPresented: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented ? 0 : 22)
            .scaleEffect(isPresented ? 1 : 0.985)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.86)
                    .delay(min(0.28, Double(index) * 0.035)),
                value: isPresented
            )
    }
}

private extension View {
    func copoolCardEntrance(index: Int, isPresented: Bool) -> some View {
        modifier(CardEntranceModifier(index: index, isPresented: isPresented))
    }
}

private struct AccountCardView: View {
    let account: AccountSummary
    let isCollapsed: Bool
    let switching: Bool
    let onSwitch: () -> Void
    let onDelete: () -> Void
    @Environment(\.locale) private var locale
    @State private var isHoveringCollapsedSwitch = false
    @State private var isCollapsedSwitchOverlayPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCollapsed ? 8 : 8) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        stamp(text: planLabel, tint: toneColor.opacity(0.18), fg: toneColor)
                        if account.isCurrent {
                            stamp(
                                text: L10n.tr("accounts.card.current"),
                                tint: toneColor.opacity(0.24),
                                fg: toneColor
                            )
                        }
                    }
                    if !isCollapsed, let teamNameTag {
                        stamp(text: teamNameTag, tint: Color.secondary.opacity(0.16), fg: .secondary, maxWidth: 140)
                    }
                }

                Spacer(minLength: 0)

                if !isCollapsed {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .copoolActionButtonStyle(
                        prominent: true,
                        tint: .red,
                        density: .compact,
                        iOSStyle: .liquidGlass
                    )
                    .tint(.red)
                }
            }

            Text(displayAccountName)
                .font(.headline)
                .foregroundStyle(account.isCurrent ? toneColor : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if isCollapsed {
                compactUsageSection
            } else {
                windowSection(title: L10n.tr("accounts.window.five_hour"), window: account.usage?.fiveHour, tint: .orange)
                windowSection(title: L10n.tr("accounts.window.one_week"), window: account.usage?.oneWeek, tint: .teal)

                HStack(spacing: 8) {
                    Text(L10n.tr("accounts.card.credits_format", creditsText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, account.isCurrent ? 0 : 42)
                    Spacer(minLength: 0)
                }

                if let usageError = account.usageError, !usageError.isEmpty {
                    Text(usageError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(isCollapsed ? 8 : 10)
        .cardSurface(
            cornerRadius: 12
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(account.isCurrent ? toneColor.opacity(0.45) : .clear, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            if !isCollapsed, !account.isCurrent {
                Button {
                    onSwitch()
                } label: {
                    if switching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .copoolActionButtonStyle(
                    prominent: true,
                    tint: .mint,
                    density: .compact,
                    iOSStyle: .liquidGlass
                )
                .disabled(switching)
                .accessibilityLabel(Text(L10n.tr("accounts.card.switch_to_this")))
                .padding(8)
            }
        }
        .overlay {
            if collapsedSwitchOverlayVisible {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                        }
                        .onTapGesture {
                            dismissCollapsedSwitchOverlay()
                        }

                    Button {
                        onSwitch()
                    } label: {
                        if switching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.tr("accounts.card.switch_to_this"), systemImage: "arrow.left.arrow.right.circle.fill")
                                .lineLimit(1)
                        }
                    }
                    .copoolActionButtonStyle(
                        prominent: true,
                        tint: .mint,
                        density: .compact,
                        iOSStyle: .liquidGlass
                    )
                    .disabled(switching)
                }
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            guard canHoverSwitchOverlay else {
                isHoveringCollapsedSwitch = false
                return
            }
            withAnimation(.easeInOut(duration: 0.16)) {
                isHoveringCollapsedSwitch = hovering
            }
        }
        #if os(iOS)
        .onLongPressGesture(minimumDuration: 0.35) {
            guard canRevealCollapsedSwitchOverlay else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                isCollapsedSwitchOverlayPresented = true
            }
        }
        #endif
        .onChange(of: isCollapsed) { _, collapsed in
            if !collapsed {
                dismissCollapsedSwitchOverlay()
            }
        }
        .onChange(of: account.isCurrent) { _, isCurrent in
            if isCurrent {
                dismissCollapsedSwitchOverlay()
            }
        }
    }

    private var canHoverSwitchOverlay: Bool {
        #if os(macOS)
        isCollapsed && !account.isCurrent
        #else
        false
        #endif
    }

    private var canRevealCollapsedSwitchOverlay: Bool {
        isCollapsed && !account.isCurrent && !switching
    }

    private var collapsedSwitchOverlayVisible: Bool {
        guard isCollapsed && !account.isCurrent else { return false }
        #if os(iOS)
        return isCollapsedSwitchOverlayPresented || switching
        #else
        return isHoveringCollapsedSwitch || switching
        #endif
    }

    private var compactUsageSection: some View {
        HStack(spacing: 14) {
            CompactUsageRing(
                usedPercent: compactUsedPercent(account.usage?.fiveHour),
                tint: .orange
            )
            CompactUsageRing(
                usedPercent: compactUsedPercent(account.usage?.oneWeek),
                tint: .teal
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func windowSection(title: String, window: UsageWindow?, tint: Color) -> some View {
        let usedRaw = clamped(window?.usedPercent)
        let used = roundedPercent(usedRaw)
        let remain = max(0, 100 - used)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(L10n.tr("accounts.window.used_format", percent(used)))
                    .font(.caption.weight(.semibold))
                Text(L10n.tr("accounts.window.remaining_format", percent(remain)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            usageBar(usedPercent: used, tint: tint)

            Text(L10n.tr("accounts.window.reset_at_format", formatResetAt(window?.resetAt)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var planLabel: String {
        let normalized = (account.planType ?? account.usage?.planType ?? "team").lowercased()
        switch normalized {
        case "free": return "FREE"
        case "plus": return "PLUS"
        case "pro": return "PRO"
        case "enterprise": return "ENTERPRISE"
        case "business": return "BUSINESS"
        default: return "TEAM"
        }
    }

    private var teamNameTag: String? {
        guard planLabel == "TEAM" else { return nil }
        return account.displayTeamName
    }

    private var toneColor: Color {
        switch planLabel {
        case "PRO": return .orange
        case "PLUS": return .pink
        case "FREE": return .gray
        case "ENTERPRISE", "BUSINESS": return .indigo
        default: return .teal
        }
    }

    private var creditsText: String {
        guard let credits = account.usage?.credits else { return "--" }
        if credits.unlimited { return L10n.tr("accounts.card.unlimited") }
        return credits.balance ?? "--"
    }

    private var displayAccountName: String {
        let raw = (account.email ?? account.accountID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = raw.firstIndex(of: "@"), atIndex > raw.startIndex else {
            return raw
        }
        return String(raw[..<atIndex])
    }

    private func stamp(text: String, tint: Color, fg: Color, maxWidth: CGFloat? = nil) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(fg)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maxWidth)
            .background(tint, in: Capsule())
    }

    private func clamped(_ value: Double?) -> Double {
        guard let value else { return 100 }
        return max(0, min(100, value))
    }

    private func compactUsedPercent(_ window: UsageWindow?) -> Double? {
        guard let used = window?.usedPercent else { return nil }
        return max(0, min(100, used))
    }

    private func roundedPercent(_ value: Double) -> Double {
        Double(Int(value.rounded()))
    }

    private func usageBar(usedPercent: Double, tint: Color) -> some View {
        LiquidProgressBar(
            progress: usedPercent / 100,
            tint: tint
        )
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func formatResetAt(_ epoch: Int64?) -> String {
        guard let epoch else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private func dismissCollapsedSwitchOverlay() {
        guard isCollapsedSwitchOverlayPresented else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            isCollapsedSwitchOverlayPresented = false
        }
    }
}

private struct CompactUsageRing: View {
    let usedPercent: Double?
    let tint: Color

    private var progress: Double {
        guard let usedPercent else { return 0 }
        return max(0, min(1, usedPercent / 100))
    }

    private var percentText: String {
        guard let usedPercent else { return "--" }
        return "\(Int(usedPercent.rounded()))%"
    }

    var body: some View {
        ZStack {
            LiquidProgressRing(
                progress: progress,
                tint: tint,
                lineWidth: 7
            )
            VStack(spacing: 1) {
                Text(percentText)
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                Text(L10n.tr("accounts.compact.used"))
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 54, height: 54)
    }
}
