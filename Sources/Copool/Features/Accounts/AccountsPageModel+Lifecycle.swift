import Foundation

extension AccountsPageModel {
    func toggleUsageProgressDisplay() async {
        guard let settingsCoordinator else { return }

        let nextMode: UsageProgressDisplayMode = usageProgressDisplayMode == .used ? .remaining : .used

        do {
            let settings = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(usageProgressDisplayMode: nextMode)
            )
            applySettings(settings)
            onSettingsUpdated?(settings)
            notice = NoticeMessage(
                style: .info,
                text: L10n.tr(
                    "accounts.notice.usage_progress_display_changed_format",
                    L10n.tr(settings.usageProgressDisplayMode.localizationKey)
                )
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func applySettings(_ settings: AppSettings) {
        usageProgressDisplayMode = settings.usageProgressDisplayMode
    }

    func loadIfNeeded() async {
        guard !hasLoaded else {
            await reloadFromLocalStoreAfterExternalMutation()
            return
        }
        await load()
    }

    func load() async {
        do {
            let accounts = try await coordinator.listAccounts()
            await applyReloadedAccounts(accounts)

            hasLoaded = true
        } catch {
            state = .error(message: error.localizedDescription)
            hasLoaded = true
        }
    }

    func reloadFromLocalStoreAfterExternalMutation() async {
        do {
            let accounts = try await coordinator.listAccounts(refreshWorkspaceMetadata: false)
            AccountSwitchDebugLog.write(
                "accountsPage.reloadFromLocalStore",
                "reloaded=\(AccountSwitchDebugLog.describe(accounts: accounts))"
            )
            await applyReloadedAccounts(accounts)
        } catch {}
    }

    /// Applies account snapshots produced by the global background refresh pipeline.
    /// This keeps the Accounts page in sync without creating a duplicate timer.
    func syncFromBackgroundRefresh(_ accounts: [AccountSummary]) {
        applyAccounts(accounts)
    }

    func syncRemoteUsageRefreshActivity(refreshingAccountIDs: Set<String>) {
        if remoteUsageRefreshingAccountIDs != refreshingAccountIDs {
            remoteUsageRefreshingAccountIDs = refreshingAccountIDs
        }

        let isRefreshing = !refreshingAccountIDs.isEmpty
        guard isRemoteUsageRefreshing != isRefreshing else { return }
        isRemoteUsageRefreshing = isRefreshing
    }

    private func applyReloadedAccounts(_ accounts: [AccountSummary]) async {
        applyAccounts(accounts)
        await refreshPendingWorkspaceAuthorizations(from: accounts)
    }
}
