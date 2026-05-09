import Foundation
import Combine

extension Notification.Name {
    static let copoolLocalProxySnapshotDidUpdate = Notification.Name("copool.proxy.snapshot.local-update")
}

enum ProxyControlNotificationPayloadKey {
    static let snapshot = "snapshot"
}

@MainActor
final class TrayMenuModel: ObservableObject, AccountsManualRefreshServiceProtocol, AccountsLocalMutationSyncServiceProtocol {
    struct BackgroundRefreshPolicy: Sendable {
        let initialRefreshDelay: Duration
        let usageRefreshInterval: Duration
        let refreshUsageOnRecurringTick: Bool

        init(
            initialRefreshDelay: Duration,
            usageRefreshInterval: Duration,
            refreshUsageOnRecurringTick: Bool
        ) {
            self.initialRefreshDelay = initialRefreshDelay
            self.usageRefreshInterval = usageRefreshInterval
            self.refreshUsageOnRecurringTick = refreshUsageOnRecurringTick
        }

        static func forPlatform(_ platform: RuntimePlatform) -> BackgroundRefreshPolicy {
            _ = platform
            return BackgroundRefreshPolicy(
                initialRefreshDelay: .milliseconds(700),
                usageRefreshInterval: .seconds(10),
                refreshUsageOnRecurringTick: true
            )
        }
    }

    let accountsCoordinator: AccountsCoordinator
    let settingsCoordinator: SettingsCoordinator
    let remoteAccountsMutationSyncService: RemoteAccountsMutationSyncServiceProtocol?
    let backgroundRefreshPolicy: BackgroundRefreshPolicy
    let dateProvider: DateProviding
    let snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy
    let usageRefreshPlanningPolicy: AccountsUsageRefreshPlanningPolicy
    var usageRefreshTask: Task<Void, Never>?
    var workspaceMetadataRefreshTask: Task<Void, Never>?
    var autoSmartSwitchEnabled = false
    var accountsRefreshActivityCount = 0
    var remoteUsageRefreshActivityCount = 0
    var remoteUsageRefreshActivityCountsByID: [String: Int] = [:]

    @Published var accounts: [AccountSummary] = []
    @Published var notice: String?
    @Published var isRefreshingAccounts = false
    @Published var isFetchingRemoteUsage = false
    @Published var remoteUsageRefreshingAccountIDs: Set<String> = []

    init(
        accountsCoordinator: AccountsCoordinator,
        settingsCoordinator: SettingsCoordinator,
        remoteAccountsMutationSyncService: RemoteAccountsMutationSyncServiceProtocol? = nil,
        backgroundRefreshPolicy: BackgroundRefreshPolicy,
        dateProvider: DateProviding = SystemDateProvider(),
        snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy = AccountsSnapshotFreshnessPolicy(),
        usageRefreshPlanningPolicy: AccountsUsageRefreshPlanningPolicy = AccountsUsageRefreshPlanningPolicy(),
        initialAccounts: [AccountSummary] = []
    ) {
        self.accountsCoordinator = accountsCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.remoteAccountsMutationSyncService = remoteAccountsMutationSyncService
        self.backgroundRefreshPolicy = backgroundRefreshPolicy
        self.dateProvider = dateProvider
        self.snapshotFreshnessPolicy = snapshotFreshnessPolicy
        self.usageRefreshPlanningPolicy = usageRefreshPlanningPolicy
        self.accounts = initialAccounts
    }

    deinit {
        usageRefreshTask?.cancel()
        workspaceMetadataRefreshTask?.cancel()
    }

    func acceptLocalAccountsSnapshot(_ accounts: [AccountSummary]) {
        AccountSwitchDebugLog.write(
            "tray.acceptLocalSnapshot",
            "incoming=\(AccountSwitchDebugLog.describe(accounts: accounts))"
        )
        self.accounts = accounts
    }

    func applySettings(_ settings: AppSettings) {
        autoSmartSwitchEnabled = settings.autoSmartSwitch
    }

    var title: String {
        guard let current = accounts.first(where: { $0.isCurrent }) else {
            return L10n.tr("tray.title.placeholder")
        }

        let five = percent(remainingValue(window: current.usage?.fiveHour))
        let week = percent(remainingValue(window: current.usage?.oneWeek))
        return L10n.tr("tray.title.format", five, week)
    }

    func accountLine(_ account: AccountSummary) -> String {
        let prefix = account.isCurrent ? L10n.tr("tray.account.current_prefix") : ""
        let five = percent(remainingValue(window: account.usage?.fiveHour))
        let week = percent(remainingValue(window: account.usage?.oneWeek))
        return L10n.tr("tray.account.line.format", prefix, account.label, five, week)
    }

    private func remainingValue(window: UsageWindow?) -> Double? {
        guard let window else { return nil }
        return max(0, 100 - window.usedPercent)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

}
