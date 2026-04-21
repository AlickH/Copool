import Foundation
import OSLog

extension AccountsCoordinator {
    private var authFlowLogger: Logger {
        Logger(subsystem: "Copool", category: "AccountsAuthFlow")
    }

    func listAccounts(refreshWorkspaceMetadata: Bool = true) async throws -> [AccountSummary] {
        var store = try storeRepository.loadStore()
        let didReconcile = Self.reconcileStoredAccountMetadata(in: &store, authRepository: authRepository)
        let didEnrich = refreshWorkspaceMetadata
            ? try await enrichStoredWorkspaceMetadataIfNeeded(in: &store, forceRemoteCheck: false)
            : false
        if didReconcile || didEnrich {
            try storeRepository.saveStore(store)
        }
        let summaries = store.accountSummaries()
        AccountSwitchDebugLog.write(
            "listAccounts",
            "refreshWorkspaceMetadata=\(refreshWorkspaceMetadata) reconciled=\(didReconcile) enriched=\(didEnrich) \(AccountSwitchDebugLog.describe(store: store, currentAuthAccountKey: authRepository.currentAuthAccountKey())) \(AccountSwitchDebugLog.describe(accounts: summaries))"
        )
        return summaries
    }

    @discardableResult
    func importCurrentAuthAccount(customLabel: String?) async throws -> AccountSummary {
        guard runtimePlatform == .macOS else {
            throw AppError.invalidData(PlatformCapabilities.unsupportedOperationMessage)
        }
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
        if setAsCurrent, runtimePlatform == .macOS {
            try authRepository.writeCurrentAuth(authJSON)
        }
        return try await importAccount(authJSON: authJSON, customLabel: customLabel)
    }

    @discardableResult
    func addAccountViaLogin(customLabel: String?, timeoutSeconds: TimeInterval = 10 * 60) async throws -> AccountSummary {
        authFlowLogger.log("addAccountViaLogin started")
        AuthFlowDebugLog.write("AccountsAuthFlow", "addAccountViaLogin started")
        let tokens = try await chatGPTOAuthLoginService.signInWithChatGPT(timeoutSeconds: timeoutSeconds)
        authFlowLogger.log("addAccountViaLogin received tokens with \(tokens.consentWorkspaces.count) consent workspaces")
        AuthFlowDebugLog.write("AccountsAuthFlow", "addAccountViaLogin received tokens with \(tokens.consentWorkspaces.count) consent workspaces")
        let authJSON = try authRepository.makeChatGPTAuth(from: tokens)
        AuthFlowDebugLog.write("AccountsAuthFlow", "addAccountViaLogin made auth json")
        let imported = try await importAccount(authJSON: authJSON, customLabel: customLabel)
        authFlowLogger.log("addAccountViaLogin imported account \(imported.accountID, privacy: .public)")
        AuthFlowDebugLog.write("AccountsAuthFlow", "addAccountViaLogin imported account \(imported.accountID)")
        try persistConsentWorkspaceDirectory(
            tokens.consentWorkspaces,
            authorizedWorkspaceID: imported.accountID,
            fallbackEmail: imported.email,
            fallbackPlanType: imported.planType
        )
        authFlowLogger.log("addAccountViaLogin persisted consent workspace directory")
        AuthFlowDebugLog.write("AccountsAuthFlow", "addAccountViaLogin persisted consent workspace directory")
        return imported
    }

