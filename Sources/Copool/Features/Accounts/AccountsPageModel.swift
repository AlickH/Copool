import Foundation
import Combine

@MainActor
final class AccountsPageModel: ObservableObject {
    let coordinator: AccountsCoordinator
    let settingsCoordinator: SettingsCoordinator?
    let manualRefreshService: AccountsManualRefreshServiceProtocol?
    let localAccountsMutationSyncService: AccountsLocalMutationSyncServiceProtocol?
    let chooseAuthDocumentURL: (() -> URL?)?
    let onLocalAccountsChanged: (([AccountSummary]) -> Void)?
    let onSettingsUpdated: ((AppSettings) -> Void)?
    let runtimePlatform: RuntimePlatform

    private let noticeScheduler = NoticeAutoDismissScheduler()
    var pendingWorkspaceRefreshTask: Task<Void, Never>?
    var addAccountTask: Task<AccountSummary, Error>?
    var pendingWorkspaceAuthorizationTask: Task<AccountSummary, Error>?

    var hasLoaded = false
    @Published var usageProgressDisplayMode: UsageProgressDisplayMode

    @Published var state: ViewState<[AccountSummary]>
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }
    @Published var isManualRefreshing = false
    @Published var isRemoteUsageRefreshing = false
    @Published var remoteUsageRefreshingAccountIDs: Set<String> = []
    @Published var isImporting = false
    @Published var isAdding = false
    @Published var switchingAccountID: String?
    @Published var refreshingAccountIDs: Set<String> = []
    @Published var collapsedAccountIDs: Set<String> = []
    @Published var workspaceDirectory: [WorkspaceDirectoryEntry] = []
    @Published var pendingWorkspaceAuthorizations: [WorkspaceAuthorizationCandidate] = []
    @Published var pendingWorkspaceAuthorizationError: String?
    @Published var authorizingWorkspaceID: String?

    init(
        coordinator: AccountsCoordinator,
        settingsCoordinator: SettingsCoordinator? = nil,
        manualRefreshService: AccountsManualRefreshServiceProtocol? = nil,
        localAccountsMutationSyncService: AccountsLocalMutationSyncServiceProtocol? = nil,
        chooseAuthDocumentURL: (() -> URL?)? = nil,
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform,
        usageProgressDisplayMode: UsageProgressDisplayMode = .used,
        onLocalAccountsChanged: (([AccountSummary]) -> Void)? = nil,
        onSettingsUpdated: ((AppSettings) -> Void)? = nil,
        initialAccounts: [AccountSummary]? = nil
    ) {
        self.coordinator = coordinator
        self.settingsCoordinator = settingsCoordinator
        self.manualRefreshService = manualRefreshService
        self.localAccountsMutationSyncService = localAccountsMutationSyncService
        self.chooseAuthDocumentURL = chooseAuthDocumentURL
        self.runtimePlatform = runtimePlatform
        self.usageProgressDisplayMode = usageProgressDisplayMode
        self.onLocalAccountsChanged = onLocalAccountsChanged
        self.onSettingsUpdated = onSettingsUpdated
        self.state = initialAccounts.map { initialAccounts in
            Self.makeViewState(accounts: AccountRanking.sortForDisplay(initialAccounts))
        } ?? .loading
    }

    var canRefreshUsageAction: Bool {
        !isAdding
    }

    var areAllAccountsCollapsed: Bool {
        guard case .content(let accounts) = state else { return false }
        let ids = Set(accounts.filter { !$0.isWorkspaceDeactivated }.map(\.id))
        guard !ids.isEmpty else { return false }
        return collapsedAccountIDs.isSuperset(of: ids)
    }

    var hasResolvedInitialState: Bool {
        if case .loading = state {
            return false
        }
        return true
    }

    var isRefreshing: Bool {
        isManualRefreshing || isRemoteUsageRefreshing || !refreshingAccountIDs.isEmpty
    }

    var isRefreshSpinnerActive: Bool {
        isManualRefreshing
    }

    deinit {
        addAccountTask?.cancel()
        pendingWorkspaceAuthorizationTask?.cancel()
        pendingWorkspaceRefreshTask?.cancel()
    }

    var desktopActionButtons: [AccountsActionButtonDescriptor<AccountsPageActionIntent>] {
        AccountsActionPresentation.desktopButtons(
            isImporting: isImporting,
            isAdding: isAdding,
            switchingAccountID: switchingAccountID,
            canRefreshUsage: canRefreshUsageAction,
            isRefreshSpinnerActive: isRefreshSpinnerActive
        )
    }

    var leadingToolbarButtons: [AccountsActionButtonDescriptor<AccountsPageActionIntent>] {
        let buttons = AccountsActionPresentation.leadingToolbarButtons(
            isImporting: isImporting,
            isAdding: isAdding
        )
        return buttons
    }

    var trailingToolbarButtons: [AccountsActionButtonDescriptor<AccountsPageActionIntent>] {
        AccountsActionPresentation.trailingToolbarButtons(
            canRefreshUsage: canRefreshUsageAction,
            isRefreshSpinnerActive: isRefreshSpinnerActive,
            areAllAccountsCollapsed: areAllAccountsCollapsed
        )
    }

    var collapsePresentation: AccountsCollapsePresentation {
        AccountsActionPresentation.collapseControl(
            areAllAccountsCollapsed: areAllAccountsCollapsed
        )
    }

    func isAccountCollapsed(_ id: String) -> Bool {
        collapsedAccountIDs.contains(id)
    }

    func isAccountRefreshing(_ id: String) -> Bool {
        refreshingAccountIDs.contains(id)
    }

    func canRefreshAccount(_ id: String) -> Bool {
        runtimePlatform == .macOS
            && !refreshingAccountIDs.contains(id)
            && (isManualRefreshing || !remoteUsageRefreshingAccountIDs.contains(id))
    }

    func isUsageRefreshActive(forAccountID id: String) -> Bool {
        (!isManualRefreshing && remoteUsageRefreshingAccountIDs.contains(id))
            || refreshingAccountIDs.contains(id)
    }

    func handlePageAction(_ intent: AccountsPageActionIntent) async {
        switch intent {
        case .importCurrentAuth:
            await importCurrentAuth()
        case .importAuthFile:
            guard let url = chooseAuthDocumentURL?() else { return }
            await importAuthDocument(from: url, setAsCurrent: false)
        case .addAccount:
            await addAccountViaLogin()
        case .cancelAddAccount:
            cancelAddAccount()
        case .toggleUsageProgressDisplay:
            await toggleUsageProgressDisplay()
        case .smartSwitch:
            await smartSwitch()
        case .refreshUsage:
            await refreshUsage()
        case .toggleCollapse:
            toggleAllAccountsCollapsed()
        }
    }
}
