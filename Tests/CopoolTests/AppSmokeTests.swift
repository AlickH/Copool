import XCTest
import Combine
@testable import Copool

@MainActor
final class AppSmokeTests: XCTestCase {
    func testAccountsPageLoadSwitchAndSettingsFlow() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = SmokeAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-current",
                        label: "Current",
                        email: "current@example.com",
                        accountID: "account-current",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["id_token": .string("current-token")]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeSmokeUsageSnapshot(fetchedAt: now),
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-next",
                        label: "Next",
                        email: "next@example.com",
                        accountID: "account-next",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["id_token": .string("next-token")]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeSmokeUsageSnapshot(fetchedAt: now),
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-current",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "smoke-device",
                    accountKey: "account-current"
                )
            )
        )
        let settingsRepository = TestSettingsRepository()
        let authRepository = SmokeAuthRepository(currentAccountKey: "account-current")
        let accountsCoordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: settingsRepository,
            authRepository: authRepository,
            usageService: SmokeUsageService(snapshot: makeSmokeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: SmokeChatLoginService(),
            codexCLIService: SmokeCodexCLIService(),
            editorAppService: SmokeEditorAppService(),
            opencodeAuthSyncService: SmokeOpencodeAuthSyncService(),
            dateProvider: SmokeDateProvider(now: now)
        )
        let settingsCoordinator = SettingsCoordinator(
            settingsRepository: settingsRepository,
            launchAtStartupService: SmokeLaunchAtStartupService()
        )
        let accountsModel = AccountsPageModel(
            coordinator: accountsCoordinator,
            currentAccountSelectionSyncService: SmokeCurrentAccountSelectionSyncService(),
            cloudSyncAvailabilityService: CloudSyncAvailabilityService()
        )
        let settingsModel = SettingsPageModel(
            settingsCoordinator: settingsCoordinator,
            editorAppService: SmokeEditorAppService()
        )

        await accountsModel.loadIfNeeded()
        guard case .content(let loadedAccounts) = accountsModel.state else {
            return XCTFail("Expected loaded accounts content state")
        }
        XCTAssertEqual(loadedAccounts.map(\.label), ["Current", "Next"])
        XCTAssertEqual(loadedAccounts.first(where: \.isCurrent)?.id, "acct-current")

        await accountsModel.switchAccount(id: "acct-next")
        guard case .content(let switchedAccounts) = accountsModel.state else {
            return XCTFail("Expected switched accounts content state")
        }
        XCTAssertEqual(switchedAccounts.first(where: \.isCurrent)?.id, "acct-next")
        XCTAssertEqual(authRepository.currentAccountKey, "account-next")

        settingsModel.settings = try await settingsCoordinator.currentSettings()
        settingsModel.setAutoStartProxy(true)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(settingsModel.settings.autoStartApiProxy)
        XCTAssertEqual(try settingsRepository.loadSettings().autoStartApiProxy, true)
    }

    func testProxyPageStartAndStopFlow() async {
        let localCommandService = SmokeProxyLocalCommandService()
        let settingsCoordinator = SettingsCoordinator(
            settingsRepository: TestSettingsRepository(),
            launchAtStartupService: SmokeLaunchAtStartupService()
        )
        let model = ProxyPageModel(
            coordinator: ProxyCoordinator(
                proxyService: SmokeProxyRuntimeService(),
                cloudflaredService: SmokeCloudflaredService(),
                remoteService: SmokeRemoteProxyService()
            ),
            settingsCoordinator: settingsCoordinator,
            localProxyCommandService: localCommandService,
            runtimePlatform: .macOS
        )

        await model.startProxy()
        XCTAssertTrue(model.proxyStatus.running)
        let commandsAfterStart = await localCommandService.readCommands()
        XCTAssertEqual(commandsAfterStart, [.startProxy])

        await model.stopProxy()
        XCTAssertFalse(model.proxyStatus.running)
        let commandsAfterStop = await localCommandService.readCommands()
        XCTAssertEqual(commandsAfterStop, [.startProxy, .stopProxy])
    }

    func testTrayAutoSmartSwitchUpdatesAccountsPageCurrentState() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = SmokeAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-current",
                        label: "Current",
                        email: "current@example.com",
                        accountID: "account-current",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["id_token": .string("current-token")]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-next",
                        label: "Next",
                        email: "next@example.com",
                        accountID: "account-next",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["id_token": .string("next-token")]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-current",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "smoke-device",
                    accountKey: "account-current"
                )
            )
        )
        var settings = AppSettings.defaultValue
        settings.autoSmartSwitch = true
        settings.launchCodexAfterSwitch = false
        let settingsRepository = TestSettingsRepository(settings: settings)
        let authRepository = SmokeAuthRepository(currentAccountKey: "account-current")
        let accountsCoordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: settingsRepository,
            authRepository: authRepository,
            usageService: SmokeMappedUsageService(
                snapshotsByAccountID: [
                    "account-current": UsageSnapshot(
                        fetchedAt: now,
                        planType: "pro",
                        fiveHour: UsageWindow(usedPercent: 99, windowSeconds: 18_000, resetAt: nil),
                        oneWeek: UsageWindow(usedPercent: 95, windowSeconds: 604_800, resetAt: nil),
                        credits: nil
                    ),
                    "account-next": UsageSnapshot(
                        fetchedAt: now,
                        planType: "pro",
                        fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                        oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
                        credits: nil
                    )
                ]
            ),
            chatGPTOAuthLoginService: SmokeChatLoginService(),
            codexCLIService: SmokeCodexCLIService(),
            editorAppService: SmokeEditorAppService(),
            opencodeAuthSyncService: SmokeOpencodeAuthSyncService(),
            dateProvider: SmokeDateProvider(now: now)
        )
        let settingsCoordinator = SettingsCoordinator(
            settingsRepository: settingsRepository,
            launchAtStartupService: SmokeLaunchAtStartupService()
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: accountsCoordinator,
            settingsCoordinator: settingsCoordinator,
            cloudSyncService: nil,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: SmokeDateProvider(now: now),
            initialAccounts: try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        )
        trayModel.autoSmartSwitchEnabled = true
        let accountsModel = AccountsPageModel(
            coordinator: accountsCoordinator,
            manualRefreshService: trayModel,
            localAccountsMutationSyncService: trayModel,
            currentAccountSelectionSyncService: SmokeCurrentAccountSelectionSyncService(),
            cloudSyncAvailabilityService: CloudSyncAvailabilityService(),
            onLocalAccountsChanged: { accounts in
                trayModel.acceptLocalAccountsSnapshot(accounts)
            },
            initialAccounts: try await accountsCoordinator.listAccounts(refreshWorkspaceMetadata: false)
        )
        let accountsSyncCancellable = trayModel.$accounts
            .removeDuplicates()
            .sink { accounts in
                accountsModel.acceptExternalAccountsSnapshot(accounts)
            }
        defer { _ = accountsSyncCancellable }

        await accountsModel.loadIfNeeded()
        let latestAccounts = try await trayModel.refreshLocalAccounts(
            forceUsageRefresh: true,
            prefersSerialUsageRefresh: false,
            bypassUsageThrottle: true,
            targetAccountIDs: nil,
            onPartialUpdate: nil
        )
        trayModel.acceptLocalAccountsSnapshot(latestAccounts)

        XCTAssertEqual(authRepository.currentAccountKey, "account-next")
        guard case .content(let accounts) = accountsModel.state else {
            return XCTFail("Expected accounts page content state")
        }
        XCTAssertEqual(accounts.first(where: \.isCurrent)?.id, "acct-next")
    }
}

