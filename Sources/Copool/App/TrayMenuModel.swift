import Foundation
import Combine

extension Notification.Name {
    static let copoolCurrentAccountSelectionPushDidArrive = Notification.Name("copool.current-account-selection.push")
    static let copoolProxyControlPushDidArrive = Notification.Name("copool.proxy-control.push")
}

@MainActor
final class TrayMenuModel: ObservableObject, AccountsManualRefreshServiceProtocol {
    enum CloudSyncMode: Sendable {
        case disabled
        case pushLocalAccounts
        case pullRemoteAccounts
    }

    struct BackgroundRefreshPolicy: Sendable {
        let initialRefreshDelay: Duration
        let selectionRefreshInterval: Duration
        let refreshUsageOnRecurringTick: Bool
        let cloudSyncMode: CloudSyncMode
        let applyRemoteSelectionSwitchEffects: Bool

        static func forPlatform(_ platform: RuntimePlatform) -> BackgroundRefreshPolicy {
            switch platform {
            case .macOS:
                return BackgroundRefreshPolicy(
                    initialRefreshDelay: .milliseconds(700),
                    selectionRefreshInterval: .seconds(5),
                    refreshUsageOnRecurringTick: true,
                    cloudSyncMode: .pushLocalAccounts,
                    applyRemoteSelectionSwitchEffects: true
                )
            case .iOS:
                return BackgroundRefreshPolicy(
                    initialRefreshDelay: .milliseconds(700),
                    selectionRefreshInterval: .seconds(5),
                    refreshUsageOnRecurringTick: true,
                    cloudSyncMode: .pullRemoteAccounts,
                    applyRemoteSelectionSwitchEffects: false
                )
            }
        }
    }

    private let accountsCoordinator: AccountsCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let cloudSyncService: AccountsCloudSyncServiceProtocol?
    private let currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol?
    private let backgroundRefreshPolicy: BackgroundRefreshPolicy
    private var refreshTask: Task<Void, Never>?
    private var selectionRefreshTask: Task<Void, Never>?
    private var currentSelectionPushCancellable: AnyCancellable?
    private var autoSmartSwitchEnabled = false

    @Published var accounts: [AccountSummary] = []
    @Published var notice: String?

    init(
        accountsCoordinator: AccountsCoordinator,
        settingsCoordinator: SettingsCoordinator,
        cloudSyncService: AccountsCloudSyncServiceProtocol?,
        currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol?,
        backgroundRefreshPolicy: BackgroundRefreshPolicy,
        initialAccounts: [AccountSummary] = []
    ) {
        self.accountsCoordinator = accountsCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.cloudSyncService = cloudSyncService
        self.currentAccountSelectionSyncService = currentAccountSelectionSyncService
        self.backgroundRefreshPolicy = backgroundRefreshPolicy
        self.accounts = initialAccounts
    }

