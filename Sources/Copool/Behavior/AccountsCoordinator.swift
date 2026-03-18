import Foundation

actor AccountsCoordinator {
    private enum UsageRefreshPolicy {
        static let minimumRefreshIntervalSeconds: Int64 = 25

        static func shouldRefresh(_ snapshot: UsageSnapshot?, now: Int64) -> Bool {
            guard let snapshot else { return true }
            return now - snapshot.fetchedAt >= minimumRefreshIntervalSeconds
        }
    }

    private enum UsageRefreshExecutionMode {
        case parallel
        case serial
    }

    private let storeRepository: AccountsStoreRepository
    private let authRepository: AuthRepository
    private let usageService: UsageService
    private let chatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol
    private let codexCLIService: CodexCLIServiceProtocol
    private let editorAppService: EditorAppServiceProtocol
    private let opencodeAuthSyncService: OpencodeAuthSyncServiceProtocol
    private let dateProvider: DateProviding
    private let runtimePlatform: RuntimePlatform

    init(
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository,
        usageService: UsageService,
        chatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol,
        codexCLIService: CodexCLIServiceProtocol,
        editorAppService: EditorAppServiceProtocol,
        opencodeAuthSyncService: OpencodeAuthSyncServiceProtocol,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform
    ) {
        self.storeRepository = storeRepository
        self.authRepository = authRepository
        self.usageService = usageService
        self.chatGPTOAuthLoginService = chatGPTOAuthLoginService
        self.codexCLIService = codexCLIService
        self.editorAppService = editorAppService
        self.opencodeAuthSyncService = opencodeAuthSyncService
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
    }

    func listAccounts() throws -> [AccountSummary] {
        let store = try storeRepository.loadStore()
        let currentAccountID = authRepository.currentAuthAccountID()
        return store.accountSummaries(currentAccountID: currentAccountID)
    }

    @discardableResult
    func importCurrentAuthAccount(customLabel: String?) async throws -> AccountSummary {
        let authJSON = try authRepository.readCurrentAuth()
        return try await importAccount(authJSON: authJSON, customLabel: customLabel)
    }

    @discardableResult
    func importAccountFile(from url: URL, customLabel: String?, setAsCurrent: Bool) async throws -> AccountSummary {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let authJSON = try authRepository.readAuth(from: url)
        if setAsCurrent {
            if runtimePlatform == .macOS {
                try authRepository.writeCurrentAuth(authJSON)
            }
        }
        return try await importAccount(authJSON: authJSON, customLabel: customLabel)
    }

    @discardableResult
    private func importAccount(authJSON: JSONValue, customLabel: String?) async throws -> AccountSummary {
        let extracted = try authRepository.extractAuth(from: authJSON)

        var usage: UsageSnapshot?
        var usageError: String?

        do {
            usage = try await usageService.fetchUsage(accessToken: extracted.accessToken, accountID: extracted.accountID)
        } catch {
            usageError = error.localizedDescription
        }

        let now = dateProvider.unixSecondsNow()
        let generatedLabel = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = generatedLabel?.isEmpty == false
            ? generatedLabel!
            : (extracted.email ?? "Codex \(String(extracted.accountID.prefix(8)))")

        var store = try storeRepository.loadStore()
        let account = StoredAccount(
            id: UUID().uuidString,
            label: label,
            email: extracted.email,
            accountID: extracted.accountID,
            planType: extracted.planType,
            teamName: extracted.teamName,
            teamAlias: nil,
            authJSON: authJSON,
            addedAt: now,
            updatedAt: now,
            usage: usage,
            usageError: usageError
        )

        if let existingIndex = store.accounts.firstIndex(where: { $0.accountID == extracted.accountID }) {
            var existing = store.accounts[existingIndex]
            existing.label = account.label
            existing.email = account.email
            existing.planType = account.planType
            existing.teamName = account.teamName
            existing.authJSON = account.authJSON
            existing.updatedAt = now
            existing.usage = usage ?? existing.usage
            existing.usageError = usageError
            store.accounts[existingIndex] = existing
        } else {
            store.accounts.append(account)
        }

        try storeRepository.saveStore(store)
        let savedAccount = store.accounts.first(where: { $0.accountID == extracted.accountID })!

        let currentAccountID = authRepository.currentAuthAccountID()
        return toSummary(savedAccount, currentAccountID: currentAccountID)
    }

    func deleteAccount(id: String) throws {
        var store = try storeRepository.loadStore()
        store.accounts.removeAll { $0.id == id }
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

        return toSummary(store.accounts[index], currentAccountID: authRepository.currentAuthAccountID())
    }

    func switchAccount(id: String) throws {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        try updateCurrentAccountProjection(authJSON: account.authJSON)
    }

    func switchAccountAndApplySettings(id: String, workspacePath: String? = nil) throws -> SwitchAccountExecutionResult {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        try updateCurrentAccountProjection(authJSON: account.authJSON)
        return try applySwitchSideEffects(
            for: account,
            settings: store.settings,
            workspacePath: workspacePath
        )
    }

    func smartSwitch() throws -> (AccountSummary, SwitchAccountExecutionResult)? {
        let sorted = AccountRanking.sortByRemaining(try listAccounts())
        guard let best = sorted.first else { return nil }
        let execution = try switchAccountAndApplySettings(id: best.id)
        return (best, execution)
    }

    func autoSmartSwitchIfNeeded() throws -> (AccountSummary, SwitchAccountExecutionResult)? {
        let accounts = try listAccounts()
        guard let target = AccountRanking.pickAutoSwitchTarget(accounts) else {
            return nil
        }
        let execution = try switchAccountAndApplySettings(id: target.id)
        return (target, execution)
    }

    func addAccountViaLogin(customLabel: String?, timeoutSeconds: TimeInterval = 10 * 60) async throws -> AccountSummary {
        let tokens = try await chatGPTOAuthLoginService.signInWithChatGPT(timeoutSeconds: timeoutSeconds)
        let authJSON = try authRepository.makeChatGPTAuth(from: tokens)
        return try await importAccount(authJSON: authJSON, customLabel: customLabel)
    }

    func refreshAllUsage() async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .parallel, force: false)
    }

    func refreshAllUsageSerially() async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .serial, force: false)
    }

    func refreshAllUsage(force: Bool) async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .parallel, force: force)
    }

    func refreshAllUsageSerially(force: Bool) async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .serial, force: force)
    }

    private func refreshAllUsage(using mode: UsageRefreshExecutionMode, force: Bool) async throws -> [AccountSummary] {
        let now = dateProvider.unixSecondsNow()
        let snapshot = try storeRepository.loadStore()
        let authRepository = self.authRepository
        let usageService = self.usageService

        let refreshedAccounts: [StoredAccount]
        switch mode {
        case .parallel:
            refreshedAccounts = await withTaskGroup(of: StoredAccount.self, returning: [StoredAccount].self) { group in
                for account in snapshot.accounts {
                    group.addTask {
                        await Self.refreshAccount(
                            account,
                            now: now,
                            forceRefresh: force,
                            authRepository: authRepository,
                            usageService: usageService
                        )
                    }
                }

                var refreshedAccounts: [StoredAccount] = []
                refreshedAccounts.reserveCapacity(snapshot.accounts.count)
                for await account in group {
                    refreshedAccounts.append(account)
                }
                return refreshedAccounts
            }
        case .serial:
            var sequentialAccounts: [StoredAccount] = []
            sequentialAccounts.reserveCapacity(snapshot.accounts.count)
            for account in snapshot.accounts {
                let refreshed = await Self.refreshAccount(
                    account,
                    now: now,
                    forceRefresh: force,
                    authRepository: authRepository,
                    usageService: usageService
                )
                sequentialAccounts.append(refreshed)
            }
            refreshedAccounts = sequentialAccounts
        }

        var latest = try storeRepository.loadStore()
        let refreshedByAccountID = Dictionary(uniqueKeysWithValues: refreshedAccounts.map { ($0.accountID, $0) })

        latest.accounts = latest.accounts.map { existing in
            guard let refreshed = refreshedByAccountID[existing.accountID] else {
                return existing
            }
            var merged = existing
            merged.label = refreshed.label
            merged.email = refreshed.email
            merged.planType = refreshed.planType
            merged.teamName = refreshed.teamName
            merged.teamAlias = refreshed.teamAlias
            merged.authJSON = refreshed.authJSON
            merged.updatedAt = refreshed.updatedAt
            merged.usage = refreshed.usage
            merged.usageError = refreshed.usageError
            return merged
        }

        try storeRepository.saveStore(latest)

        return latest.accountSummaries(currentAccountID: authRepository.currentAuthAccountID())
    }

    private static func refreshAccount(
        _ account: StoredAccount,
        now: Int64,
        forceRefresh: Bool,
        authRepository: AuthRepository,
        usageService: UsageService
    ) async -> StoredAccount {
        var account = account
        guard forceRefresh || UsageRefreshPolicy.shouldRefresh(account.usage, now: now) else {
            return account
        }

        do {
            let extracted = try authRepository.extractAuth(from: account.authJSON)
            let usage = try await usageService.fetchUsage(
                accessToken: extracted.accessToken,
                accountID: extracted.accountID
            )
            account.usage = usage
            account.usageError = nil
            account.planType = extracted.planType ?? account.planType
            account.teamName = extracted.teamName
            account.email = extracted.email ?? account.email
        } catch {
            account.usageError = error.localizedDescription
        }

        account.updatedAt = now
        return account
    }

    private func toSummary(_ account: StoredAccount, currentAccountID: String?) -> AccountSummary {
        AccountsStore(accounts: [account]).accountSummaries(currentAccountID: currentAccountID)[0]
    }

    private func updateCurrentAccountProjection(authJSON: JSONValue) throws {
        let extracted = try authRepository.extractAuth(from: authJSON)
        var store = try storeRepository.loadStore()
        guard store.accounts.contains(where: { $0.accountID == extracted.accountID }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        store.currentSelection = CurrentAccountSelection(
            accountID: extracted.accountID,
            selectedAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: runtimePlatform == .macOS ? "macos-local" : "ios-local"
        )
        try storeRepository.saveStore(store)

        guard runtimePlatform == .macOS else { return }
        try authRepository.writeCurrentAuth(authJSON)
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
}
