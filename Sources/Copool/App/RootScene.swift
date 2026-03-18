import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct RootScene: View {
    @State private var selectedTab: AppTab = .accounts
    @StateObject private var accountsModel: AccountsPageModel
    @StateObject private var inviteToolModel: InviteToolPageModel
    @StateObject private var proxyModel: ProxyPageModel
    @StateObject private var settingsModel: SettingsPageModel
    @ObservedObject private var trayModel: TrayMenuModel

    init(container: AppContainer, trayModel: TrayMenuModel) {
        _accountsModel = StateObject(wrappedValue: container.accountsModel)
        _inviteToolModel = StateObject(wrappedValue: container.inviteToolModel)
        _proxyModel = StateObject(wrappedValue: container.proxyModel)
        _settingsModel = StateObject(wrappedValue: container.settingsModel)
        self.trayModel = trayModel
    }

    private var runtimeLocale: Locale {
        Locale(identifier: AppLocale.resolve(settingsModel.settings.locale).identifier)
    }

    private var currentNotice: NoticeMessage? {
        switch selectedTab {
        case .accounts:
            return accountsModel.notice
        case .inviteTool:
            return inviteToolModel.notice
        case .proxy:
            return proxyModel.notice
        case .settings:
            return settingsModel.notice
        }
    }

    private var currentAppLocale: AppLocale {
        AppLocale.resolve(settingsModel.settings.locale)
    }

    private var visibleTabs: [AppTab] {
        #if os(iOS)
        [.accounts, .inviteTool, .proxy]
        #else
        AppTab.allCases
        #endif
    }

    var body: some View {
        platformTabShell
        .environment(\.locale, runtimeLocale)
        .onAppear {
            L10n.setLocale(identifier: settingsModel.settings.locale)
        }
        .onChange(of: settingsModel.settings.locale) { _, value in
            L10n.setLocale(identifier: value)
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .proxy {
                Task {
                    await proxyModel.refreshForTabEntry()
                }
            }
        }
        .onReceive(trayModel.$accounts.removeDuplicates()) { accounts in
            accountsModel.syncFromBackgroundRefresh(accounts)
        }
        .task {
            await settingsModel.loadIfNeeded()
            await proxyModel.bootstrapOnAppLaunch(using: settingsModel.settings)
        }
        #if os(iOS)
        .animation(.easeInOut(duration: 0.2), value: currentNotice)
        #else
        .overlay(alignment: .top) {
            NoticeBanner(notice: currentNotice)
                .padding(.horizontal, LayoutRules.pagePadding)
                .padding(.top, 6)
                .allowsHitTesting(false)
                .zIndex(10)
        }
        #endif
        #if os(macOS)
        .background {
            WindowSizeEnforcer(
                minWidth: LayoutRules.minimumPanelWidth,
                maxWidth: LayoutRules.maximumPanelWidth,
                minHeight: LayoutRules.minimumPanelHeight,
                idealHeight: LayoutRules.defaultPanelHeight
            )
            .frame(width: 0, height: 0)
        }
        .frame(
            minWidth: LayoutRules.minimumPanelWidth,
            idealWidth: LayoutRules.defaultPanelWidth,
            maxWidth: LayoutRules.maximumPanelWidth,
            minHeight: LayoutRules.minimumPanelHeight
        )
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        #endif
    }

    @ViewBuilder
    private var platformTabShell: some View {
        #if os(iOS)
        TabView(selection: $selectedTab) {
            NavigationStack {
                AccountsPageView(
                    model: accountsModel,
                    currentLocale: currentAppLocale,
                    onSelectLocale: { locale in
                        settingsModel.setLocale(locale.identifier)
                    }
                )
            }
            .tag(AppTab.accounts)
            .tabItem {
                Label {
                    Text(AppTab.accounts.toolbarTitle)
                } icon: {
                    Image(systemName: AppTab.accounts.iconName)
                }
            }

            NavigationStack {
                InviteToolPageView(model: inviteToolModel)
            }
            .tag(AppTab.inviteTool)
            .tabItem {
                Label {
                    Text(AppTab.inviteTool.toolbarTitle)
                } icon: {
                    Image(systemName: AppTab.inviteTool.iconName)
                }
            }

            NavigationStack {
                ProxyPageView(model: proxyModel)
            }
            .tag(AppTab.proxy)
            .tabItem {
                Label {
                    Text(AppTab.proxy.toolbarTitle)
                } icon: {
                    Image(systemName: AppTab.proxy.iconName)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NoticeBanner(notice: currentNotice)
                .allowsHitTesting(false)
                .padding(.horizontal, LayoutRules.pagePadding)
                .padding(.bottom, 6)
        }
        #else
        VStack(spacing: 0) {
            AppTabToolbarSwitcher(selection: $selectedTab, tabs: visibleTabs)
                .frame(maxWidth: LayoutRules.tabSwitcherMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, LayoutRules.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 8)

            activePage
        }
        #endif
    }

    @ViewBuilder
    private var activePage: some View {
        switch selectedTab {
        case .accounts:
            AccountsPageView(
                model: accountsModel,
                currentLocale: currentAppLocale,
                onSelectLocale: { locale in
                    settingsModel.setLocale(locale.identifier)
                }
            )
        case .inviteTool:
            InviteToolPageView(model: inviteToolModel)
        case .proxy:
            ProxyPageView(model: proxyModel)
        case .settings:
            SettingsPageView(model: settingsModel)
        }
    }
}

#if canImport(AppKit)
private struct WindowSizeEnforcer: NSViewRepresentable {
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(on: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(on: nsView.window)
        }
    }

    private func apply(on window: NSWindow?) {
        guard let window else { return }
        window.contentMinSize = NSSize(width: minWidth, height: minHeight)
        window.contentMaxSize = NSSize(width: maxWidth, height: .greatestFiniteMagnitude)

        var targetSize = window.contentLayoutRect.size
        let clampedWidth = min(max(targetSize.width, minWidth), maxWidth)
        let clampedHeight = max(targetSize.height, minHeight)

        guard clampedWidth != targetSize.width || clampedHeight != targetSize.height else { return }
        targetSize.width = clampedWidth
        targetSize.height = clampedHeight > 0 ? clampedHeight : idealHeight
        window.setContentSize(targetSize)
    }
}
#else
private struct WindowSizeEnforcer: View {
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat

    var body: some View {
        EmptyView()
    }
}
#endif

private struct AppTabToolbarSwitcher: View {
    @Binding var selection: AppTab
    let tabs: [AppTab]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = tab
                    }
                } label: {
                    Image(systemName: tab.iconName)
                        .font(.system(size: 16, weight: selection == tab ? .semibold : .medium))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.plain)
                .background {
                    if selection == tab {
                        selectedBackground
                            .padding(3)
                    }
                }
                .overlay(alignment: .trailing) {
                    if shouldShowDivider(after: index) {
                        Rectangle()
                            .fill(separatorColor.opacity(0.55))
                            .frame(width: 1, height: 20)
                    }
                }
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityLabel(Text(tab.titleKey))
            }
        }
        .background { containerBackground }
        .overlay {
            Capsule()
                .strokeBorder(separatorColor, lineWidth: 1)
        }
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sections"))
    }

    @ViewBuilder
    private var containerBackground: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular, in: .capsule)
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var selectedBackground: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(
                    .regular
                        .tint(Color.accentColor.opacity(0.16))
                        .interactive(),
                    in: .capsule
                )
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.12))
                }
        }
    }

    private func shouldShowDivider(after index: Int) -> Bool {
        guard index < tabs.count - 1 else { return false }
        let current = tabs[index]
        let next = tabs[index + 1]
        return selection != current && selection != next
    }

    private var separatorColor: Color {
        #if canImport(AppKit)
        Color(nsColor: .separatorColor).opacity(0.9)
        #else
        Color.secondary.opacity(0.22)
        #endif
    }
}

private extension AppTab {
    var iconName: String {
        switch self {
        case .accounts: return "person.2"
        case .inviteTool: return "ticket"
        case .proxy: return "network"
        case .settings: return "gearshape"
        }
    }

    var titleTranslationKey: String {
        switch self {
        case .accounts: return "tab.accounts"
        case .inviteTool: return ""
        case .proxy: return "tab.proxy"
        case .settings: return "tab.settings"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .accounts: return "tab.accounts"
        case .inviteTool: return "卡密工具"
        case .proxy: return "tab.proxy"
        case .settings: return "tab.settings"
        }
    }

    var toolbarTitle: String {
        switch self {
        case .inviteTool:
            return "卡密工具"
        default:
            return L10n.tr(titleTranslationKey)
        }
    }
}
