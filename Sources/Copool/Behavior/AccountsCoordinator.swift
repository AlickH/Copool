import Foundation

actor AccountsCoordinator {
    enum UsageRefreshPolicy {
        static let minimumRefreshIntervalSeconds: Int64 = 25

        static func shouldRefresh(_ snapshot: UsageSnapshot?, now: Int64) -> Bool {
            guard let snapshot else { return true }
            return now - snapshot.fetchedAt >= minimumRefreshIntervalSeconds
        }
    }

    let storeRepository: AccountsStoreRepository
    let settingsRepository: SettingsRepository
    let authRepository: AuthRepository
    let usageService: UsageService
    let workspaceMetadataService: WorkspaceMetadataService?
    let chatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol
    let codexCLIService: CodexCLIServiceProtocol
    let editorAppService: EditorAppServiceProtocol
    let opencodeAuthSyncService: OpencodeAuthSyncServiceProtocol
    let dateProvider: DateProviding
    let runtimePlatform: RuntimePlatform

    private var currentAccountProjectionWriter: CurrentAccountProjectionWriter {
        CurrentAccountProjectionWriter(
            storeRepository: storeRepository,
            authRepository: authRepository,
            dateProvider: dateProvider,
            runtimePlatform: runtimePlatform
        )
    }

    init(
        storeRepository: AccountsStoreRepository,
        settingsRepository: SettingsRepository,
        authRepository: AuthRepository,
        usageService: UsageService,
        workspaceMetadataService: WorkspaceMetadataService? = nil,
        chatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol,
        codexCLIService: CodexCLIServiceProtocol,
        editorAppService: EditorAppServiceProtocol,
        opencodeAuthSyncService: OpencodeAuthSyncServiceProtocol,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform
    ) {
        self.storeRepository = storeRepository
        self.settingsRepository = settingsRepository
        self.authRepository = authRepository
        self.usageService = usageService
        self.workspaceMetadataService = workspaceMetadataService
        self.chatGPTOAuthLoginService = chatGPTOAuthLoginService
        self.codexCLIService = codexCLIService
        self.editorAppService = editorAppService
        self.opencodeAuthSyncService = opencodeAuthSyncService
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
    }

    func deleteAccount(id: String) throws {
        var store = try storeRepository.loadStore()
        store.accounts.removeAll { $0.id == id }
        try storeRepository.saveStore(store)
    }

    func listWorkspaceDirectory() throws -> [WorkspaceDirectoryEntry] {
        try storeRepository.loadStore().workspaceDirectory
    }

    func updateWorkspaceDirectoryVisibility(
        workspaceID: String,
        visibility: WorkspaceDirectoryVisibility
    ) throws {
        var store = try storeRepository.loadStore()
        let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(workspaceID)
        guard !normalizedWorkspaceID.isEmpty else { return }
        guard let index = store.workspaceDirectory.firstIndex(where: {
            AccountIdentity.normalizedAccountID($0.workspaceID) == normalizedWorkspaceID
        }) else {
            return
        }
        store.workspaceDirectory[index].visibility = visibility
        try storeRepository.saveStore(store)
    }

    func updateWorkspaceDirectoryStatus(
        workspaceID: String,
        workspaceName: String,
        email: String?,
        planType: String?,
        kind: WorkspaceDirectoryKind,
        status: WorkspaceDirectoryStatus
    ) throws {
        var store = try storeRepository.loadStore()
        let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(workspaceID)
        guard !normalizedWorkspaceID.isEmpty else { return }
        let now = dateProvider.unixSecondsNow()
        let entry = WorkspaceDirectoryEntry(
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            email: email,
            planType: planType,
            kind: kind,
            source: status == .deactivated ? .deactivated : .consent,
            status: status,
            visibility: .visible,
            lastSeenAt: now,
            lastStatusCheckedAt: now
        )

        if let index = store.workspaceDirectory.firstIndex(where: {
            AccountIdentity.normalizedAccountID($0.workspaceID) == normalizedWorkspaceID
        }) {
            store.workspaceDirectory[index] = entry
        } else {
            store.workspaceDirectory.append(entry)
        }
        try storeRepository.saveStore(store)
    }

    func updateTeamAlias(id: String, alias: String?) throws -> AccountSummary {
        var store = try storeRepository.loadStore()
        guard let index = store.accounts.firstIndex(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_update"))
        }

        store.accounts[index].teamAlias = normalizeTeamAlias(alias)
        store.accounts[index].updatedAt = dateProvider.unixSecondsNow()
        try storeRepository.saveStore(store)

        return toSummary(store.accounts[index])
    }

    func updateAccountDisplayStatus(id: String, status: AccountDisplayStatus) throws -> AccountSummary {
        var store = try storeRepository.loadStore()
        guard let index = store.accounts.firstIndex(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_update"))
        }

        store.accounts[index].displayStatus = status
        store.accounts[index].updatedAt = dateProvider.unixSecondsNow()
        try storeRepository.saveStore(store)

        return toSummary(store.accounts[index])
    }

    func switchAccount(id: String) throws {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        try updateCurrentAccountProjection(account: account)
    }

    func switchAccountAndApplySettings(id: String, workspacePath: String? = nil) throws -> SwitchAccountExecutionResult {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        AccountSwitchDebugLog.write(
            "switchAccountAndApplySettings.begin",
            "requestedCardID=\(id) \(AccountSwitchDebugLog.describe(account: account)) \(AccountSwitchDebugLog.describe(store: store, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
        try updateCurrentAccountProjection(account: account)
        let settings = try settingsRepository.loadSettings()
        let result = try applySwitchSideEffects(
            for: account,
            settings: settings,
            workspacePath: workspacePath
        )
        let latestStore = try storeRepository.loadStore()
        let restartedEditorNames = result.restartedEditorApps.map(\.rawValue).joined(separator: ",")
        AccountSwitchDebugLog.write(
            "switchAccountAndApplySettings.end",
            "requestedCardID=\(id) \(AccountSwitchDebugLog.describe(store: latestStore, currentAuthAccountKey: authRepository.currentAuthAccountKey())) opencodeSynced=\(result.opencodeSynced) restartedEditors=\(restartedEditorNames) usedFallbackCLI=\(result.usedFallbackCLI)"
        )
        return result
    }

    func applyCurrentSelection(
        cardID: String,
        selection: CurrentAccountSelection,
        writeAuth: Bool = false
    ) throws {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == cardID }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        AccountSwitchDebugLog.write(
            "applyCurrentSelection.begin",
            "cardID=\(cardID) selection=\(AccountSwitchDebugLog.describe(selection: selection)) before=\(AccountSwitchDebugLog.describe(store: store, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
        let latestStore = try currentAccountProjectionWriter.apply(
            selection: selection,
            account: account,
            writeAuth: writeAuth
        )
        AccountSwitchDebugLog.write(
            "applyCurrentSelection.end",
            "cardID=\(cardID) after=\(AccountSwitchDebugLog.describe(store: latestStore, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
    }

    func applyCurrentCardID(_ cardID: String) throws {
        let store = try storeRepository.loadStore()
        guard store.accounts.contains(where: { $0.id == cardID }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }
        let latestStore = try storeRepository.mutateStore { store in
            store.currentAccountID = cardID
        }
        AccountSwitchDebugLog.write(
            "applyCurrentCardID",
            "cardID=\(cardID) after=\(AccountSwitchDebugLog.describe(store: latestStore, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
    }

    func switchAccountAndReload(id: String, workspacePath: String? = nil) async throws -> (
        selectedAccount: AccountSummary,
        accounts: [AccountSummary],
        execution: SwitchAccountExecutionResult
    ) {
        let execution = try switchAccountAndApplySettings(id: id, workspacePath: workspacePath)
        let accounts = try await listAccounts(refreshWorkspaceMetadata: false)
        guard let selectedAccount = accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }
        AccountSwitchDebugLog.write(
            "switchAccountAndReload.end",
            "requestedCardID=\(id) selected=\(AccountSwitchDebugLog.describe(account: selectedAccount)) \(AccountSwitchDebugLog.describe(accounts: accounts))"
        )
        return (selectedAccount, accounts, execution)
    }

    func smartSwitch() async throws -> (AccountSummary, SwitchAccountExecutionResult)? {
        let sorted = AccountRanking.sortByRemaining(try await listAccounts())
        guard let best = sorted.first else { return nil }
        let switchResult = try await switchAccountAndReload(id: best.id)
        return (switchResult.selectedAccount, switchResult.execution)
    }

    func autoSmartSwitchIfNeeded() async throws -> (
        selectedAccount: AccountSummary,
        accounts: [AccountSummary],
        execution: SwitchAccountExecutionResult
    )? {
        let accounts = try await listAccounts()
        let decisionLog = AccountSwitchDebugLog.describeAutoSwitch(accounts: accounts)
        AccountSwitchDebugLog.write(
            "autoSmartSwitchIfNeeded.inspect",
            decisionLog
        )
        guard let target = AccountRanking.pickAutoSwitchTarget(accounts) else {
            AccountSwitchDebugLog.write(
                "autoSmartSwitchIfNeeded.skip",
                decisionLog
            )
            return nil
        }
        AccountSwitchDebugLog.write(
            "autoSmartSwitchIfNeeded.target",
            "target=\(AccountSwitchDebugLog.describe(account: target)) \(decisionLog)"
        )
        return try await switchAccountAndReload(id: target.id)
    }

    private func updateCurrentAccountProjection(account: StoredAccount) throws {
        let store = try storeRepository.loadStore()
        guard store.accounts.contains(where: { $0.id == account.id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        AccountSwitchDebugLog.write(
            "updateCurrentAccountProjection.begin",
            "target=\(AccountSwitchDebugLog.describe(account: account)) before=\(AccountSwitchDebugLog.describe(store: store, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
        let latestStore = try currentAccountProjectionWriter.apply(account: account)
        AccountSwitchDebugLog.write(
            "updateCurrentAccountProjection.end",
            "target=\(AccountSwitchDebugLog.describe(account: account)) after=\(AccountSwitchDebugLog.describe(store: latestStore, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
    }

    private func normalizeTeamAlias(_ alias: String?) -> String? {
        guard let alias else { return nil }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applySwitchSideEffects(
        for account: StoredAccount,
        settings: AppSettings,
        workspacePath: String?
    ) throws -> SwitchAccountExecutionResult {
        var result = SwitchAccountExecutionResult.idle

        if settings.syncOpencodeOpenaiAuth {
            do {
                try opencodeAuthSyncService.syncFromCodexAuth(account.authJSON)
                result.opencodeSynced = true
            } catch {
                result.opencodeSyncError = error.localizedDescription
            }
        }

        guard runtimePlatform == .macOS else {
            return result
        }

        if settings.restartEditorsOnSwitch {
            let restart = editorAppService.restartSelectedApps(settings.restartEditorTargets)
            result.restartedEditorApps = restart.restarted
            result.editorRestartError = restart.error
        }

        if settings.launchCodexAfterSwitch {
            result.usedFallbackCLI = try codexCLIService.launchApp(workspacePath: workspacePath)
        }

        return result
    }

    static func matchingStoredAccountIndex(
        for extracted: ExtractedAuth,
        in accounts: [StoredAccount]
    ) -> Int? {
        AccountIdentity.preferredMatchIndex(for: extracted, in: accounts)
    }

    static func matchingStoredAccount(
        for extracted: ExtractedAuth,
        in accounts: [StoredAccount]
    ) -> StoredAccount? {
        guard let index = matchingStoredAccountIndex(for: extracted, in: accounts) else {
            return nil
        }
        return accounts[index]
    }
}
