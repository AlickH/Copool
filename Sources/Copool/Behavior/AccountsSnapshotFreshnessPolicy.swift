import Foundation

struct AccountsSnapshotFreshnessPolicy: Sendable {
    let remoteSnapshotFreshnessWindowSeconds: Int64

    init(remoteSnapshotFreshnessWindowSeconds: Int64 = 30) {
        self.remoteSnapshotFreshnessWindowSeconds = remoteSnapshotFreshnessWindowSeconds
    }

    func isRemoteSnapshotFresh(
        remoteSyncedAt: Int64?,
        now: Int64
    ) -> Bool {
        guard let remoteSyncedAt else {
            return false
        }
        return now - remoteSyncedAt <= remoteSnapshotFreshnessWindowSeconds
    }

    func shouldRefreshUsage(
        forceRefresh: Bool,
        remoteSyncedAt: Int64?,
        now: Int64
    ) -> Bool {
        if forceRefresh {
            return true
        }

        guard let remoteSyncedAt else {
            return true
        }

        return !isRemoteSnapshotFresh(remoteSyncedAt: remoteSyncedAt, now: now)
    }
}

struct AccountsUsageRefreshPlanningPolicy: Sendable {
    let nonCurrentResetLeadTimeSeconds: Int64
    let fullRefreshTickInterval: Int

    init(nonCurrentResetLeadTimeSeconds: Int64 = 60, fullRefreshTickInterval: Int = 6) {
        self.nonCurrentResetLeadTimeSeconds = nonCurrentResetLeadTimeSeconds
        self.fullRefreshTickInterval = fullRefreshTickInterval
    }

    func targetAccountIDs(
        from accounts: [AccountSummary],
        now: Int64
    ) -> [String] {
        var selectedIDs: [String] = []

        if let currentAccount = accounts.first(where: \.isCurrent) {
            selectedIDs.append(currentAccount.id)
        }

        for account in accounts where !account.isCurrent {
            guard shouldRefreshNonCurrentAccount(account, now: now) else { continue }
            selectedIDs.append(account.id)
        }

        var deduped: [String] = []
        for id in selectedIDs where !deduped.contains(id) {
            deduped.append(id)
        }
        return deduped
    }

    func targetAccountIDsForRecurringTick(
        _ tick: Int,
        from accounts: [AccountSummary]
    ) -> [String]? {
        if tick % fullRefreshTickInterval == 0 {
            return nil
        }

        guard let currentAccount = accounts.first(where: \.isCurrent) else {
            return []
        }
        return [currentAccount.id]
    }

    private func shouldRefreshNonCurrentAccount(
        _ account: AccountSummary,
        now: Int64
    ) -> Bool {
        if let usageError = account.usageError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !usageError.isEmpty {
            return true
        }

        guard let usage = account.usage else { return false }
        return usage.windows.contains { window in
            guard let resetAt = window.resetAt else { return false }
            let delta = resetAt - now
            return delta >= -nonCurrentResetLeadTimeSeconds && delta <= nonCurrentResetLeadTimeSeconds
        }
    }
}

private extension UsageSnapshot {
    var windows: [UsageWindow] {
        [fiveHour, oneWeek].compactMap { $0 }
    }
}
