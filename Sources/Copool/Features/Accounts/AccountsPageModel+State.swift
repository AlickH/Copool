import Foundation

extension AccountsPageModel {
    static func makeViewState(
        accounts: [AccountSummary]
    ) -> ViewState<[AccountSummary]> {
        if accounts.isEmpty {
            return .empty(message: L10n.tr("accounts.empty.message.no_accounts"))
        }
        return .content(accounts)
    }

    func buildSwitchNotice(execution: SwitchAccountExecutionResult) -> NoticeMessage {
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

    func applyAccounts(_ accounts: [AccountSummary]) {
        let displayAccounts = AccountRanking.sortForDisplay(accounts)
        let availableIDs = Set(displayAccounts.filter { !$0.isWorkspaceDeactivated }.map(\.id))
        let nextCollapsed = collapsedAccountIDs.intersection(availableIDs)
        if nextCollapsed != collapsedAccountIDs {
            collapsedAccountIDs = nextCollapsed
        }

        let nextState = AccountsPageModel.makeViewState(accounts: displayAccounts)
        if state != nextState {
            state = nextState
        }
        AccountSwitchDebugLog.write(
            "accountsPage.applyAccounts",
            "applied=\(AccountSwitchDebugLog.describe(accounts: displayAccounts))"
        )
    }

    func applyWorkspaceDirectory(_ entries: [WorkspaceDirectoryEntry]) {
        if workspaceDirectory != entries {
            workspaceDirectory = entries
        }
    }

    func publishLocalAccounts(_ accounts: [AccountSummary]) {
        onLocalAccountsChanged?(AccountRanking.sortForDisplay(accounts))
    }

    func acceptExternalAccountsSnapshot(_ accounts: [AccountSummary]) {
        AccountSwitchDebugLog.write(
            "accountsPage.acceptExternalSnapshot",
            "incoming=\(AccountSwitchDebugLog.describe(accounts: accounts))"
        )
        applyAccounts(accounts)
    }

    func publishAndSyncLocalAccountsMutation(_ accounts: [AccountSummary]) {
        publishLocalAccounts(accounts)
        Task { @MainActor [weak self] in
            await self?.localAccountsMutationSyncService?.syncLocalAccountsMutationNow()
        }
    }

    func debugDisplayedAccounts() -> [AccountSummary] {
        guard case .content(let accounts) = state else { return [] }
        return accounts
    }
}
