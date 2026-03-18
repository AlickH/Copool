import Foundation

actor SettingsCoordinator {
    private let storeRepository: AccountsStoreRepository
    private let launchAtStartupService: LaunchAtStartupServiceProtocol

    init(
        storeRepository: AccountsStoreRepository,
        launchAtStartupService: LaunchAtStartupServiceProtocol
    ) {
        self.storeRepository = storeRepository
        self.launchAtStartupService = launchAtStartupService
    }

    func currentSettings() throws -> AppSettings {
        try storeRepository.loadStore().settings
    }

    func updateSettings(_ patch: AppSettingsPatch) throws -> AppSettings {
        let launchAtStartupPatch = patch.launchAtStartup

        var store = try storeRepository.loadStore()
        var settings = store.settings

        if let value = patch.launchAtStartup { settings.launchAtStartup = value }
        if let value = patch.launchCodexAfterSwitch { settings.launchCodexAfterSwitch = value }
        if let value = patch.autoSmartSwitch { settings.autoSmartSwitch = value }
        if let value = patch.syncOpencodeOpenaiAuth { settings.syncOpencodeOpenaiAuth = value }
        if let value = patch.restartEditorsOnSwitch { settings.restartEditorsOnSwitch = value }
        if let value = patch.restartEditorTargets { settings.restartEditorTargets = value }
        if let value = patch.autoStartApiProxy { settings.autoStartApiProxy = value }
        if let value = patch.remoteServers { settings.remoteServers = value }
        if let value = patch.locale { settings.locale = AppLocale.resolve(value).identifier }

        store.settings = settings
        try storeRepository.saveStore(store)

        if let launchAtStartupPatch {
            try launchAtStartupService.setEnabled(launchAtStartupPatch)
        }

        return settings
    }

    func syncLaunchAtStartupFromStore() throws {
        let settings = try storeRepository.loadStore().settings
        try launchAtStartupService.syncWithStoreValue(settings.launchAtStartup)
    }
}
