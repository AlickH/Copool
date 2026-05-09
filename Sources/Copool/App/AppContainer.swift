import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppContainer {
    private final class AccountsStoreChangeHandlerBox: @unchecked Sendable {
        var handler: (@Sendable () -> Void)?
    }

    let accountsModel: AccountsPageModel
    let settingsModel: SettingsPageModel
    let trayModel: TrayMenuModel

    private let settingsCoordinator: SettingsCoordinator
    private let accountsWidgetSnapshotWriter: AccountsWidgetSnapshotWriter
    private let accountsWidgetDisplayModeStore: AccountsWidgetDisplayModeStore
    private let proxyCoordinator: ProxyCoordinator
    private var accountsWidgetSnapshotCancellable: AnyCancellable?
    private var accountsPageSnapshotCancellable: AnyCancellable?
    private var widgetUsageProgressDisplayMode: UsageProgressDisplayMode

    lazy var proxyModel: ProxyPageModel = ProxyPageModel(
        coordinator: proxyCoordinator,
        settingsCoordinator: settingsCoordinator,
        chooseIdentityFilePath: {
            #if canImport(AppKit)
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.title = "Select SSH key file"
            guard panel.runModal() == .OK else { return nil }
            return panel.url?.path
            #else
            return nil
            #endif
        }
    )

    static func liveOrCrash() -> AppContainer {
        do {
            let paths = try FileSystemPaths.live()
            let storeRepository = StoreFileRepository(paths: paths)
            let settingsRepository = SettingsFileRepository(paths: paths)
            let authRepository = AuthFileRepository(paths: paths)
            let initialAccounts = try initialAccountsSnapshot(using: storeRepository)
            let usageService = DefaultUsageService(configPath: paths.codexConfigPath)
            let workspaceMetadataService = DefaultWorkspaceMetadataService(configPath: paths.codexConfigPath)
            let chatGPTOAuthLoginService = OpenAIChatGPTOAuthLoginService(configPath: paths.codexConfigPath)
            let codexCLIService = CodexCLIService()
            let editorAppService = EditorAppService()
            let opencodeSyncService = OpencodeAuthSyncService()
            let launchAtStartupService = LaunchAtStartupService()
            let accountsStoreChangeHandlerBox = AccountsStoreChangeHandlerBox()
            let accountsCoordinator = AccountsCoordinator(
                storeRepository: storeRepository,
                settingsRepository: settingsRepository,
                authRepository: authRepository,
                usageService: usageService,
                workspaceMetadataService: workspaceMetadataService,
                chatGPTOAuthLoginService: chatGPTOAuthLoginService,
                codexCLIService: codexCLIService,
                editorAppService: editorAppService,
                opencodeAuthSyncService: opencodeSyncService
            )
            let proxyCoordinator = ProxyCoordinator(
                proxyService: SwiftNativeProxyRuntimeService(
                    paths: paths,
                    storeRepository: storeRepository,
                    settingsRepository: settingsRepository,
                    authRepository: authRepository,
                    onAccountsStoreChanged: {
                        accountsStoreChangeHandlerBox.handler?()
                    },
                    switchAccount: { cardID in
                        _ = try await accountsCoordinator.switchAccountAndApplySettings(id: cardID)
                    }
                ),
                cloudflaredService: CloudflaredService(paths: paths),
                remoteService: RemoteProxyService(
                    repoRoot: RepositoryLocator.findRepoRoot(startingAt: URL(fileURLWithPath: #filePath)),
                    sourceAccountStorePath: paths.accountStorePath
                )
            )
            let settingsCoordinator = SettingsCoordinator(
                settingsRepository: settingsRepository,
                launchAtStartupService: launchAtStartupService
            )
            let initialSettings = try settingsRepository.loadSettings()
            var applySettingsToContainer: ((AppSettings) -> Void)?
            try launchAtStartupService.syncWithStoreValue(initialSettings.launchAtStartup)
            let accountsWidgetDisplayModeStore = AccountsWidgetDisplayModeStore()
            let accountsWidgetSnapshotWriter = AccountsWidgetSnapshotWriter(
                localeProvider: {
                    let identifier = (try? await settingsCoordinator.currentSettings().locale)
                        ?? AppLocale.systemDefault.identifier
                    return Locale(identifier: AppLocale.resolve(identifier).identifier)
                }
            )
            let remoteAccountsMutationSyncService = RemoteAccountsMutationSyncService(
                settingsCoordinator: settingsCoordinator,
                proxyCoordinator: proxyCoordinator
            )
            let trayModel = TrayMenuModel(
                accountsCoordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                remoteAccountsMutationSyncService: remoteAccountsMutationSyncService,
                backgroundRefreshPolicy: .forPlatform(PlatformCapabilities.currentPlatform),
                initialAccounts: initialAccounts
            )
            accountsStoreChangeHandlerBox.handler = { [weak trayModel] in
                guard let trayModel else { return }
                Task { @MainActor in
                    let accounts = try? await trayModel.accountsCoordinator.listAccounts(
                        refreshWorkspaceMetadata: false
                    )
                    guard let accounts else { return }
                    trayModel.acceptLocalAccountsSnapshot(accounts)
                }
            }
            let accountsModel = AccountsPageModel(
                coordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                manualRefreshService: trayModel,
                localAccountsMutationSyncService: trayModel,
                chooseAuthDocumentURL: {
                    #if canImport(AppKit)
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = false
                    panel.allowedContentTypes = [.json]
                    panel.title = L10n.tr("accounts.action.import_auth_file")
                    NSApp.activate(ignoringOtherApps: true)
                    guard panel.runModal() == .OK else { return nil }
                    return panel.url
                    #else
                    return nil
                    #endif
                },
                runtimePlatform: PlatformCapabilities.currentPlatform,
                usageProgressDisplayMode: initialSettings.usageProgressDisplayMode,
                onLocalAccountsChanged: { accounts in
                    trayModel.acceptLocalAccountsSnapshot(accounts)
                },
                onSettingsUpdated: { settings in
                    applySettingsToContainer?(settings)
                },
                initialAccounts: initialAccounts
            )
            let settingsModel = SettingsPageModel(
                settingsCoordinator: settingsCoordinator,
                editorAppService: editorAppService,
                onSettingsUpdated: { settings in
                    applySettingsToContainer?(settings)
                },
                onQuitRequested: {
                    #if canImport(AppKit)
                    NSApp.terminate(nil)
                    #endif
                }
            )

            let container = AppContainer(
                settingsCoordinator: settingsCoordinator,
                accountsWidgetSnapshotWriter: accountsWidgetSnapshotWriter,
                accountsWidgetDisplayModeStore: accountsWidgetDisplayModeStore,
                proxyCoordinator: proxyCoordinator,
                widgetUsageProgressDisplayMode: initialSettings.usageProgressDisplayMode,
                accountsModel: accountsModel,
                settingsModel: settingsModel,
                trayModel: trayModel
            )
            applySettingsToContainer = { settings in
                container.applySettings(settings)
            }
            return container
        } catch {
            fatalError("Failed to bootstrap Swift migration app: \(error.localizedDescription)")
        }
    }

    private init(
        settingsCoordinator: SettingsCoordinator,
        accountsWidgetSnapshotWriter: AccountsWidgetSnapshotWriter,
        accountsWidgetDisplayModeStore: AccountsWidgetDisplayModeStore,
        proxyCoordinator: ProxyCoordinator,
        widgetUsageProgressDisplayMode: UsageProgressDisplayMode,
        accountsModel: AccountsPageModel,
        settingsModel: SettingsPageModel,
        trayModel: TrayMenuModel
    ) {
        self.settingsCoordinator = settingsCoordinator
        self.accountsWidgetSnapshotWriter = accountsWidgetSnapshotWriter
        self.accountsWidgetDisplayModeStore = accountsWidgetDisplayModeStore
        self.proxyCoordinator = proxyCoordinator
        self.widgetUsageProgressDisplayMode = widgetUsageProgressDisplayMode
        self.accountsModel = accountsModel
        self.settingsModel = settingsModel
        self.trayModel = trayModel
        accountsWidgetDisplayModeStore.save(rawValue: widgetUsageProgressDisplayMode.rawValue)
        accountsWidgetSnapshotCancellable = trayModel.$accounts
            .removeDuplicates()
            .sink { [weak self] accounts in
                guard let self else { return }
                Task {
                    await self.accountsWidgetSnapshotWriter.write(
                        accounts: accounts,
                        usageProgressDisplayMode: self.widgetUsageProgressDisplayMode
                    )
                }
            }
        accountsPageSnapshotCancellable = trayModel.$accounts
            .removeDuplicates()
            .sink { [weak accountsModel] accounts in
                accountsModel?.acceptExternalAccountsSnapshot(accounts)
            }
        Task {
            await accountsWidgetSnapshotWriter.write(
                accounts: trayModel.accounts,
                usageProgressDisplayMode: widgetUsageProgressDisplayMode
            )
        }
    }

    func applySettings(_ settings: AppSettings) {
        widgetUsageProgressDisplayMode = settings.usageProgressDisplayMode
        accountsWidgetDisplayModeStore.save(rawValue: settings.usageProgressDisplayMode.rawValue)
        trayModel.applySettings(settings)
        accountsModel.applySettings(settings)
        Task {
            await accountsWidgetSnapshotWriter.write(
                accounts: trayModel.accounts,
                usageProgressDisplayMode: settings.usageProgressDisplayMode
            )
        }
    }

    private static func initialAccountsSnapshot(
        using storeRepository: StoreFileRepository
    ) throws -> [AccountSummary] {
        let store = try storeRepository.loadStore()
        return store.accountSummaries()
    }
}
