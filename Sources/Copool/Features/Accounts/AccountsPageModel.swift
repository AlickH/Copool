import Foundation
import Combine

@MainActor
final class AccountsPageModel: ObservableObject {
    private let coordinator: AccountsCoordinator
    private let manualRefreshService: AccountsManualRefreshServiceProtocol?
    private let currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol?
    private let cloudSyncAvailabilityService: CloudSyncAvailabilityServiceProtocol?
    private let onLocalAccountsChanged: (([AccountSummary]) -> Void)?
    private let noticeScheduler = NoticeAutoDismissScheduler()
    private var hasLoaded = false
    private var isCloudSyncAvailable = true

    @Published var state: ViewState<[AccountSummary]>
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }
    @Published var isRefreshing = false
    @Published var isImporting = false
    @Published var isAdding = false
    @Published var switchingAccountID: String?
    @Published private(set) var collapsedAccountIDs: Set<String> = []

    init(
        coordinator: AccountsCoordinator,
        manualRefreshService: AccountsManualRefreshServiceProtocol? = nil,
        currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol? = nil,
        cloudSyncAvailabilityService: CloudSyncAvailabilityServiceProtocol? = nil,
        onLocalAccountsChanged: (([AccountSummary]) -> Void)? = nil,
        initialAccounts: [AccountSummary]? = nil
    ) {
        self.coordinator = coordinator
        self.manualRefreshService = manualRefreshService
        self.currentAccountSelectionSyncService = currentAccountSelectionSyncService
        self.cloudSyncAvailabilityService = cloudSyncAvailabilityService
        self.onLocalAccountsChanged = onLocalAccountsChanged
        self.state = initialAccounts.map { initialAccounts in
            Self.makeViewState(accounts: initialAccounts, cloudSyncAvailable: true)
        } ?? .loading
    }

    func loadIfNeeded() async {
        if !hasLoaded {
            await load()
        }
    }

    func load() async {
        async let cloudSyncAvailableTask = cloudSyncAvailabilityService?.isICloudAvailable() ?? true
        do {
            isCloudSyncAvailable = await cloudSyncAvailableTask
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            hasLoaded = true
        } catch {
            state = .error(message: error.localizedDescription)
            hasLoaded = true
        }
    }

    func importCurrentAuth() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let imported = try await coordinator.importCurrentAuthAccount(customLabel: nil)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            notice = NoticeMessage(style: .success, text: L10n.tr("accounts.notice.imported_format", imported.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func addAccountViaLogin() async {
        isAdding = true
        defer { isAdding = false }

        do {
            let imported = try await coordinator.addAccountViaLogin(customLabel: nil)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            notice = NoticeMessage(style: .success, text: L10n.tr("accounts.notice.imported_new_format", imported.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func importAuthDocument(from url: URL, setAsCurrent: Bool) async {
        if setAsCurrent {
            isImporting = true
        } else {
            isAdding = true
        }
        defer {
            if setAsCurrent {
                isImporting = false
            } else {
                isAdding = false
            }
        }

        do {
            let imported = try await coordinator.importAccountFile(
                from: url,
                customLabel: nil,
                setAsCurrent: setAsCurrent
            )
            if setAsCurrent {
                syncCurrentAccountSelectionInBackground(accountID: imported.accountID)
            }
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            let key = setAsCurrent
                ? "accounts.notice.imported_format"
                : "accounts.notice.imported_new_format"
            notice = NoticeMessage(style: .success, text: L10n.tr(key, imported.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func reportImportSelectionFailure(_ error: Error) {
        notice = NoticeMessage(style: .error, text: error.localizedDescription)
    }

    func refreshUsage() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let accounts: [AccountSummary]
            if let manualRefreshService {
                accounts = try await manualRefreshService.performManualRefresh()
            } else {
                accounts = try await coordinator.refreshAllUsage(force: true)
            }
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            let noticeKey = manualRefreshService == nil
                ? "accounts.notice.usage_refreshed"
                : "accounts.notice.accounts_refreshed"
            notice = NoticeMessage(style: .info, text: L10n.tr(noticeKey))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func deleteAccount(id: String) async {
        do {
            try await coordinator.deleteAccount(id: id)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.account_deleted"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func saveTeamAlias(id: String, alias: String?) async {
        do {
            _ = try await coordinator.updateTeamAlias(id: id, alias: alias)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            notice = NoticeMessage(style: .success, text: L10n.tr("accounts.notice.team_name_updated"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func switchAccount(id: String) async {
        switchingAccountID = id
        defer { switchingAccountID = nil }

        do {
            let execution = try await coordinator.switchAccountAndApplySettings(id: id)
            let accounts = try await coordinator.listAccounts()
            guard let selectedAccount = accounts.first(where: { $0.id == id }) else {
                throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
            }
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            syncCurrentAccountSelectionInBackground(accountID: selectedAccount.accountID)
            notice = buildSwitchNotice(execution: execution)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func smartSwitch() async {
        do {
            let accountsBefore = try await coordinator.listAccounts()
            let sorted = AccountRanking.sortByRemaining(accountsBefore)
            guard let best = sorted.first else {
                notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.no_switch_target"))
                return
            }
            if best.isCurrent {
                notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.already_best"))
                return
            }

            let execution = try await coordinator.switchAccountAndApplySettings(id: best.id)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            syncCurrentAccountSelectionInBackground(accountID: best.accountID)
            var switchNotice = buildSwitchNotice(execution: execution)
            switchNotice.text = L10n.tr("accounts.notice.smart_switched_prefix_format", best.label, switchNotice.text)
            notice = switchNotice
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func isAccountCollapsed(_ id: String) -> Bool {
        collapsedAccountIDs.contains(id)
    }

    var areAllAccountsCollapsed: Bool {
        guard case .content(let accounts) = state else { return false }
        let ids = Set(accounts.map(\.id))
        guard !ids.isEmpty else { return false }
        return collapsedAccountIDs.isSuperset(of: ids)
    }

    var canImportCurrentAuthAction: Bool {
        !isImporting && !isAdding
    }

    var canAddAccountAction: Bool {
        !isImporting && !isAdding
    }

    var canSmartSwitchAction: Bool {
        !isImporting && !isAdding && switchingAccountID == nil
    }

    var canRefreshUsageAction: Bool {
        !isRefreshing && !isAdding
    }

    func toggleAllAccountsCollapsed() {
        guard case .content(let accounts) = state else { return }
        let ids = Set(accounts.map(\.id))
        guard !ids.isEmpty else {
            collapsedAccountIDs = []
            return
        }
        collapsedAccountIDs = collapsedAccountIDs.isSuperset(of: ids) ? [] : ids
    }

    var hasResolvedInitialState: Bool {
        if case .loading = state {
            return false
        }
        return true
    }

    /// Applies account snapshots produced by the global background refresh pipeline.
    /// This keeps the Accounts page in sync without creating a duplicate timer.
    func syncFromBackgroundRefresh(_ accounts: [AccountSummary]) {
        applyAccounts(accounts)
    }

    static func makeViewState(
        accounts: [AccountSummary],
        cloudSyncAvailable: Bool
    ) -> ViewState<[AccountSummary]> {
        let sorted = AccountRanking.sortByRemaining(accounts)
        if sorted.isEmpty {
            let messageKey = cloudSyncAvailable
                ? "accounts.empty.message.no_accounts"
                : "accounts.empty.message.enable_icloud"
            return .empty(message: L10n.tr(messageKey))
        }
        return .content(sorted)
    }

    private func buildSwitchNotice(execution: SwitchAccountExecutionResult) -> NoticeMessage {
        var style: NoticeStyle = .success
        var segments: [String] = []

        if execution.usedFallbackCLI {
            style = .info
            segments.append(L10n.tr("accounts.notice.switch_done_fallback"))
        } else {
            segments.append(L10n.tr("accounts.notice.switch_done"))
        }

        if let syncError = execution.opencodeSyncError, !syncError.isEmpty {
            style = .error
            segments.append(L10n.tr("accounts.notice.sync_failed_format", syncError))
        } else if execution.opencodeSynced {
            segments.append(L10n.tr("accounts.notice.sync_done"))
        }

        if let restartError = execution.editorRestartError, !restartError.isEmpty {
            style = .error
            segments.append(L10n.tr("accounts.notice.editor_restart_failed_format", restartError))
        } else if !execution.restartedEditorApps.isEmpty {
            let names = execution.restartedEditorApps.map(\.rawValue).joined(separator: " / ")
            segments.append(L10n.tr("accounts.notice.editor_restarted_format", names))
        }

        return NoticeMessage(style: style, text: segments.joined(separator: " · "))
    }

    private func applyAccounts(_ accounts: [AccountSummary]) {
        let sorted = AccountRanking.sortByRemaining(accounts)
        let availableIDs = Set(sorted.map(\.id))
        let nextCollapsed = collapsedAccountIDs.intersection(availableIDs)
        if nextCollapsed != collapsedAccountIDs {
            collapsedAccountIDs = nextCollapsed
        }

        let nextState = AccountsPageModel.makeViewState(
            accounts: sorted,
            cloudSyncAvailable: isCloudSyncAvailable
        )
        if state != nextState {
            state = nextState
        }
    }

    private func syncCurrentAccountSelection(accountID: String) async {
        guard let currentAccountSelectionSyncService else { return }
        do {
            try await currentAccountSelectionSyncService.recordLocalSelection(accountID: accountID)
            try await currentAccountSelectionSyncService.pushLocalSelectionIfNeeded()
        } catch {
            #if DEBUG
            print("Current account selection sync skipped:", error.localizedDescription)
            #endif
        }
    }

    private func syncCurrentAccountSelectionInBackground(accountID: String) {
        Task {
            await syncCurrentAccountSelection(accountID: accountID)
        }
    }

    private func publishLocalAccounts(_ accounts: [AccountSummary]) {
        onLocalAccountsChanged?(AccountRanking.sortByRemaining(accounts))
    }
}