    func startBackgroundRefresh() {
        guard refreshTask == nil else { return }
        configureCurrentSelectionPushHandlingIfNeeded()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.backgroundRefreshPolicy.initialRefreshDelay)
            await self.refreshNow(forceUsageRefresh: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.refreshNow(forceUsageRefresh: self.backgroundRefreshPolicy.refreshUsageOnRecurringTick)
            }
        }
        selectionRefreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.backgroundRefreshPolicy.initialRefreshDelay)
            await self.refreshCurrentSelectionNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: self.backgroundRefreshPolicy.selectionRefreshInterval)
                await self.refreshCurrentSelectionNow()
            }
        }
    }

    func stopBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        selectionRefreshTask?.cancel()
        selectionRefreshTask = nil
    }

    deinit {
        refreshTask?.cancel()
        selectionRefreshTask?.cancel()
    }

    func refreshNow(forceUsageRefresh: Bool) async {
        do {
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

    func refreshCurrentSelectionNow() async {
        do {
            let result = try await reconcileCurrentAccountSelection(failOnError: false)
            guard result.didUpdateSelection else { return }
            accounts = try await accountsCoordinator.listAccounts()
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func performManualRefresh() async throws -> [AccountSummary] {
        let settings = try await settingsCoordinator.currentSettings()
        applySettings(settings)

        // On manual refresh, prefer live usage data. Pull remote accounts first on iOS,
        // then refresh usage directly, and finally push the fresh snapshot back to CloudKit.
        if backgroundRefreshPolicy.cloudSyncMode == .pullRemoteAccounts {
            _ = try await performCloudSync(mode: .pullRemoteAccounts, failOnError: false)
            _ = try await reconcileCurrentAccountSelection(failOnError: false)
        }

        let prefersSerialUsageRefresh = backgroundRefreshPolicy.cloudSyncMode == .pullRemoteAccounts
        var latestAccounts = try await refreshLocalAccounts(
            forceUsageRefresh: true,
            prefersSerialUsageRefresh: prefersSerialUsageRefresh,
            bypassUsageThrottle: true
        )

        if backgroundRefreshPolicy.cloudSyncMode != .disabled {
            _ = try await performCloudSync(mode: .pushLocalAccounts, failOnError: false)
            _ = try await reconcileCurrentAccountSelection(failOnError: false)
            latestAccounts = try await accountsCoordinator.listAccounts()
        }

        accounts = latestAccounts
        notice = nil
        return latestAccounts
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

    private func executeRefresh(
        forceUsageRefresh: Bool,
        failOnCloudSyncError: Bool
    ) async throws -> [AccountSummary] {
        let settings = try await settingsCoordinator.currentSettings()
        applySettings(settings)

        let prefersSerialUsageRefresh = backgroundRefreshPolicy.cloudSyncMode == .pullRemoteAccounts
        var latestAccounts = try await refreshLocalAccounts(
            forceUsageRefresh: forceUsageRefresh,
            prefersSerialUsageRefresh: prefersSerialUsageRefresh,
            bypassUsageThrottle: false
        )

        if try await performCloudSync(mode: backgroundRefreshPolicy.cloudSyncMode, failOnError: failOnCloudSyncError) {
            latestAccounts = try await accountsCoordinator.listAccounts()
        }

        if try await reconcileCurrentAccountSelection(
            failOnError: failOnCloudSyncError
        ).didUpdateSelection {
            latestAccounts = try await accountsCoordinator.listAccounts()
        }

        return latestAccounts
    }

    private func refreshLocalAccounts(
        forceUsageRefresh: Bool,
        prefersSerialUsageRefresh: Bool,
        bypassUsageThrottle: Bool
    ) async throws -> [AccountSummary] {
        if forceUsageRefresh {
            if prefersSerialUsageRefresh {
                _ = try await accountsCoordinator.refreshAllUsageSerially(force: bypassUsageThrottle)
            } else {
                _ = try await accountsCoordinator.refreshAllUsage(force: bypassUsageThrottle)
            }
            if autoSmartSwitchEnabled {
                _ = try await accountsCoordinator.autoSmartSwitchIfNeeded()
            }
        }
        return try await accountsCoordinator.listAccounts()
    }

    private func performCloudSync(mode: CloudSyncMode, failOnError: Bool) async throws -> Bool {
        guard let cloudSyncService else { return false }

        do {
            switch mode {
            case .disabled:
                return false
            case .pushLocalAccounts:
                try await cloudSyncService.pushLocalAccountsIfNeeded()
                return false
            case .pullRemoteAccounts:
                return try await cloudSyncService.pullRemoteAccountsIfNeeded()
            }
        } catch {
            if failOnError {
                throw error
            }
            #if DEBUG
            print("CloudKit background sync skipped:", error.localizedDescription)
            #endif
            return false
        }
    }

    private func configureCurrentSelectionPushHandlingIfNeeded() {
        guard backgroundRefreshPolicy.applyRemoteSelectionSwitchEffects else { return }
        guard currentSelectionPushCancellable == nil else { return }

        currentSelectionPushCancellable = NotificationCenter.default
            .publisher(for: .copoolCurrentAccountSelectionPushDidArrive)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleCurrentSelectionPushNotification()
                }
            }

        Task {
            do {
                try await currentAccountSelectionSyncService?.ensurePushSubscriptionIfNeeded()
            } catch {
                #if DEBUG
                print("CloudKit current selection push subscription skipped:", error.localizedDescription)
                #endif
            }
        }
    }

    private func reconcileCurrentAccountSelection(
        failOnError: Bool
    ) async throws -> CurrentAccountSelectionPullResult {
        guard let currentAccountSelectionSyncService else { return .noChange }

        do {
            let pullResult = try await currentAccountSelectionSyncService.pullRemoteSelectionIfNeeded()

            if pullResult.changedCurrentAccount,
               backgroundRefreshPolicy.applyRemoteSelectionSwitchEffects,
               let remoteAccountID = pullResult.accountID {
                try await applyRemoteSelectionSwitchEffects(accountID: remoteAccountID)
                return pullResult
            }

            if !pullResult.didUpdateSelection {
                try await currentAccountSelectionSyncService.pushLocalSelectionIfNeeded()
            }

            return pullResult
        } catch {
            if failOnError {
                throw error
            }
            #if DEBUG
            print("CloudKit current selection sync skipped:", error.localizedDescription)
            #endif
            return .noChange
        }
    }

    private func applyRemoteSelectionSwitchEffects(accountID: String) async throws {
        let accounts = try await accountsCoordinator.listAccounts()
        guard let matchingAccount = accounts.first(where: { $0.accountID == accountID }) else { return }
        _ = try await accountsCoordinator.switchAccountAndApplySettings(id: matchingAccount.id)
    }

    private func handleCurrentSelectionPushNotification() async {
        do {
            let result = try await reconcileCurrentAccountSelection(failOnError: false)
            guard result.didUpdateSelection else { return }
            accounts = try await accountsCoordinator.listAccounts()
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }
}
