import Foundation

@MainActor
extension TrayMenuModel {
    func refreshNow(forceUsageRefresh: Bool) async {
        guard !isRefreshingAccounts else { return }
        do {
            beginAccountsRefreshActivity()
            defer { endAccountsRefreshActivity() }
            let latestAccounts = try await executeRefresh(
                forceUsageRefresh: forceUsageRefresh,
                failOnCloudSyncError: false
            )
            accounts = latestAccounts
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func reconcileCloudStateNow() async {
        do {
            let latestAccounts = try await executeCloudReconciliation(failOnCloudSyncError: false)
            accounts = latestAccounts
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func refreshCurrentSelectionNow() async {
        do {
            let result = try await reconcileCurrentAccountSelection(failOnError: false)
            guard result.didUpdateSelection else { return }
            accounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
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

        _ = try await pullCloudAccountsIfNeeded(failOnError: false)
        _ = try await reconcileCurrentAccountSelection(failOnError: false)
        let prefersSerialUsageRefresh = backgroundRefreshPolicy.cloudSyncMode == .pullRemoteAccounts
        let shouldPushSnapshot = backgroundRefreshPolicy.cloudSyncMode != .disabled
        var latestAccounts = try await refreshLocalAccounts(
            forceUsageRefresh: true,
            prefersSerialUsageRefresh: prefersSerialUsageRefresh,
            bypassUsageThrottle: true,
            targetAccountIDs: nil,
            onPartialUpdate: onPartialUpdate
        )

        if shouldPushSnapshot, !latestAccounts.isEmpty {
            try await pushCloudAccountsIfNeeded(failOnError: false)
        }
        _ = try await reconcileCurrentAccountSelection(failOnError: false)
        latestAccounts = try await accountsCoordinator.listAccounts()

        accounts = latestAccounts
        scheduleWorkspaceMetadataRefresh(forceRemoteCheck: true)
        notice = nil
        return latestAccounts
    }

    func syncLocalAccountsMutationNow() async {
        do {
            try await pushCloudAccountsIfNeeded(failOnError: false)
            if let remoteAccountsMutationSyncService {
                let report = await remoteAccountsMutationSyncService.syncConfiguredRemoteAccounts()
                notice = report.failures.isEmpty ? nil : report.failures.joined(separator: " | ")
            } else {
                notice = nil
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func startBackgroundRefresh() {
        guard cloudReconciliationTask == nil else { return }
        configureAccountsSnapshotPushHandlingIfNeeded()
        configureCurrentSelectionPushHandlingIfNeeded()
        cloudReconciliationTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileCloudStateNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: self.backgroundRefreshPolicy.cloudReconciliationInterval)
                await self.reconcileCloudStateNow()
            }
        }
        usageRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard self.backgroundRefreshPolicy.refreshUsageOnRecurringTick else { return }
            try? await Task.sleep(for: self.backgroundRefreshPolicy.initialRefreshDelay)
            while !Task.isCancelled {
                try? await Task.sleep(for: self.backgroundRefreshPolicy.usageRefreshInterval)
                await self.refreshNow(forceUsageRefresh: true)
            }
        }
    }

    func stopBackgroundRefresh() {
        cloudReconciliationTask?.cancel()
        cloudReconciliationTask = nil
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
        workspaceMetadataRefreshTask?.cancel()
        workspaceMetadataRefreshTask = nil
        accountsSnapshotPushCancellable = nil
        currentSelectionPushCancellable = nil
    }

    func executeRefresh(
        forceUsageRefresh: Bool,
        failOnCloudSyncError: Bool
    ) async throws -> [AccountSummary] {
        let settings = try await settingsCoordinator.currentSettings()
        applySettings(settings)

        let cloudPullResult = try await pullCloudAccountsIfNeeded(failOnError: failOnCloudSyncError)
        _ = try await reconcileCurrentAccountSelection(failOnError: failOnCloudSyncError)
        let prefersSerialUsageRefresh = backgroundRefreshPolicy.cloudSyncMode == .pullRemoteAccounts
        let now = dateProvider.unixSecondsNow()
        let shouldRefreshUsage: Bool
        if backgroundRefreshPolicy.cloudSyncMode == .pushLocalAccounts {
            shouldRefreshUsage = forceUsageRefresh
        } else {
            shouldRefreshUsage = snapshotFreshnessPolicy.shouldRefreshUsage(
                forceRefresh: forceUsageRefresh,
                remoteSyncedAt: cloudPullResult.remoteSyncedAt,
                now: now
            )
        }
        let targetAccountIDs = usageRefreshPlanningPolicy.targetAccountIDs(
            from: try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false),
            now: now
        )
        var latestAccounts = try await refreshLocalAccounts(
            forceUsageRefresh: shouldRefreshUsage,
            prefersSerialUsageRefresh: prefersSerialUsageRefresh,
            bypassUsageThrottle: false,
            targetAccountIDs: targetAccountIDs,
            onPartialUpdate: nil
        )

        if cloudPullResult.didUpdateAccounts {
            latestAccounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        }

        if shouldRefreshUsage,
           backgroundRefreshPolicy.cloudSyncMode != .disabled,
           !targetAccountIDs.isEmpty {
            try await pushCloudAccountsIfNeeded(failOnError: failOnCloudSyncError)
        }

        if try await reconcileCurrentAccountSelection(
            failOnError: failOnCloudSyncError
        ).didUpdateSelection {
            latestAccounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        }

        return latestAccounts
    }

    func executeCloudReconciliation(
        failOnCloudSyncError: Bool
    ) async throws -> [AccountSummary] {
        let cloudPullResult = try await pullCloudAccountsIfNeeded(failOnError: failOnCloudSyncError)
        let selectionPullResult = try await reconcileCurrentAccountSelection(
            failOnError: failOnCloudSyncError
        )
        let latestLocalAccounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)

        if backgroundRefreshPolicy.cloudSyncMode == .pushLocalAccounts,
           !latestLocalAccounts.isEmpty,
           !cloudPullResult.didUpdateAccounts {
            try await pushCloudAccountsIfNeeded(failOnError: failOnCloudSyncError)
        }

        if cloudPullResult.didUpdateAccounts || selectionPullResult.didUpdateSelection {
            return try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        }

        return latestLocalAccounts
    }

    func refreshLocalAccounts(
        forceUsageRefresh: Bool,
        prefersSerialUsageRefresh: Bool,
        bypassUsageThrottle: Bool,
        targetAccountIDs: [String]?,
        onPartialUpdate: (@MainActor ([AccountSummary]) -> Void)?
    ) async throws -> [AccountSummary] {
        let latestAccounts = try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        if forceUsageRefresh {
            let resolvedTargetAccountIDs = targetAccountIDs ?? latestAccounts.map(\.id)
            guard !resolvedTargetAccountIDs.isEmpty else {
                return latestAccounts
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
               let (selectedAccount, _) = try await accountsCoordinator.autoSmartSwitchIfNeeded() {
                await syncCurrentAccountSelectionIfNeeded(accountID: selectedAccount.accountID)
            }
        }
        return try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
    }

    func pullCloudAccountsIfNeeded(
        failOnError: Bool
    ) async throws -> AccountsCloudSyncPullResult {
        guard let cloudSyncService else { return .noChange }

        do {
            let now = dateProvider.unixSecondsNow()
            return try await cloudSyncService.pullRemoteAccountsIfNeeded(
                currentTime: now,
                maximumSnapshotAgeSeconds: snapshotFreshnessPolicy.remoteSnapshotFreshnessWindowSeconds
            )
        } catch {
            if failOnError {
                throw error
            }
            return .noChange
        }
    }

    func pushCloudAccountsIfNeeded(failOnError: Bool) async throws {
        guard let cloudSyncService else { return }

        do {
            try await cloudSyncService.pushLocalAccountsIfNeeded()
        } catch {
            if failOnError {
                throw error
            }
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
                if self.backgroundRefreshPolicy.cloudSyncMode == .pushLocalAccounts {
                    try await self.pushCloudAccountsIfNeeded(failOnError: false)
                }
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

    private func syncCurrentAccountSelectionIfNeeded(accountID: String) async {
        guard let currentAccountSelectionSyncService else { return }

        do {
            try await currentAccountSelectionSyncService.recordLocalSelection(accountID: accountID)
            try await currentAccountSelectionSyncService.pushLocalSelectionIfNeeded()
        } catch {}
    }
}
