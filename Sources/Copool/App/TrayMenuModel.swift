import Foundation
import Combine

extension Notification.Name {
    static let copoolAccountsSnapshotPushDidArrive = Notification.Name("copool.accounts-snapshot.push")
    static let copoolCurrentAccountSelectionPushDidArrive = Notification.Name("copool.current-account-selection.push")
    static let copoolProxyControlPushDidArrive = Notification.Name("copool.proxy-control.push")
    static let copoolLocalProxySnapshotDidUpdate = Notification.Name("copool.proxy.snapshot.local-update")
}

enum ProxyControlNotificationPayloadKey {
    static let snapshot = "snapshot"
}

@MainActor
final class TrayMenuModel: ObservableObject, AccountsManualRefreshServiceProtocol, AccountsLocalMutationSyncServiceProtocol {
    struct BackgroundRefreshPolicy: Sendable {
        let initialRefreshDelay: Duration
        let cloudReconciliationInterval: Duration
        let usageRefreshInterval: Duration
        let refreshUsageOnRecurringTick: Bool
        let cloudSyncMode: AccountsCloudSyncMode
        let applyRemoteSelectionSwitchEffects: Bool

        init(
            initialRefreshDelay: Duration,
            cloudReconciliationInterval: Duration,
            usageRefreshInterval: Duration,
            refreshUsageOnRecurringTick: Bool,
            cloudSyncMode: AccountsCloudSyncMode,
            applyRemoteSelectionSwitchEffects: Bool
        ) {
            self.initialRefreshDelay = initialRefreshDelay
            self.cloudReconciliationInterval = cloudReconciliationInterval
            self.usageRefreshInterval = usageRefreshInterval
            self.refreshUsageOnRecurringTick = refreshUsageOnRecurringTick
            self.cloudSyncMode = cloudSyncMode
            self.applyRemoteSelectionSwitchEffects = applyRemoteSelectionSwitchEffects
        }

        static func forPlatform(_ platform: RuntimePlatform) -> BackgroundRefreshPolicy {
            switch platform {
            case .macOS:
                return BackgroundRefreshPolicy(
                    initialRefreshDelay: .milliseconds(700),
                    cloudReconciliationInterval: .seconds(3),
                    usageRefreshInterval: .seconds(30),
                    refreshUsageOnRecurringTick: true,
                    cloudSyncMode: .pushLocalAccounts,
                    applyRemoteSelectionSwitchEffects: true
                )
            case .iOS:
                return BackgroundRefreshPolicy(
                    initialRefreshDelay: .milliseconds(700),
                    cloudReconciliationInterval: .seconds(3),
                    usageRefreshInterval: .seconds(30),
                    refreshUsageOnRecurringTick: true,
                    cloudSyncMode: .pullRemoteAccounts,
                    applyRemoteSelectionSwitchEffects: true
                )
            }
        }
    }

    let accountsCoordinator: AccountsCoordinator
    let settingsCoordinator: SettingsCoordinator
    let cloudSyncService: AccountsCloudSyncServiceProtocol?
    let currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol?
    let remoteAccountsMutationSyncService: RemoteAccountsMutationSyncServiceProtocol?
    let backgroundRefreshPolicy: BackgroundRefreshPolicy
    let dateProvider: DateProviding
    let snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy
    let usageRefreshPlanningPolicy: AccountsUsageRefreshPlanningPolicy
    var cloudReconciliationTask: Task<Void, Never>?
    var usageRefreshTask: Task<Void, Never>?
    var workspaceMetadataRefreshTask: Task<Void, Never>?
    var accountsSnapshotPushCancellable: AnyCancellable?
    var currentSelectionPushCancellable: AnyCancellable?
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
        cloudSyncService: AccountsCloudSyncServiceProtocol?,
        currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol?,
        remoteAccountsMutationSyncService: RemoteAccountsMutationSyncServiceProtocol? = nil,
        backgroundRefreshPolicy: BackgroundRefreshPolicy,
        dateProvider: DateProviding = SystemDateProvider(),
        snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy = AccountsSnapshotFreshnessPolicy(),
        usageRefreshPlanningPolicy: AccountsUsageRefreshPlanningPolicy = AccountsUsageRefreshPlanningPolicy(),
        initialAccounts: [AccountSummary] = []
    ) {
        self.accountsCoordinator = accountsCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.cloudSyncService = cloudSyncService
        self.currentAccountSelectionSyncService = currentAccountSelectionSyncService
        self.remoteAccountsMutationSyncService = remoteAccountsMutationSyncService
        self.backgroundRefreshPolicy = backgroundRefreshPolicy
        self.dateProvider = dateProvider
        self.snapshotFreshnessPolicy = snapshotFreshnessPolicy
        self.usageRefreshPlanningPolicy = usageRefreshPlanningPolicy
        self.accounts = initialAccounts
    }

    deinit {
        cloudReconciliationTask?.cancel()
        usageRefreshTask?.cancel()
        workspaceMetadataRefreshTask?.cancel()
    }

    func acceptLocalAccountsSnapshot(_ accounts: [AccountSummary]) {
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
