import Foundation

extension AccountsPageModel {
    func authorizePendingWorkspace(id: String) async {
        guard runtimePlatform == .macOS else {
            notice = NoticeMessage(style: .error, text: PlatformCapabilities.unsupportedOperationMessage)
            return
        }
        guard !isRefreshing, !isAdding, !isImporting else { return }
        guard let candidate = pendingWorkspaceAuthorizations.first(where: { $0.id == id }) else { return }
        guard candidate.status == .pending else { return }
        guard pendingWorkspaceAuthorizationTask == nil else { return }

        authorizingWorkspaceID = id
        let task = Task { [coordinator] in
            try await coordinator.authorizeWorkspaceViaLogin(
                workspaceID: candidate.workspaceID,
                workspaceName: candidate.workspaceName,
                customLabel: nil
            )
        }
        pendingWorkspaceAuthorizationTask = task
        defer {
            pendingWorkspaceAuthorizationTask = nil
            authorizingWorkspaceID = nil
        }

        do {
            let imported = try await task.value
            removePendingWorkspaceAuthorization(id: id)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            schedulePendingWorkspaceRefresh(from: accounts, preferredSourceAccountID: imported.id)
            notice = NoticeMessage(
                style: .success,
                text: L10n.tr("accounts.notice.workspace_authorized_format", candidate.workspaceName)
            )
        } catch is CancellationError {
            notice = NoticeMessage(style: .error, text: L10n.tr("error.oauth.request_cancelled"))
        } catch {
            if isDeactivatedPendingWorkspaceError(error) {
                markPendingWorkspaceAuthorizationDeactivated(id: id)
                try? await coordinator.updateWorkspaceDirectoryStatus(
                    workspaceID: candidate.workspaceID,
                    workspaceName: candidate.workspaceName,
                    email: candidate.email,
                    planType: candidate.planType,
                    kind: .workspace,
                    status: .deactivated
                )
                applyWorkspaceDirectory((try? await coordinator.listWorkspaceDirectory()) ?? workspaceDirectory)
            }
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func cancelPendingWorkspaceAuthorization() {
        pendingWorkspaceAuthorizationTask?.cancel()
    }

    func deletePendingWorkspace(id: String) async {
        guard runtimePlatform == .macOS else {
            notice = NoticeMessage(style: .error, text: PlatformCapabilities.unsupportedOperationMessage)
            return
        }
        pendingWorkspaceRefreshTask?.cancel()
        if isCurrentDeactivatedAccountPendingCard(id: id) {
            await deleteDeactivatedPendingAccount(id: id)
            return
        }
        guard authorizingWorkspaceID != id else { return }
        guard let candidate = pendingWorkspaceAuthorizations.first(where: { $0.id == id }) else { return }

        let previousWorkspaceDirectory = workspaceDirectory

        removePendingWorkspaceAuthorization(id: id)
        updateWorkspaceDirectoryVisibilityLocally(
            workspaceID: id,
            visibility: .deleted
        )

        do {
            try await coordinator.updateWorkspaceDirectoryVisibility(
                workspaceID: id,
                visibility: .deleted
            )
            notice = NoticeMessage(style: .info, text: L10n.tr("accounts.pending.notice.dismissed"))
        } catch {
            workspaceDirectory = previousWorkspaceDirectory
            restorePendingWorkspaceAuthorization(candidate)
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshPendingWorkspaceAuthorizations(
        from accounts: [AccountSummary],
        preferredSourceAccountID: String? = nil
    ) async {
        guard runtimePlatform == .macOS else {
            pendingWorkspaceAuthorizations = []
            pendingWorkspaceAuthorizationError = nil
            return
        }
        guard !Task.isCancelled else { return }
        do {
            let entries = try await coordinator.syncWorkspaceDirectory()
            guard !Task.isCancelled else { return }
            applyWorkspaceDirectory(entries)
            pendingWorkspaceAuthorizations = pendingWorkspaceCandidates(
                from: entries,
                accounts: accounts
            )
            pendingWorkspaceAuthorizationError = nil
        } catch {
            guard !isPendingWorkspaceRefreshCancellation(error) else { return }
            pendingWorkspaceAuthorizationError = error.localizedDescription
        }
    }

    func schedulePendingWorkspaceRefresh(
        from accounts: [AccountSummary],
        preferredSourceAccountID: String? = nil
    ) {
        pendingWorkspaceRefreshTask?.cancel()
        pendingWorkspaceRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshPendingWorkspaceAuthorizations(
                from: accounts,
                preferredSourceAccountID: preferredSourceAccountID
            )
        }
    }

    func clearPendingWorkspaceAuthorizations() {
        workspaceDirectory = []
        pendingWorkspaceAuthorizations = []
        pendingWorkspaceAuthorizationError = nil
        authorizingWorkspaceID = nil
    }

    private func removePendingWorkspaceAuthorization(id: String) {
        pendingWorkspaceAuthorizations.removeAll { $0.id == id }
        pendingWorkspaceAuthorizationError = nil
    }

    private func markPendingWorkspaceAuthorizationDeactivated(id: String) {
        guard let index = pendingWorkspaceAuthorizations.firstIndex(where: { $0.id == id }) else { return }
        pendingWorkspaceAuthorizations[index].status = .deactivated
        pendingWorkspaceAuthorizationError = nil
    }

    private func restorePendingWorkspaceAuthorization(_ candidate: WorkspaceAuthorizationCandidate) {
        pendingWorkspaceAuthorizations = PendingWorkspaceCardRules.sortedCandidates(
            pendingWorkspaceAuthorizations + [candidate]
        )
        pendingWorkspaceAuthorizationError = nil
    }

    private func updateWorkspaceDirectoryVisibilityLocally(
        workspaceID: String,
        visibility: WorkspaceDirectoryVisibility
    ) {
        let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(workspaceID)
        guard !normalizedWorkspaceID.isEmpty else { return }
        guard let index = workspaceDirectory.firstIndex(where: {
            AccountIdentity.normalizedAccountID($0.workspaceID) == normalizedWorkspaceID
        }) else {
            return
        }
        guard workspaceDirectory[index].visibility != visibility else { return }
        workspaceDirectory[index].visibility = visibility
    }

    private func isPendingWorkspaceRefreshCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return error.localizedDescription.lowercased().contains("cancelled")
    }

    private func isDeactivatedPendingWorkspaceError(_ error: Error) -> Bool {
        guard let appError = error as? AppError else { return false }
        return appError.isWorkspaceDeactivated
    }

    private func isCurrentDeactivatedAccountPendingCard(id: String) -> Bool {
        guard case .content(let accounts) = state else { return false }
        return accounts.contains { $0.id == id && $0.isWorkspaceDeactivated }
    }

    private func pendingWorkspaceCandidates(
        from entries: [WorkspaceDirectoryEntry],
        accounts: [AccountSummary]
    ) -> [WorkspaceAuthorizationCandidate] {
        let authorizedWorkspaceIDs = Set(
            accounts.map { AccountIdentity.normalizedAccountID($0.accountID) }
        )

        let candidates: [WorkspaceAuthorizationCandidate] = entries.compactMap { entry in
            let workspaceID = AccountIdentity.normalizedAccountID(entry.workspaceID)
            guard !workspaceID.isEmpty else { return nil }
            guard entry.kind == .workspace else { return nil }
            guard entry.visibility == .visible else { return nil }
            guard !authorizedWorkspaceIDs.contains(workspaceID) else { return nil }
            guard let workspaceName = WorkspaceDisplayName.normalized(from: entry.workspaceName) else { return nil }

            return WorkspaceAuthorizationCandidate(
                workspaceID: entry.workspaceID,
                workspaceName: workspaceName,
                email: entry.email,
                planType: entry.planType,
                status: entry.status == .deactivated ? .deactivated : .pending
            )
        }
        return PendingWorkspaceCardRules.sortedCandidates(candidates)
    }

    private func deleteDeactivatedPendingAccount(id: String) async {
        guard case .content(let accounts) = state,
              accounts.contains(where: { $0.id == id }) else {
            return
        }

        let remainingAccounts = accounts.filter { $0.id != id }
        applyAccounts(remainingAccounts)

        do {
            _ = try await coordinator.updateAccountDisplayStatus(id: id, status: .deleted)
            let refreshedAccounts = try await coordinator.listAccounts()
            applyAccounts(refreshedAccounts)
            await refreshPendingWorkspaceAuthorizations(from: refreshedAccounts)
            publishAndSyncLocalAccountsMutation(refreshedAccounts)
            notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.account_deleted"))
        } catch {
            applyAccounts(accounts)
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }
}