private func makeSmokeUsageSnapshot(fetchedAt: Int64) -> UsageSnapshot {
    UsageSnapshot(
        fetchedAt: fetchedAt,
        planType: "pro",
        fiveHour: nil,
        oneWeek: nil,
        credits: nil
    )
}

private final class SmokeAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var store: AccountsStore

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    func saveStore(_ store: AccountsStore) throws {
        lock.lock()
        self.store = store
        lock.unlock()
    }
}

private final class SmokeAuthRepository: AuthRepository, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var currentAccountKey: String?
    private var currentAuth: JSONValue

    init(currentAccountKey: String?) {
        self.currentAccountKey = currentAccountKey
        self.currentAuth = .object(["id_token": .string("current-token")])
    }

    func readCurrentAuth() throws -> JSONValue { currentAuth }
    func readCurrentAuthOptional() throws -> JSONValue? { currentAuth }

    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return currentAuth
    }

    func writeCurrentAuth(_ auth: JSONValue) throws {
        lock.lock()
        currentAuth = auth
        if case .object(let object) = auth,
           case .string(let token) = object["id_token"] {
            currentAccountKey = token == "next-token" ? "account-next" : "account-current"
        }
        lock.unlock()
    }

    func removeCurrentAuth() throws {
        lock.lock()
        currentAuth = .object([:])
        currentAccountKey = nil
        lock.unlock()
    }

    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        .object([
            "id_token": .string(tokens.idToken),
            "access_token": .string(tokens.accessToken),
            "refresh_token": .string(tokens.refreshToken)
        ])
    }

    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        let token: String
        if case .object(let object) = auth,
           case .string(let idToken) = object["id_token"] {
            token = idToken
        } else {
            token = "current-token"
        }
        let accountID = token == "next-token" ? "account-next" : "account-current"
        return ExtractedAuth(
            accountID: accountID,
            accessToken: "access-token",
            email: accountID == "account-next" ? "next@example.com" : "current@example.com",
            planType: "pro",
            teamName: nil,
            principalID: accountID
        )
    }

}

private struct SmokeUsageService: UsageService {
    let snapshot: UsageSnapshot

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        _ = accountID
        return snapshot
    }
}

