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
    @StateObject private var chromeStore: RootSceneChromeStore
    @StateObject private var deferredProxyModel = DeferredProxyModelStore()
    private let trayModel: TrayMenuModel
    private let accountsModel: AccountsPageModel
    private let settingsModel: SettingsPageModel
    private let container: AppContainer

    init(container: AppContainer, trayModel: TrayMenuModel) {
        self.container = container
        self.accountsModel = container.accountsModel
        self.settingsModel = container.settingsModel
        _chromeStore = StateObject(
            wrappedValue: RootSceneChromeStore(
                accountsModel: container.accountsModel,
                settingsModel: container.settingsModel
            )
        )
        self.trayModel = trayModel
    }

    private var runtimeLocale: Locale {
        Locale(identifier: AppLocale.resolve(chromeStore.localeIdentifier).identifier)
    }

    private var currentNotice: NoticeMessage? {
        switch selectedTab {
        case .accounts:
            return chromeStore.accountsNotice
        case .proxy:
            return deferredProxyModel.model?.notice
        case .settings:
            return chromeStore.settingsNotice
        }
    }

    private var currentAppLocale: AppLocale {
        AppLocale.resolve(chromeStore.localeIdentifier)
    }

    private var visibleTabs: [AppTab] {
        #if os(iOS)
        [.accounts, .proxy]
        #else
        AppTab.allCases
        #endif
    }

    var body: some View {
        platformTabShell
        .environment(\.locale, runtimeLocale)
        .onAppear {
            L10n.setLocale(identifier: chromeStore.localeIdentifier)
        }
        .onChange(of: chromeStore.localeIdentifier) { _, value in
            L10n.setLocale(identifier: value)
        }
        .onReceive(trayModel.$accounts.removeDuplicates()) { _ in
            Task {
                await accountsModel.reloadFromLocalStoreAfterExternalMutation()
            }
        }
        .onReceive(trayModel.$remoteUsageRefreshingAccountIDs.removeDuplicates()) { accountIDs in
            accountsModel.syncRemoteUsageRefreshActivity(refreshingAccountIDs: accountIDs)
        }
        .onChange(of: selectedTab) { _, value in
            guard value == .proxy else { return }
            deferredProxyModel.loadIfNeeded(using: container)
        }
        .task {
            await accountsModel.loadIfNeeded()
        }
        .task {
            await settingsModel.loadIfNeeded()
        }
        .rootSceneNoticePresentation(currentNotice)
        #if os(macOS)
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
                proxyTabContent
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
        case .proxy:
            proxyTabContent
        case .settings:
            SettingsPageView(model: settingsModel)
        }
    }

    @ViewBuilder
    private var proxyTabContent: some View {
        if let proxyModel = deferredProxyModel.model {
            ProxyPageView(model: proxyModel)
        } else {
            DeferredPagePlaceholder()
                .task {
                    deferredProxyModel.loadIfNeeded(using: container)
                }
        }
    }
}

@MainActor
private final class RootSceneChromeStore: ObservableObject {
    @Published private(set) var localeIdentifier: String
    @Published private(set) var accountsNotice: NoticeMessage?
    @Published private(set) var settingsNotice: NoticeMessage?

    private var cancellables: Set<AnyCancellable> = []

    init(accountsModel: AccountsPageModel, settingsModel: SettingsPageModel) {
        localeIdentifier = settingsModel.settings.locale
        accountsNotice = accountsModel.notice
        settingsNotice = settingsModel.notice

        settingsModel.$settings
            .map(\.locale)
            .removeDuplicates()
            .sink { [weak self] localeIdentifier in
                self?.localeIdentifier = localeIdentifier
            }
            .store(in: &cancellables)

        accountsModel.$notice
            .removeDuplicates()
            .sink { [weak self] notice in
                self?.accountsNotice = notice
            }
            .store(in: &cancellables)

        settingsModel.$notice
            .removeDuplicates()
            .sink { [weak self] notice in
                self?.settingsNotice = notice
            }
            .store(in: &cancellables)
    }
}

@MainActor
private final class DeferredProxyModelStore: ObservableObject {
    @Published private(set) var model: ProxyPageModel?

    func loadIfNeeded(using container: AppContainer) {
        guard model == nil else { return }
        model = container.proxyModel
    }
}

private struct DeferredPagePlaceholder: View {
    var body: some View {
        VStack {
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private extension View {
    @ViewBuilder
    func rootSceneNoticePresentation(_ notice: NoticeMessage?) -> some View {
        #if os(iOS)
        self
            .animation(.easeInOut(duration: 0.2), value: notice)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NoticeBanner(notice: notice)
                    .allowsHitTesting(false)
                    .padding(.horizontal, LayoutRules.pagePadding)
                    .padding(.bottom, 6)
            }
        #else
        self
            .overlay(alignment: .top) {
                NoticeBanner(notice: notice)
                    .padding(.horizontal, LayoutRules.pagePadding)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        #endif
    }
}

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
        case .proxy: return "network"
        case .settings: return "gearshape"
        }
    }

    var titleTranslationKey: String {
        switch self {
        case .accounts: return "tab.accounts"
        case .proxy: return "tab.proxy"
        case .settings: return "tab.settings"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .accounts: return "tab.accounts"
        case .proxy: return "tab.proxy"
        case .settings: return "tab.settings"
        }
    }

    var toolbarTitle: String {
        L10n.tr(titleTranslationKey)
    }
}
