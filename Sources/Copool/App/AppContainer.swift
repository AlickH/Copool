import Foundation

@MainActor
struct AppContainer {
    let accountsModel: AccountsPageModel
    let inviteToolModel: InviteToolPageModel
    let proxyModel: ProxyPageModel
    let settingsModel: SettingsPageModel
    let trayModel: TrayMenuModel
    let proxyControlBridge: ProxyControlBridge

    static func liveOrCrash() -> AppContainer {
        do {
            let paths = try FileSystemPaths.live()
            let storeRepository = StoreFileRepository(paths: paths)
            let authRepository = AuthFileRepository(paths: paths)
            let initialStore = try storeRepository.loadStore()
            let usageService = DefaultUsageService(configPath: paths.codexConfigPath)
            let proxyService = SwiftNativeProxyRuntimeService(
                paths: paths,
                storeRepository: storeRepository,
                authRepository: authRepository
            )
            let cloudflaredService = CloudflaredService(paths: paths)
            let remoteService = RemoteProxyService(
                repoRoot: RepositoryLocator.findRepoRoot(startingAt: URL(fileURLWithPath: #filePath)),
                sourceAccountStorePath: paths.accountStorePath,
                sourceAuthPath: paths.codexAuthPath
            )
            let chatGPTOAuthLoginService = OpenAIChatGPTOAuthLoginService(configPath: paths.codexConfigPath)
            let codexCLIService = CodexCLIService()
            let editorAppService = EditorAppService()
            let opencodeSyncService = OpencodeAuthSyncService()
            let launchAtStartupService = LaunchAtStartupService()
            let cloudSyncService = CloudKitAccountsSyncService(storeRepository: storeRepository)
            let cloudSyncAvailabilityService = CloudSyncAvailabilityService()
            let proxyControlCloudSyncService = CloudKitProxyControlSyncService()
            let currentAccountSelectionSyncService = CloudKitCurrentAccountSelectionSyncService(
                storeRepository: storeRepository,
                authRepository: authRepository
            )

            let settingsCoordinator = SettingsCoordinator(
                storeRepository: storeRepository,
                launchAtStartupService: launchAtStartupService
            )
            let accountsCoordinator = AccountsCoordinator(
                storeRepository: storeRepository,
                authRepository: authRepository,
                usageService: usageService,
                chatGPTOAuthLoginService: chatGPTOAuthLoginService,
                codexCLIService: codexCLIService,
                editorAppService: editorAppService,
                opencodeAuthSyncService: opencodeSyncService
            )
            let initialAccounts = initialStore.accountSummaries(
                currentAccountID: authRepository.currentAuthAccountID()
            )
            let proxyCoordinator = ProxyCoordinator(
                proxyService: proxyService,
                cloudflaredService: cloudflaredService,
                remoteService: remoteService
            )
            let inviteToolCoordinator = InviteToolCoordinator(
                service: InviteToolService()
            )
            let proxyControlBridge = ProxyControlBridge(
                proxyCoordinator: proxyCoordinator,
                settingsCoordinator: settingsCoordinator,
                cloudSyncService: proxyControlCloudSyncService
            )
            let trayModel = TrayMenuModel(
                accountsCoordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                cloudSyncService: cloudSyncService,
                currentAccountSelectionSyncService: currentAccountSelectionSyncService,
                backgroundRefreshPolicy: .forPlatform(PlatformCapabilities.currentPlatform),
                initialAccounts: initialAccounts
            )
            let settingsModel = SettingsPageModel(
                settingsCoordinator: settingsCoordinator,
                editorAppService: editorAppService,
                onSettingsUpdated: { settings in
                    trayModel.applySettings(settings)
                }
            )

            Task {
                do {
                    try await settingsCoordinator.syncLaunchAtStartupFromStore()
                } catch {
                    // Keep launch non-blocking even if system login item sync fails.
                }
            }

            return AppContainer(
                accountsModel: AccountsPageModel(
                    coordinator: accountsCoordinator,
                    manualRefreshService: trayModel,
                    currentAccountSelectionSyncService: currentAccountSelectionSyncService,
                    cloudSyncAvailabilityService: cloudSyncAvailabilityService,
                    onLocalAccountsChanged: { accounts in
                        trayModel.acceptLocalAccountsSnapshot(accounts)
                    },
                    initialAccounts: initialAccounts
                ),
                inviteToolModel: InviteToolPageModel(
                    coordinator: inviteToolCoordinator
                ),
                proxyModel: ProxyPageModel(
                    coordinator: proxyCoordinator,
                    settingsCoordinator: settingsCoordinator,
                    proxyControlCloudSyncService: proxyControlCloudSyncService
                ),
                settingsModel: settingsModel,
                trayModel: trayModel,
                proxyControlBridge: proxyControlBridge
            )
        } catch {
            fatalError("Failed to bootstrap Swift migration app: \(error.localizedDescription)")
        }
    }
}