private struct SmokeMappedUsageService: UsageService {
    let snapshotsByAccountID: [String: UsageSnapshot]

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        guard let snapshot = snapshotsByAccountID[accountID] else {
            throw AppError.invalidData("Missing smoke usage snapshot for \(accountID)")
        }
        return snapshot
    }
}

private struct SmokeDateProvider: DateProviding {
    let now: Int64

    func unixSecondsNow() -> Int64 {
        now
    }
}

private struct SmokeChatLoginService: ChatGPTOAuthLoginServiceProtocol {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        return ChatGPTOAuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id"
        )
    }
}

private struct SmokeCodexCLIService: CodexCLIServiceProtocol {
    func launchApp(workspacePath: String?) throws -> Bool {
        _ = workspacePath
        return true
    }
}

private struct SmokeEditorAppService: EditorAppServiceProtocol {
    func listInstalledApps() -> [InstalledEditorApp] { [] }

    func restartSelectedApps(_ targets: [EditorAppID]) -> (restarted: [EditorAppID], error: String?) {
        (targets, nil)
    }
}

private struct SmokeOpencodeAuthSyncService: OpencodeAuthSyncServiceProtocol {
    func syncFromCodexAuth(_ authJSON: JSONValue) throws {
        _ = authJSON
    }
}

private final class SmokeLaunchAtStartupService: LaunchAtStartupServiceProtocol, @unchecked Sendable {
    private(set) var enabled = false

    func setEnabled(_ enabled: Bool) throws {
        self.enabled = enabled
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        self.enabled = enabled
    }
}

private actor SmokeCurrentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol {
    func recordLocalSelection(accountID: String) async throws {
        _ = accountID
    }

    func pushLocalSelectionIfNeeded() async throws {}

    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult {
        .noChange
    }

    func ensurePushSubscriptionIfNeeded() async throws {}
}

private actor SmokeProxyLocalCommandService: ProxyLocalCommandServiceProtocol {
    private var commands: [ProxyControlCommandKind] = []
    private var running = false

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        commands.append(command.kind)
        switch command.kind {
        case .startProxy:
            running = true
        case .stopProxy:
            running = false
        default:
            break
        }

        return ProxyControlSnapshot(
            syncedAt: 1,
            sourceDeviceID: "smoke",
            proxyStatus: running
                ? ApiProxyStatus(running: true, port: 8787, apiKey: "key", availableAccounts: 2)
                : .idle,
            preferredProxyPort: 8787,
            preferredProxyPortText: "8787",
            autoStartProxy: false,
            cloudflaredStatus: .idle,
            cloudflaredTunnelMode: .quick,
            cloudflaredNamedInput: NamedCloudflaredTunnelInput(
                apiToken: "",
                accountID: "",
                zoneID: "",
                hostname: ""
            ),
            cloudflaredUseHTTP2: false,
            publicAccessEnabled: false,
            remoteServers: [],
            remoteStatusesSyncedAt: nil,
            remoteStatuses: [:],
            remoteLogs: [:],
            lastHandledCommandID: command.id,
            lastCommandError: nil
        )
    }

    func readCommands() -> [ProxyControlCommandKind] {
        commands
    }
}

private struct SmokeProxyRuntimeService: ProxyRuntimeService {
    func status() async -> ApiProxyStatus { .idle }

    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        ApiProxyStatus(running: true, port: preferredPort ?? 8787, apiKey: "key", availableAccounts: 2)
    }

    func stop() async -> ApiProxyStatus { .idle }
    func refreshAPIKey() async throws -> ApiProxyStatus { .idle }
    func syncAccountsStore() async throws {}
}

private struct SmokeCloudflaredService: CloudflaredServiceProtocol {
    func status() async -> CloudflaredStatus { .idle }
    func install() async throws -> CloudflaredStatus { .idle }

    func start(_ input: StartCloudflaredTunnelInput) async throws -> CloudflaredStatus {
        _ = input
        return .idle
    }

    func stop() async -> CloudflaredStatus { .idle }
}

private struct SmokeRemoteProxyService: RemoteProxyServiceProtocol {
    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        _ = server
        return RemoteProxyStatus(
            installed: false,
            serviceInstalled: false,
            running: false,
            enabled: false,
            serviceName: "",
            pid: nil,
            baseURL: "",
            apiKey: nil,
            lastError: nil
        )
    }

    func discover(server: RemoteServerConfig) async throws -> [DiscoveredRemoteProxyInstance] {
        _ = server
        return []
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func syncAccounts(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        _ = server
        _ = lines
        return ""
    }

    func uninstall(server: RemoteServerConfig, removeRemoteDirectory: Bool) async throws -> RemoteProxyStatus {
        _ = server
        _ = removeRemoteDirectory
        return RemoteProxyStatus(
            installed: false,
            serviceInstalled: false,
            running: false,
            enabled: false,
            serviceName: "",
            pid: nil,
            baseURL: "",
            apiKey: nil,
            lastError: nil
        )
    }
}
