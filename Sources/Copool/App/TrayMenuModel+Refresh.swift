import Foundation

struct LocalAccountsRefreshResult {
    let accounts: [AccountSummary]
    let didAutoSwitch: Bool
}

@MainActor
extension TrayMenuModel {
    func refreshNow(forceUsageRefresh: Bool) async {
        guard !isRefreshingAccounts else { return }
        do {
            beginAccountsRefreshActivity()
            defer { endAccountsRefreshActivity() }
            accounts = try await executeRefresh(forceUsageRefresh: forceUsageRefresh)
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary] {
        beginAccountsRefreshActivity()
        defer { endAccountsRefreshActivity() }
        let settings = try await settingsCoordinator.currentSettings()
        applySettings(settings)

        let localRefreshResult = try await refreshLocalAccounts(
            forceUsageRefresh: true,
            prefersSerialUsageRefresh: false,
            bypassUsageThrottle: true,
            targetAccountIDs: nil,
            onPartialUpdate: onPartialUpdate
        )
        let latestAccounts = localRefreshResult.accounts
        AccountSwitchDebugLog.write(
            "tray.performManualRefresh.afterLocalRefresh",
            "didAutoSwitch=\(localRefreshResult.didAutoSwitch) \(AccountSwitchDebugLog.describe(accounts: latestAccounts))"
        )

        accounts = latestAccounts
        scheduleWorkspaceMetadataRefresh(forceRemoteCheck: true)
        notice = nil
        return latestAccounts
    }

    func syncLocalAccountsMutationNow() async {
        if let remoteAccountsMutationSyncService {
            let report = await remoteAccountsMutationSyncService.syncConfiguredRemoteAccounts()
            notice = report.failures.isEmpty ? nil : report.failures.joined(separator: " | ")
        } else {
            notice = nil
        }
    }

    func startBackgroundRefresh() {
        guard usageRefreshTask == nil else { return }
        usageRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard self.backgroundRefreshPolicy.refreshUsageOnRecurringTick else { return }
            try? await Task.sleep(for: self.backgroundRefreshPolicy.initialRefreshDelay)
            var tick = 0
            await self.refreshRecurringUsage(tick: tick)
            while !Task.isCancelled {
                try? await Task.sleep(for: self.backgroundRefreshPolicy.usageRefreshInterval)
                tick += 1
                await self.refreshRecurringUsage(tick: tick)
            }
        }
    }

    func stopBackgroundRefresh() {
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
        workspaceMetadataRefreshTask?.cancel()
        workspaceMetadataRefreshTask = nil
    }