    func syncWorkspaceDirectory() async throws -> [WorkspaceDirectoryEntry] {
        var store = try storeRepository.loadStore()
        guard let workspaceMetadataService else {
            return store.workspaceDirectory
        }

        let eligibleAccounts = try store.accounts.compactMap { account -> (StoredAccount, ExtractedAuth)? in
            guard account.displayStatus == .list else { return nil }
            let extracted = try authRepository.extractAuth(from: account.authJSON)
            guard shouldLookupRemoteWorkspaceMetadata(extracted: extracted) else { return nil }
            return (account, extracted)
        }
        guard !eligibleAccounts.isEmpty else {
            return store.workspaceDirectory
        }

        let now = dateProvider.unixSecondsNow()
        let authorizedWorkspaceIDs = Set(
            store.accounts
                .filter { $0.displayStatus == .list }
                .map { AccountIdentity.normalizedAccountID($0.accountID) }
        )
        var nextEntriesByID = Dictionary(
            uniqueKeysWithValues: store.workspaceDirectory.compactMap { entry -> (String, WorkspaceDirectoryEntry)? in
                let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(entry.workspaceID)
                guard !normalizedWorkspaceID.isEmpty else { return nil }
                return (normalizedWorkspaceID, entry)
            }
        )

        var discoveredWorkspaceIDs: Set<String> = []
        var discoveredWorkspacesByID: [String: (metadata: WorkspaceMetadata, sourceAccount: StoredAccount)] = [:]

        for (sourceAccount, extracted) in eligibleAccounts {
            try Task.checkCancellation()
            let metadata = try await workspaceMetadataService.fetchWorkspaceMetadata(
                accessToken: extracted.accessToken
            )
            try Task.checkCancellation()

            for workspace in metadata {
                let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(workspace.accountID)
                guard !normalizedWorkspaceID.isEmpty else { continue }
                discoveredWorkspaceIDs.insert(normalizedWorkspaceID)
                if discoveredWorkspacesByID[normalizedWorkspaceID] == nil {
                    discoveredWorkspacesByID[normalizedWorkspaceID] = (workspace, sourceAccount)
                }
            }
        }

        for (normalizedWorkspaceID, discoveredWorkspace) in discoveredWorkspacesByID {
            let workspace = discoveredWorkspace.metadata
            let sourceAccount = discoveredWorkspace.sourceAccount
            guard !authorizedWorkspaceIDs.contains(normalizedWorkspaceID) else {
                nextEntriesByID.removeValue(forKey: normalizedWorkspaceID)
                continue
            }
            guard let workspaceName = Self.visibleWorkspaceName(for: workspace) else {
                nextEntriesByID.removeValue(forKey: normalizedWorkspaceID)
                continue
            }

            let existingEntry = nextEntriesByID[normalizedWorkspaceID]
            let shouldPreserveDeactivated = existingEntry?.status == .deactivated
            let entry = WorkspaceDirectoryEntry(
                workspaceID: workspace.accountID,
                workspaceName: workspaceName,
                email: sourceAccount.email,
                planType: sourceAccount.planType,
                kind: workspaceDirectoryKind(for: workspace),
                source: .legacyMetadata,
                status: shouldPreserveDeactivated ? .deactivated : .active,
                visibility: existingEntry?.visibility ?? .visible,
                lastSeenAt: now,
                lastStatusCheckedAt: existingEntry?.lastStatusCheckedAt
            )
            nextEntriesByID[normalizedWorkspaceID] = entry
        }

        nextEntriesByID = nextEntriesByID.filter { workspaceID, entry in
            if entry.status == .deactivated {
                return true
            }
            if entry.visibility == .deleted {
                return true
            }
            if entry.source == .consent {
                return true
            }
            return discoveredWorkspaceIDs.contains(workspaceID)
        }

        let retainedEntries = nextEntriesByID.values.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .workspace
            }
            let lhsName = lhs.workspaceName ?? ""
            let rhsName = rhs.workspaceName ?? ""
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }

        if store.workspaceDirectory != retainedEntries {
            store.workspaceDirectory = retainedEntries
            try storeRepository.saveStore(store)
        }

        return retainedEntries
    }

    @discardableResult
    func authorizeWorkspaceViaLogin(
        workspaceID: String,
        workspaceName: String,
        customLabel: String?,
        timeoutSeconds: TimeInterval = 10 * 60
    ) async throws -> AccountSummary {
        guard runtimePlatform == .macOS else {
            throw AppError.invalidData(PlatformCapabilities.unsupportedOperationMessage)
        }
        authFlowLogger.log("authorizeWorkspaceViaLogin started for workspace \(workspaceID, privacy: .public)")
        AuthFlowDebugLog.write("AccountsAuthFlow", "authorizeWorkspaceViaLogin started for workspace \(workspaceID)")
        let tokens = try await chatGPTOAuthLoginService.signInWithChatGPT(
            timeoutSeconds: timeoutSeconds,
            forcedWorkspaceID: workspaceID
        )
        authFlowLogger.log("authorizeWorkspaceViaLogin received tokens with \(tokens.consentWorkspaces.count) consent workspaces")
        AuthFlowDebugLog.write("AccountsAuthFlow", "authorizeWorkspaceViaLogin received tokens with \(tokens.consentWorkspaces.count) consent workspaces")
        let authJSON = try authRepository.makeChatGPTAuth(from: tokens)
        AuthFlowDebugLog.write("AccountsAuthFlow", "authorizeWorkspaceViaLogin made auth json")
        let imported = try await importAccount(
            authJSON: authJSON,
            customLabel: customLabel,
            prefetchedWorkspaceName: workspaceName
        )
        authFlowLogger.log("authorizeWorkspaceViaLogin imported account \(imported.accountID, privacy: .public)")
        AuthFlowDebugLog.write("AccountsAuthFlow", "authorizeWorkspaceViaLogin imported account \(imported.accountID)")
        try persistConsentWorkspaceDirectory(
            tokens.consentWorkspaces,
            authorizedWorkspaceID: imported.accountID,
            fallbackEmail: imported.email,
            fallbackPlanType: imported.planType
        )
        authFlowLogger.log("authorizeWorkspaceViaLogin persisted consent workspace directory")
        AuthFlowDebugLog.write("AccountsAuthFlow", "authorizeWorkspaceViaLogin persisted consent workspace directory")
        return imported
    }

    func refreshUsage(
        accountIDs: [String]? = nil,
        force: Bool = false,
        serial: Bool = false,
        onPartialUpdate: (@Sendable ([AccountSummary]) async -> Void)? = nil
    ) async throws -> [AccountSummary] {
        guard runtimePlatform == .macOS else {
            throw AppError.invalidData(PlatformCapabilities.unsupportedOperationMessage)
        }
        let now = dateProvider.unixSecondsNow()
        let snapshot = try storeRepository.loadStore()
        let authRepository = self.authRepository
        let usageService = self.usageService
        let targetIDSet = accountIDs.map(Set.init)
        let refreshTargets = snapshot.accounts.filter { account in
            guard account.displayStatus != .deleted, account.displayStatus != .pending else { return false }
            guard let targetIDSet else { return true }
            return targetIDSet.contains(account.id)
        }

        guard !refreshTargets.isEmpty else {
            return snapshot.accountSummaries()
        }

        var latest = snapshot
        if serial {
            for account in refreshTargets {
                let refreshed = await Self.refreshAccount(
                    account,
                    now: now,
                    forceRefresh: force,
                    authRepository: authRepository,
                    usageService: usageService
                )
                latest = try Self.mergeRefreshedAccount(
                    refreshed,
                    using: storeRepository,
                    authRepository: authRepository
                )
                if let onPartialUpdate {
                    await onPartialUpdate(
                        latest.accountSummaries()
                    )
                }
            }
        } else {
            try await withThrowingTaskGroup(of: StoredAccount.self, returning: Void.self) { group in
                for account in refreshTargets {
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
                for try await refreshed in group {
                    latest = try Self.mergeRefreshedAccount(
                        refreshed,
                        using: storeRepository,
                        authRepository: authRepository
                    )
                    if let onPartialUpdate {
                        await onPartialUpdate(
                            latest.accountSummaries()
                        )
                    }
                }
            }
        }

        return latest.accountSummaries()
    }

    func refreshWorkspaceMetadata(forceRemoteCheck: Bool) async throws -> [AccountSummary] {
        guard runtimePlatform == .macOS else {
            throw AppError.invalidData(PlatformCapabilities.unsupportedOperationMessage)
        }
        var store = try storeRepository.loadStore()
        let didChange = try await enrichStoredWorkspaceMetadataIfNeeded(
            in: &store,
            forceRemoteCheck: forceRemoteCheck
        )
        if didChange {
            try storeRepository.saveStore(store)
        }
        return store.accountSummaries()
    }

    private func importAccount(
        authJSON: JSONValue,
        customLabel: String?,
        prefetchedWorkspaceName: String? = nil
    ) async throws -> AccountSummary {
        authFlowLogger.log("importAccount started")
        AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount started")
        let now = dateProvider.unixSecondsNow()
        var authJSON = authJSON
        var extracted = try authRepository.extractAuth(from: authJSON)
        authFlowLogger.log("importAccount extracted account \(extracted.accountID, privacy: .public)")
        AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount extracted account \(extracted.accountID)")

        var usage: UsageSnapshot?
        var usageError: String?

        if runtimePlatform == .macOS {
            do {
                authFlowLogger.log("importAccount fetching usage snapshot")
                AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount fetching usage snapshot")
                let refreshed = try await Self.fetchUsageSnapshot(
                    authJSON: authJSON,
                    authRepository: authRepository,
                    usageService: usageService,
                    now: now
                )
                authJSON = refreshed.authJSON
                extracted = refreshed.extractedAuth
                usage = refreshed.usage
                authFlowLogger.log("importAccount usage snapshot fetched for \(extracted.accountID, privacy: .public)")
                AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount usage snapshot fetched for \(extracted.accountID)")
            } catch {
                if let deactivatedError = AppError.workspaceDeactivatedIfMatched(error) {
                    throw deactivatedError
                }
                usageError = error.localizedDescription
                authFlowLogger.error("importAccount usage snapshot failed: \(error.localizedDescription, privacy: .public)")
                AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount usage snapshot failed: \(error.localizedDescription)")
            }
        }

        if let prefetchedWorkspaceName {
            extracted.teamName = prefetchedWorkspaceName
        } else if runtimePlatform == .macOS,
                  let workspaceMetadataService,
                  shouldLookupRemoteWorkspaceMetadata(extracted: extracted) {
            authFlowLogger.log("importAccount fetching workspace metadata")
            AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount fetching workspace metadata")
            do {
                let directory = try await workspaceMetadataService.fetchWorkspaceMetadata(
                    accessToken: extracted.accessToken
                )
                if let remoteWorkspaceName = Self.remoteWorkspaceName(
                    for: extracted.accountID,
                    in: directory
                ) {
                    extracted.teamName = remoteWorkspaceName
                }
                authFlowLogger.log("importAccount workspace metadata fetched")
                AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount workspace metadata fetched")
            } catch {
                if let deactivatedError = AppError.workspaceDeactivatedIfMatched(error) {
                    throw deactivatedError
                }
                authFlowLogger.error("importAccount workspace metadata failed: \(error.localizedDescription, privacy: .public)")
                AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount workspace metadata failed: \(error.localizedDescription)")
            }
        }

        let generatedLabel = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = generatedLabel?.isEmpty == false
            ? generatedLabel!
            : (extracted.email ?? "Codex \(String(extracted.accountID.prefix(8)))")

        var store = try storeRepository.loadStore()
        authFlowLogger.log("importAccount loaded store with \(store.accounts.count) accounts")
        AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount loaded store with \(store.accounts.count) accounts")
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
            usageError: usageError,
            usageStateUpdatedAt: usage == nil && usageError == nil ? 0 : now,
            workspaceStatus: .active,
            principalID: extracted.principalID
        )

        if let existingIndex = Self.matchingStoredAccountIndex(for: extracted, in: store.accounts) {
            var existing = store.accounts[existingIndex]
            existing.label = account.label
            existing.email = account.email
            existing.planType = account.planType
            if let teamName = WorkspaceDisplayName.normalized(from: account.teamName) {
                existing.teamName = teamName
            }
            existing.authJSON = account.authJSON
            existing.updatedAt = now
            existing.usage = usage ?? existing.usage
            existing.usageError = usageError
            if usage != nil || usageError != nil {
                existing.usageStateUpdatedAt = now
            }
            existing.workspaceStatus = .active
            existing.principalID = extracted.principalID
            store.accounts[existingIndex] = existing
        } else {
            store.accounts.append(account)
        }
        store.workspaceDirectory.removeAll {
            AccountIdentity.normalizedAccountID($0.workspaceID)
                == AccountIdentity.normalizedAccountID(extracted.accountID)
        }
        authFlowLogger.log("importAccount saving store")
        AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount saving store")
        try storeRepository.saveStore(store)
        authFlowLogger.log("importAccount saved store")
        AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount saved store")
        let savedAccount = Self.matchingStoredAccount(for: extracted, in: store.accounts)!
        if store.currentAccountID == savedAccount.id {
            try? authRepository.writeCurrentAuth(authJSON)
        }
        authFlowLogger.log("importAccount persisted current auth if needed")
        AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount persisted current auth if needed")
        authFlowLogger.log("importAccount finished for \(savedAccount.accountID, privacy: .public)")
        AuthFlowDebugLog.write("AccountsAuthFlow", "importAccount finished for \(savedAccount.accountID)")
        return toSummary(savedAccount)
    }

    func toSummary(_ account: StoredAccount) -> AccountSummary {
        AccountsStore(accounts: [account], currentAccountID: account.id).accountSummaries()[0]
    }

    private func enrichStoredWorkspaceMetadataIfNeeded(
        in store: inout AccountsStore,
        forceRemoteCheck: Bool
    ) async throws -> Bool {
        guard let workspaceMetadataService else { return false }

        var didChange = false
        var cachedDirectories: [String: [WorkspaceMetadata]] = [:]

        for index in store.accounts.indices {
            let storedAccount = store.accounts[index]
            guard storedAccount.displayStatus != .deleted else { continue }
            let extracted = try authRepository.extractAuth(from: storedAccount.authJSON)
            guard shouldLookupRemoteWorkspaceMetadata(extracted: extracted) else { continue }
            if !forceRemoteCheck,
               WorkspaceDisplayName.normalized(from: storedAccount.teamName) != nil {
                continue
            }

            let directory: [WorkspaceMetadata]
            if let cached = cachedDirectories[extracted.accessToken] {
                directory = cached
            } else {
                do {
                    let fetched = try await workspaceMetadataService.fetchWorkspaceMetadata(
                        accessToken: extracted.accessToken
                    )
                    cachedDirectories[extracted.accessToken] = fetched
                    directory = fetched
                } catch {
                    if let deactivatedError = AppError.workspaceDeactivatedIfMatched(error) {
                        if store.accounts[index].workspaceStatus != .deactivated {
                            store.accounts[index].workspaceStatus = .deactivated
                            didChange = true
                        }
                        authFlowLogger.error("workspace metadata lookup marked \(storedAccount.accountID, privacy: .public) deactivated: \(deactivatedError.localizedDescription, privacy: .public)")
                        continue
                    }
                    if forceRemoteCheck {
                        throw error
                    }
                    authFlowLogger.error("workspace metadata lookup skipped for \(storedAccount.accountID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            guard let remoteWorkspace = Self.remoteWorkspaceSnapshot(
                for: extracted.accountID,
                in: directory
            ) else { continue }

            if let remoteWorkspaceName = remoteWorkspace.name,
               store.accounts[index].teamName != remoteWorkspaceName {
                store.accounts[index].teamName = remoteWorkspaceName
                didChange = true
            }

            if store.accounts[index].workspaceStatus != remoteWorkspace.status {
                store.accounts[index].workspaceStatus = remoteWorkspace.status
                didChange = true
            }
        }

        return didChange
    }

    private func shouldLookupRemoteWorkspaceMetadata(extracted: ExtractedAuth) -> Bool {
        let normalizedPlan = (extracted.planType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedPlan == "team" || normalizedPlan == "business" || normalizedPlan == "enterprise"
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
            UsageDebugLog.write(
                "refreshAccount.skip",
                "cardID=\(account.id) accountID=\(account.accountID) existing=\(describeUsage(account.usage))"
            )
            return account
        }

        do {
            let refreshed = try await fetchUsageSnapshot(
                authJSON: account.authJSON,
                authRepository: authRepository,
                usageService: usageService,
                now: now
            )
            account.authJSON = refreshed.authJSON
            account.usage = refreshed.usage
            account.usageError = nil
            account.usageStateUpdatedAt = now
            account.planType = refreshed.extractedAuth.planType ?? account.planType
        if let teamName = WorkspaceDisplayName.normalized(from: refreshed.extractedAuth.teamName) {
            account.teamName = teamName
        }
            account.email = refreshed.extractedAuth.email ?? account.email
            account.workspaceStatus = .active
            if account.displayStatus != .deleted {
                account.displayStatus = .list
            }
            account.principalID = refreshed.extractedAuth.principalID
            UsageDebugLog.write(
                "refreshAccount.success",
                "cardID=\(account.id) accountID=\(account.accountID) usage=\(describeUsage(account.usage)) usageStateUpdatedAt=\(account.usageStateUpdatedAt)"
            )
        } catch {
            if let deactivatedError = AppError.workspaceDeactivatedIfMatched(error) {
                account.workspaceStatus = .deactivated
                if account.displayStatus != .deleted {
                    account.displayStatus = .deactivated
                }
                account.usageError = deactivatedError.localizedDescription
            } else {
                account.usageError = userFacingUsageErrorMessage(for: error)
            }
            account.usageStateUpdatedAt = now
            UsageDebugLog.write(
                "refreshAccount.failure",
                "cardID=\(account.id) accountID=\(account.accountID) oldUsage=\(describeUsage(account.usage)) error=\(account.usageError ?? "nil") usageStateUpdatedAt=\(account.usageStateUpdatedAt)"
            )
        }

        account.updatedAt = now
        return account
    }

    private static func mergeRefreshedAccount(
        _ refreshed: StoredAccount,
        into store: AccountsStore
    ) -> AccountsStore {
        var store = store
        store.accounts = store.accounts.map { existing in
            guard existing.id == refreshed.id else { return existing }
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
            merged.usageStateUpdatedAt = refreshed.usageStateUpdatedAt
            merged.workspaceStatus = refreshed.workspaceStatus
            merged.displayStatus = refreshed.displayStatus
            merged.principalID = refreshed.principalID
            return merged
        }
        reconcileWorkspaceDirectory(for: refreshed, in: &store)
        return store
    }

    private static func mergeRefreshedAccount(
        _ refreshed: StoredAccount,
        using storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository
    ) throws -> AccountsStore {
        let latestStore = try storeRepository.mutateStore { store in
            store = mergeRefreshedAccount(refreshed, into: store)
        }
        try persistCurrentAuthIfNeeded(
            refreshedAccount: refreshed,
            in: latestStore,
            authRepository: authRepository
        )
        return latestStore
    }

    private static func describeUsage(_ usage: UsageSnapshot?) -> String {
        guard let usage else { return "nil" }
        return "fetchedAt=\(usage.fetchedAt) fiveHourUsed=\(describePercent(usage.fiveHour?.usedPercent)) fiveHourReset=\(usage.fiveHour?.resetAt.map(String.init) ?? "nil") oneWeekUsed=\(describePercent(usage.oneWeek?.usedPercent)) oneWeekReset=\(usage.oneWeek?.resetAt.map(String.init) ?? "nil")"
    }

    private static func describePercent(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.2f", value)
    }

    private static func reconcileWorkspaceDirectory(
        for account: StoredAccount,
        in store: inout AccountsStore
    ) {
        let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(account.accountID)
        guard !normalizedWorkspaceID.isEmpty else { return }

        store.workspaceDirectory.removeAll {
            AccountIdentity.normalizedAccountID($0.workspaceID) == normalizedWorkspaceID
        }
    }

    private static func refreshAuthIfNeeded(
        _ authJSON: JSONValue,
        authRepository: AuthRepository,
        now: Int64
    ) async throws -> JSONValue {
        guard accessTokenIsExpired(in: authJSON, now: now) else {
            return authJSON
        }
        return try await authRepository.refreshChatGPTAuth(authJSON)
    }

    private static func fetchUsageSnapshot(
        authJSON: JSONValue,
        authRepository: AuthRepository,
        usageService: UsageService,
        now: Int64
    ) async throws -> (authJSON: JSONValue, extractedAuth: ExtractedAuth, usage: UsageSnapshot) {
        var authJSON = try await refreshAuthIfNeeded(
            authJSON,
            authRepository: authRepository,
            now: now
        )
        var extracted = try authRepository.extractAuth(from: authJSON)

        do {
            let usage = try await usageService.fetchUsage(
                accessToken: extracted.accessToken,
                accountID: extracted.accountID
            )
            return (authJSON, extracted, usage)
        } catch {
            guard isExpiredAuthenticationError(error) else {
                throw error
            }

            authJSON = try await authRepository.refreshChatGPTAuth(authJSON)
            extracted = try authRepository.extractAuth(from: authJSON)
            let usage = try await usageService.fetchUsage(
                accessToken: extracted.accessToken,
                accountID: extracted.accountID
            )
            return (authJSON, extracted, usage)
        }
    }

    private static func accessTokenIsExpired(in authJSON: JSONValue, now: Int64) -> Bool {
        guard let accessToken = AuthJWTDecoder.tokenObject(from: authJSON)?["access_token"]?.stringValue,
              let claims = try? AuthJWTDecoder.decodePayload(accessToken),
              let expiration = claims["exp"]?.int64Value else {
            return false
        }
        return expiration <= now
    }

    private static func isExpiredAuthenticationError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("provided authentication token is expired")
            || message.contains("token_expired")
            || message.contains("refresh token has already been used")
            || message.contains("signing in again")
    }

    private static func userFacingUsageErrorMessage(for error: Error) -> String {
        if isExpiredAuthenticationError(error) {
            return L10n.tr("error.accounts.sign_in_expired")
        }
        return error.localizedDescription
    }

    private static func persistCurrentAuthIfNeeded(
        refreshedAccount: StoredAccount,
        in store: AccountsStore,
        authRepository: AuthRepository
    ) throws {
        guard store.currentAccountID == refreshedAccount.id else {
            return
        }
        try authRepository.writeCurrentAuth(refreshedAccount.authJSON)
    }

    private static func reconcileStoredAccountMetadata(
        in store: inout AccountsStore,
        authRepository: AuthRepository
    ) -> Bool {
        var didChange = false

        for index in store.accounts.indices {
            let storedAccount = store.accounts[index]
            guard let reconciled = try? authRepository.extractAuth(from: storedAccount.authJSON) else {
                continue
            }
            if store.accounts[index].email != reconciled.email {
                store.accounts[index].email = reconciled.email
                didChange = true
            }

            if store.accounts[index].principalID != reconciled.principalID {
                store.accounts[index].principalID = reconciled.principalID
                didChange = true
            }

            if store.accounts[index].planType != reconciled.planType {
                store.accounts[index].planType = reconciled.planType
                didChange = true
            }

            let reconciledTeamName = WorkspaceDisplayName.normalized(from: reconciled.teamName)
            let storedTeamName = WorkspaceDisplayName.normalized(from: store.accounts[index].teamName)
            if let reconciledTeamName, storedTeamName != reconciledTeamName {
                store.accounts[index].teamName = reconciledTeamName
                didChange = true
            }

        }

        if let currentAccountID = store.currentAccountID,
           !store.accounts.contains(where: { $0.id == currentAccountID }) {
            store.currentAccountID = nil
            didChange = true
        }

        return didChange
    }

    private static func remoteWorkspaceName(
        for accountID: String,
        in metadata: [WorkspaceMetadata]
    ) -> String? {
        remoteWorkspaceSnapshot(for: accountID, in: metadata)?.name
    }

    private static func remoteWorkspaceSnapshot(
        for accountID: String,
        in metadata: [WorkspaceMetadata]
    ) -> (name: String?, status: AccountWorkspaceStatus)? {
        guard let match = metadata.first(where: {
            AccountIdentity.normalizedAccountID($0.accountID) == AccountIdentity.normalizedAccountID(accountID)
        }) else {
            return nil
        }

        let trimmedName = WorkspaceDisplayName.normalized(from: match.workspaceName)
        if workspaceMetadataRepresentsInactiveWorkspace(match) {
            return (trimmedName, .deactivated)
        }

        guard let visibleName = visibleWorkspaceName(for: match) else {
            return nil
        }

        return (visibleName, .active)
    }

    private static func visibleWorkspaceName(for metadata: WorkspaceMetadata) -> String? {
        if workspaceMetadataRepresentsInactiveWorkspace(metadata) || workspaceMetadataIsPersonal(metadata) {
            return nil
        }

        guard let trimmedName = WorkspaceDisplayName.normalized(from: metadata.workspaceName) else {
            return nil
        }

        return trimmedName
    }

    private static func workspaceMetadataRepresentsInactiveWorkspace(_ metadata: WorkspaceMetadata) -> Bool {
        let inactiveKeywords = ["deactivat", "disabl", "archiv", "suspend", "inactive", "deleted"]
        return workspaceMetadataContainsAnyKeyword(metadata, keywords: inactiveKeywords)
    }

    private static func workspaceMetadataIsPersonal(_ metadata: WorkspaceMetadata) -> Bool {
        workspaceMetadataContainsAnyKeyword(metadata, keywords: ["personal"])
    }

    private static func workspaceMetadataContainsAnyKeyword(
        _ metadata: WorkspaceMetadata,
        keywords: [String]
    ) -> Bool {
        let searchableFields = [
            metadata.structure,
            metadata.workspaceName
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        for field in searchableFields where !field.isEmpty {
            if keywords.contains(where: { field.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func workspaceDirectoryKind(for metadata: WorkspaceMetadata) -> WorkspaceDirectoryKind {
        let normalizedStructure = (metadata.structure ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedStructure == "personal" ? .personal : .workspace
    }

    private static func workspaceDirectoryKind(for account: StoredAccount) -> WorkspaceDirectoryKind {
        WorkspaceDisplayName.normalized(from: account.teamName) == nil ? .personal : .workspace
    }

    private func persistConsentWorkspaceDirectory(
        _ workspaces: [ConsentWorkspaceOption],
        authorizedWorkspaceID: String,
        fallbackEmail: String?,
        fallbackPlanType: String?
    ) throws {
        guard !workspaces.isEmpty else { return }

        var store = try storeRepository.loadStore()
        let now = dateProvider.unixSecondsNow()
        let normalizedAuthorizedWorkspaceID = AccountIdentity.normalizedAccountID(authorizedWorkspaceID)
        let authorizedWorkspaceIDs = Set(
            store.accounts
                .filter { $0.displayStatus == .list }
                .map { AccountIdentity.normalizedAccountID($0.accountID) }
        )

        var nextEntriesByID = Dictionary(
            uniqueKeysWithValues: store.workspaceDirectory.compactMap { entry -> (String, WorkspaceDirectoryEntry)? in
                let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(entry.workspaceID)
                guard !normalizedWorkspaceID.isEmpty else { return nil }
                guard entry.source != .consent else { return nil }
                return (normalizedWorkspaceID, entry)
            }
        )

        for workspace in workspaces {
            let normalizedWorkspaceID = AccountIdentity.normalizedAccountID(workspace.workspaceID)
            guard !normalizedWorkspaceID.isEmpty else { continue }

            if normalizedWorkspaceID == normalizedAuthorizedWorkspaceID
                || authorizedWorkspaceIDs.contains(normalizedWorkspaceID) {
                nextEntriesByID.removeValue(forKey: normalizedWorkspaceID)
                continue
            }

            nextEntriesByID[normalizedWorkspaceID] = WorkspaceDirectoryEntry(
                workspaceID: workspace.workspaceID,
                workspaceName: workspace.workspaceName,
                email: fallbackEmail,
                planType: fallbackPlanType,
                kind: workspace.kind,
                source: .consent,
                status: .active,
                visibility: .visible,
                lastSeenAt: now,
                lastStatusCheckedAt: nil
            )
        }

        store.workspaceDirectory = nextEntriesByID.values.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .workspace
            }
            let lhsName = lhs.workspaceName ?? ""
            let rhsName = rhs.workspaceName ?? ""
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
        try storeRepository.saveStore(store)
    }

}
