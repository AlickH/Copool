import Foundation

extension AccountsPageModel {
    func refreshUsage() async {
        if runtimePlatform == .iOS {
            await requestRemoteAccountsRefresh()
            return
        }
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
        guard runtimePlatform == .macOS else {
            notice = NoticeMessage(style: .error, text: PlatformCapabilities.unsupportedOperationMessage)
            return
        }
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

    private func requestRemoteAccountsRefresh() async {
        guard let proxyControlCloudSyncService else {
            notice = NoticeMessage(style: .error, text: PlatformCapabilities.unsupportedOperationMessage)
            return
        }
        guard !isRefreshing else { return }

        isManualRefreshing = true
        defer { isManualRefreshing = false }

        let command = ProxyControlCommand(
            id: UUID().uuidString,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
            sourceDeviceID: "ios-accounts",
            kind: .refreshAccounts,
            preferredProxyPort: nil,
            autoStartProxy: nil,
            cloudflaredInput: nil,
            remoteServer: nil,
            remoteServerID: nil,
            logLines: nil
        )

        do {
            try await proxyControlCloudSyncService.enqueueCommand(command)
            notice = NoticeMessage(
                style: .info,
                text: L10n.tr("accounts.notice.remote_refresh_requested")
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }
}