    func executeRefresh(forceUsageRefresh: Bool) async throws -> [AccountSummary] {
        let settings = try await settingsCoordinator.currentSettings()
        applySettings(settings)

        let now = dateProvider.unixSecondsNow()
        let targetAccountIDs = usageRefreshPlanningPolicy.targetAccountIDs(
            from: try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false),
            now: now
        )
        let localRefreshResult = try await refreshLocalAccounts(
            forceUsageRefresh: forceUsageRefresh,
            prefersSerialUsageRefresh: false,
            bypassUsageThrottle: false,
            targetAccountIDs: targetAccountIDs,
            onPartialUpdate: nil
        )
        let latestAccounts = localRefreshResult.accounts
        AccountSwitchDebugLog.write(
            "tray.executeRefresh.afterLocalRefresh",
            "forceUsageRefresh=\(forceUsageRefresh) didAutoSwitch=\(localRefreshResult.didAutoSwitch) \(AccountSwitchDebugLog.describe(accounts: latestAccounts))"
        )
        return latestAccounts
    }

    func refreshLocalAccounts(
        forceUsageRefresh: Bool,
        prefersSerialUsageRefresh: Bool,
        bypassUsageThrottle: Bool,
        targetAccountIDs: [String]?,
        onPartialUpdate: (@MainActor ([AccountSummary]) -> Void)?
    ) async throws -> LocalAccountsRefreshResult {
        let latestAccounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        AccountSwitchDebugLog.write(
            "tray.refreshLocalAccounts.begin",
            "forceUsageRefresh=\(forceUsageRefresh) bypassUsageThrottle=\(bypassUsageThrottle) autoSmartSwitchEnabled=\(autoSmartSwitchEnabled) \(AccountSwitchDebugLog.describe(accounts: latestAccounts))"
        )
        if forceUsageRefresh {
            let resolvedTargetAccountIDs = targetAccountIDs ?? latestAccounts.map(\.id)
            guard !resolvedTargetAccountIDs.isEmpty else {
                return LocalAccountsRefreshResult(accounts: latestAccounts, didAutoSwitch: false)
            }
            beginRemoteUsageRefreshActivity(for: resolvedTargetAccountIDs)
            defer { endRemoteUsageRefreshActivity(for: resolvedTargetAccountIDs) }

            _ = try await accountsCoordinator.refreshUsage(
                accountIDs: resolvedTargetAccountIDs,
                force: bypassUsageThrottle,
                serial: prefersSerialUsageRefresh,
                onPartialUpdate: { accounts in
                    guard let onPartialUpdate else { return }
                    await MainActor.run {
                        onPartialUpdate(accounts)
                    }
                }
            )
            if autoSmartSwitchEnabled,
               let switchResult = try await accountsCoordinator.autoSmartSwitchIfNeeded() {
                AccountSwitchDebugLog.write(
                    "tray.refreshLocalAccounts.autoSwitched",
                    "selected=\(AccountSwitchDebugLog.describe(account: switchResult.selectedAccount)) \(AccountSwitchDebugLog.describe(accounts: switchResult.accounts))"
                )
                return LocalAccountsRefreshResult(accounts: switchResult.accounts, didAutoSwitch: true)
            }
        }
        let refreshedAccounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        AccountSwitchDebugLog.write(
            "tray.refreshLocalAccounts.end",
            "didAutoSwitch=false \(AccountSwitchDebugLog.describe(accounts: refreshedAccounts))"
        )
        return LocalAccountsRefreshResult(
            accounts: refreshedAccounts,
            didAutoSwitch: false
        )
    }

    func refreshRecurringUsage(tick: Int) async {
        guard !isRefreshingAccounts else { return }
        do {
            beginAccountsRefreshActivity()
            defer { endAccountsRefreshActivity() }
            let settings = try await settingsCoordinator.currentSettings()
            applySettings(settings)

            let latestAccounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
            let targetAccountIDs = usageRefreshPlanningPolicy.targetAccountIDsForRecurringTick(
                tick,
                from: latestAccounts
            )
            let localRefreshResult = try await refreshLocalAccounts(
                forceUsageRefresh: true,
                prefersSerialUsageRefresh: false,
                bypassUsageThrottle: false,
                targetAccountIDs: targetAccountIDs,
                onPartialUpdate: nil
            )
            accounts = localRefreshResult.accounts
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func scheduleWorkspaceMetadataRefresh(forceRemoteCheck: Bool) {
        workspaceMetadataRefreshTask?.cancel()
        workspaceMetadataRefreshTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.beginAccountsRefreshActivity()
            }
            defer {
                Task { @MainActor [weak self] in
                    self?.endAccountsRefreshActivity()
                }
            }
            do {
                let latestAccounts = try await self.accountsCoordinator.refreshWorkspaceMetadata(
                    forceRemoteCheck: forceRemoteCheck
                )
                guard !Task.isCancelled else { return }
                self.accounts = latestAccounts
                self.notice = nil
            } catch {}
        }
    }

    func beginAccountsRefreshActivity() {
        accountsRefreshActivityCount += 1
        if !isRefreshingAccounts {
            isRefreshingAccounts = true
        }
    }

    func endAccountsRefreshActivity() {
        accountsRefreshActivityCount = max(0, accountsRefreshActivityCount - 1)
        if accountsRefreshActivityCount == 0, isRefreshingAccounts {
            isRefreshingAccounts = false
        }
    }

    func beginRemoteUsageRefreshActivity(for accountIDs: [String]) {
        remoteUsageRefreshActivityCount += 1
        for accountID in accountIDs {
            remoteUsageRefreshActivityCountsByID[accountID, default: 0] += 1
        }
        remoteUsageRefreshingAccountIDs = Set(remoteUsageRefreshActivityCountsByID.keys)
        if !isFetchingRemoteUsage {
            isFetchingRemoteUsage = true
        }
    }

    func endRemoteUsageRefreshActivity(for accountIDs: [String]) {
        remoteUsageRefreshActivityCount = max(0, remoteUsageRefreshActivityCount - 1)
        for accountID in accountIDs {
            let nextCount = max(0, remoteUsageRefreshActivityCountsByID[accountID, default: 0] - 1)
            if nextCount == 0 {
                remoteUsageRefreshActivityCountsByID.removeValue(forKey: accountID)
            } else {
                remoteUsageRefreshActivityCountsByID[accountID] = nextCount
            }
        }
        remoteUsageRefreshingAccountIDs = Set(remoteUsageRefreshActivityCountsByID.keys)
        if remoteUsageRefreshActivityCount == 0, isFetchingRemoteUsage {
            isFetchingRemoteUsage = false
        }
    }
}
