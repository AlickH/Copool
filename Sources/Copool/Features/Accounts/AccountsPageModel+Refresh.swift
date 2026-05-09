import Foundation

extension AccountsPageModel {
    func refreshUsage() async {
        guard !isRefreshing else { return }
        isManualRefreshing = true
        defer { isManualRefreshing = false }

        do {
            if let manualRefreshService {
                _ = try await manualRefreshService.performManualRefresh(onPartialUpdate: { _ in })
            } else {
                _ = try await coordinator.refreshUsage(
                    force: true,
                    onPartialUpdate: { [weak self] accounts in
                        guard let self else { return }
                        await MainActor.run {
                            self.applyAccounts(accounts)
                            self.publishLocalAccounts(accounts)
                        }
                    }
                )
            }
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            await refreshPendingWorkspaceAuthorizations(from: accounts)
            if manualRefreshService == nil {
                publishLocalAccounts(accounts)
            }
            let noticeKey = manualRefreshService == nil
                ? "accounts.notice.usage_refreshed"
                : "accounts.notice.accounts_refreshed"
            notice = NoticeMessage(style: .info, text: L10n.tr(noticeKey))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshUsage(forAccountID id: String) async {
        guard !isRefreshing else { return }
        refreshingAccountIDs.insert(id)
        defer { refreshingAccountIDs.remove(id) }

        do {
            let accounts = try await coordinator.refreshUsage(
                accountIDs: [id],
                force: true,
                onPartialUpdate: { [weak self] accounts in
                    guard let self else { return }
                    await MainActor.run {
                        self.applyAccounts(accounts)
                        self.publishLocalAccounts(accounts)
                    }
                }
            )
            applyAccounts(accounts)
            await refreshPendingWorkspaceAuthorizations(from: accounts)
            publishAndSyncLocalAccountsMutation(accounts)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

}
