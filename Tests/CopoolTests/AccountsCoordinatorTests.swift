import XCTest
@testable import Copool

final class AccountsCoordinatorTests: XCTestCase {
    func testAccountsUsageRefreshPlanningTargetsCurrentAndNearResetAccounts() {
        let now: Int64 = 1_763_216_000
        let policy = AccountsUsageRefreshPlanningPolicy(nonCurrentResetLeadTimeSeconds: 60)
        let accounts = [
            makeAccountSummary(
                id: "acct-current",
                accountID: "account-current",
                isCurrent: true,
                usage: makeUsageSnapshot(fetchedAt: now - 300, fiveHourResetAt: now + 600)
            ),
            makeAccountSummary(
                id: "acct-near-reset",
                accountID: "account-near-reset",
                isCurrent: false,
                usage: makeUsageSnapshot(fetchedAt: now - 300, fiveHourResetAt: now + 45)
            ),
            makeAccountSummary(
                id: "acct-idle",
                accountID: "account-idle",
                isCurrent: false,
                usage: makeUsageSnapshot(fetchedAt: now - 300, fiveHourResetAt: now + 600)
            ),
            AccountSummary(
                id: "acct-error",
                label: "acct-error",
                email: "error@example.com",
                accountID: "account-error",
                planType: "pro",
                teamName: nil,
                teamAlias: nil,
                addedAt: now,
                updatedAt: now,
                usage: makeUsageSnapshot(fetchedAt: now - 300, fiveHourResetAt: now + 600),
                usageError: "timeout",
                isCurrent: false
            )
        ]

        XCTAssertEqual(
            policy.targetAccountIDs(from: accounts, now: now),
            ["acct-current", "acct-near-reset", "acct-error"]
        )
    }

    func testAccountsUsageRefreshPlanningTargetsNonCurrentAccountsJustAfterReset() {
        let now: Int64 = 1_763_216_000
        let policy = AccountsUsageRefreshPlanningPolicy(nonCurrentResetLeadTimeSeconds: 60)
        let accounts = [
            makeAccountSummary(
                id: "acct-current",
                accountID: "account-current",
                isCurrent: true,
                usage: makeUsageSnapshot(fetchedAt: now - 300, fiveHourResetAt: now + 600)
            ),
            makeAccountSummary(
                id: "acct-post-reset",
                accountID: "account-post-reset",
                isCurrent: false,
                usage: makeUsageSnapshot(fetchedAt: now - 300, fiveHourResetAt: now - 30)
            ),
            makeAccountSummary(
                id: "acct-stale",
                accountID: "account-stale",
                isCurrent: false,
                usage: makeUsageSnapshot(fetchedAt: now - 300, fiveHourResetAt: now - 600)
            )
        ]

        XCTAssertEqual(
            policy.targetAccountIDs(from: accounts, now: now),
            ["acct-current", "acct-post-reset"]
        )
    }

    func testListAccountsBackfillsWorkspaceNameFromRemoteMetadata() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Team",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testListAccountsKeepsCurrentSelectionWhenReconciledAccountKeyChanges() async throws {
        let now: Int64 = 1_763_216_000
        let selected = StoredAccount(
            id: "acct-selected",
            label: "Selected",
            email: "old-selected@example.com",
            accountID: "workspace-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object(["slot": .string("selected")]),
            addedAt: now,
            updatedAt: now,
            usage: nil,
            usageError: nil
        )
        let other = StoredAccount(
            id: "acct-other",
            label: "Other",
            email: "old-other@example.com",
            accountID: "workspace-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object(["slot": .string("other")]),
            addedAt: now + 1,
            updatedAt: now + 1,
            usage: nil,
            usageError: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [selected, other],
                currentAccountID: selected.id,
                currentSelection: CurrentAccountSelection(
                    cardID: selected.id,
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: ReconciledPrincipalAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts(refreshWorkspaceMetadata: false)

        XCTAssertEqual(accounts.filter(\.isCurrent).map(\.id), ["acct-selected"])
        XCTAssertEqual(
            try storeRepository.loadStore().currentSelection?.cardID,
            accounts.first(where: { $0.id == "acct-selected" })?.id
        )
    }

    func testListAccountsReconcilesStoredWorkspaceMetadataFromAuthJSON() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Test",
                        email: nil,
                        accountID: "account-1",
                        planType: nil,
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.email, "test@example.com")
        XCTAssertEqual(accounts.first?.planType, "pro")
        XCTAssertEqual(accounts.first?.teamName, "workspace-x")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "workspace-x")
    }

    func testListAccountsDoesNotClearStoredWorkspaceNameWhenAuthLacksTeamName() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Test",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testListAccountsSkipsRemoteWorkspaceMetadataLookupWhenStoredWorkspaceNameExists() async throws {
        let now: Int64 = 1_763_216_000
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Team",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()

        XCTAssertEqual(metadataService.callCount, 0)
        XCTAssertEqual(accounts.first?.teamName, "remote-space")
    }

    func testImportCurrentAuthPrefersRemoteWorkspaceMetadata() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let imported = try await coordinator.importCurrentAuthAccount(customLabel: nil)
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(imported.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testForcedRefreshBypassesUsageThrottle() async throws {
        let now: Int64 = 1_763_216_000
        let existingUsage = UsageSnapshot(
            fetchedAt: now,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
            credits: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "Test",
                    email: "test@example.com",
                    accountID: "account-1",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: now,
                    updatedAt: now,
                    usage: existingUsage,
                    usageError: nil
                )
            ],
            currentSelection: nil
        )
        let usageService = CountingUsageService(result: existingUsage)
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.refreshUsage()
        XCTAssertEqual(usageService.callCount, 0)

        _ = try await coordinator.refreshUsage(force: true)
        XCTAssertEqual(usageService.callCount, 1)
    }

    func testRefreshUsagePersistsUsageStateTimestamp() async throws {
        let oldTimestamp: Int64 = 1_763_216_000
        let now: Int64 = oldTimestamp + 300
        let oldUsage = makeUsageSnapshot(fetchedAt: oldTimestamp)
        let newUsage = UsageSnapshot(
            fetchedAt: now,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: now + 300),
            oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: now + 10_000),
            credits: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Test",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["account_id": .string("account-1")]),
                        addedAt: oldTimestamp,
                        updatedAt: oldTimestamp,
                        usage: oldUsage,
                        usageError: nil,
                        usageStateUpdatedAt: oldTimestamp
                    )
                ],
                currentSelection: nil
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(result: newUsage),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.refreshUsage(force: true)

        let savedStore = try storeRepository.loadStore()
        XCTAssertEqual(savedStore.accounts.first?.usage?.fiveHour?.usedPercent, 100)
        XCTAssertEqual(savedStore.accounts.first?.usageStateUpdatedAt, now)
    }

    func testSelectiveUsageRefreshOnlyRequestsTargetAccounts() async throws {
        let now: Int64 = 1_763_216_000
        let store = AccountsStore(
            version: 1,
            accounts: [
                makeStoredAccount(id: "acct-1", accountID: "account-1", now: now),
                makeStoredAccount(id: "acct-2", accountID: "account-2", now: now),
                makeStoredAccount(id: "acct-3", accountID: "account-3", now: now),
            ],
            currentSelection: nil
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                "account-2": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                "account-3": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
            ]
        )
        let authRepository = MultiAccountAuthRepository(
            extractedByAccountID: [
                "account-1": makeExtractedAuth(accountID: "account-1"),
                "account-2": makeExtractedAuth(accountID: "account-2"),
                "account-3": makeExtractedAuth(accountID: "account-3"),
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.refreshUsage(accountIDs: ["acct-1", "acct-3"], force: true)

        let requestedAccountIDs = await usageService.readRequestedAccountIDs()
        XCTAssertEqual(Set(requestedAccountIDs), Set(["account-1", "account-3"]))
    }

    func testRefreshUsageRefreshesExpiredStoredAuthBeforeFetching() async throws {
        let now: Int64 = 1_763_216_000
        let expiredAccessToken = makeUnsignedJWT(payload: ["exp": now - 60])
        let freshAccessToken = makeUnsignedJWT(payload: ["exp": now + 3_600])
        let expiredAuth = makeTestAuthJSON(accountID: "account-1", accessToken: expiredAccessToken)
        let refreshedAuth = makeTestAuthJSON(accountID: "account-1", accessToken: freshAccessToken)
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Test",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: expiredAuth,
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil
            )
        )
        let usageService = ValidatingUsageService(
            validAccessToken: freshAccessToken,
            result: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
        )
        let authRepository = RefreshingAuthRepository(refreshedAuth: refreshedAuth)
        var settings = AppSettings.defaultValue
        settings.autoSmartSwitch = true
        let settingsRepository = TestSettingsRepository(settings: settings)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: settingsRepository,
            authRepository: authRepository,
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.refreshUsage(force: true)
        let savedStore = try storeRepository.loadStore()
        let requestedTokens = await usageService.readRequestedAccessTokens()

        XCTAssertEqual(authRepository.readRefreshCallCount(), 1)
        XCTAssertEqual(requestedTokens, [freshAccessToken])
        XCTAssertNil(accounts.first?.usageError)
        XCTAssertEqual(
            savedStore.accounts.first?.authJSON["tokens"]?["access_token"]?.stringValue,
            freshAccessToken
        )
    }

    func testRefreshUsageShowsRefreshFailureMessageWhenRefreshTokenIsReused() async throws {
        let now: Int64 = 1_763_216_000
        let expiredAccessToken = makeUnsignedJWT(payload: ["exp": now - 60])
        let expiredAuth = makeTestAuthJSON(accountID: "account-1", accessToken: expiredAccessToken)
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Test",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: expiredAuth,
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil
            )
        )
        let usageService = ValidatingUsageService(
            validAccessToken: "unused",
            result: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
        )
        let message = "Your refresh token has already been used to generate a new access token. Please try signing in again."
        let authRepository = FailingRefreshingAuthRepository(message: message)
        var settings = AppSettings.defaultValue
        settings.autoSmartSwitch = true
        let settingsRepository = TestSettingsRepository(settings: settings)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: settingsRepository,
            authRepository: authRepository,
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.refreshUsage(force: true)
        let requestedTokens = await usageService.readRequestedAccessTokens()

        XCTAssertEqual(authRepository.readRefreshCallCount(), 1)
        XCTAssertEqual(requestedTokens, [])
        XCTAssertEqual(accounts.first?.usageError, L10n.tr("error.accounts.sign_in_expired"))
    }

    func testAddAccountViaLoginOnIOSSkipsUsageFetchAndImportsSingleCurrentAccount() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let usageService = ValidatingUsageService(
            validAccessToken: "unused",
            result: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
        )
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: usageService,
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: FixedChatGPTOAuthLoginService(
                tokens: ChatGPTOAuthTokens(
                    accessToken: "token-1",
                    refreshToken: "refresh-1",
                    idToken: "id-1",
                    apiKey: nil
                )
            ),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now),
            runtimePlatform: .iOS
        )

        let imported = try await coordinator.addAccountViaLogin(customLabel: nil)
        let requestedTokens = await usageService.readRequestedAccessTokens()
        let accounts = try await coordinator.listAccounts()

        XCTAssertEqual(imported.accountID, "account-1")
        XCTAssertNil(imported.teamName)
        XCTAssertEqual(requestedTokens, [])
        XCTAssertEqual(metadataService.callCount, 1)
        XCTAssertEqual(accounts.map(\.accountID), ["account-1"])
        XCTAssertEqual(accounts.map(\.teamName), ["remote-space"])
    }

    func testAddAccountViaLoginOnMacOSImportsSingleCurrentAccount() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
            ]
        )
        let metadataService = StubWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: usageService,
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: FixedChatGPTOAuthLoginService(
                tokens: ChatGPTOAuthTokens(
                    accessToken: "token-1",
                    refreshToken: "refresh-1",
                    idToken: "id-1",
                    apiKey: nil
                )
            ),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.addAccountViaLogin(customLabel: nil)

        let accounts = try await coordinator.listAccounts()
        let requestedAccountIDs = await usageService.readRequestedAccountIDs()
        XCTAssertEqual(accounts.map(\.accountID), ["account-1"])
        XCTAssertEqual(accounts.map(\.teamName), ["remote-space"])
        XCTAssertEqual(requestedAccountIDs, ["account-1"])
    }

    func testAddAccountViaLoginReimportsCurrentAccountWithoutCreatingDuplicates() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
            ]
        )
        let metadataService = StubWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: usageService,
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: FixedChatGPTOAuthLoginService(
                tokens: ChatGPTOAuthTokens(
                    accessToken: "token-1",
                    refreshToken: "refresh-1",
                    idToken: "id-1",
                    apiKey: nil
                )
            ),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.addAccountViaLogin(customLabel: nil)
        _ = try await coordinator.addAccountViaLogin(customLabel: nil)

        let accounts = try await coordinator.listAccounts()
        let requestedAccountIDs = await usageService.readRequestedAccountIDs()
        XCTAssertEqual(accounts.map(\.accountID), ["account-1"])
        XCTAssertEqual(accounts.map(\.teamName), ["remote-space"])
        XCTAssertEqual(requestedAccountIDs, ["account-1", "account-1"])
    }

    func testListAccountsIgnoresDeactivatedRemoteWorkspaceName() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Team",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "Deactivated Workspace", structure: "workspace")]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()

        XCTAssertEqual(accounts.first?.teamName, "Deactivated Workspace")
        XCTAssertEqual(accounts.first?.workspaceStatus, .deactivated)
    }

    func testAuthorizeWorkspaceViaLoginImportsSpecificWorkspace() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let loginService = RecordingWorkspaceAwareChatGPTOAuthLoginService(
            defaultTokens: ChatGPTOAuthTokens(
                accessToken: "token-1",
                refreshToken: "refresh-1",
                idToken: "id-1",
                apiKey: nil
            ),
            tokensByWorkspaceID: [
                "account-2": ChatGPTOAuthTokens(
                    accessToken: "token-2",
                    refreshToken: "refresh-2",
                    idToken: "id-2",
                    apiKey: nil
                )
            ]
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-2": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-2": makeExtractedAuth(
                        accountID: "account-2",
                        planType: "team",
                        teamName: nil
                    )
                ]
            ),
            usageService: usageService,
            workspaceMetadataService: StubWorkspaceMetadataService(metadata: []),
            chatGPTOAuthLoginService: loginService,
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let imported = try await coordinator.authorizeWorkspaceViaLogin(
            workspaceID: "account-2",
            workspaceName: "ops-space",
            customLabel: nil
        )

        let accounts = try await coordinator.listAccounts()
        let forcedWorkspaceIDs = await loginService.readForcedWorkspaceIDs()

        XCTAssertEqual(imported.accountID, "account-2")
        XCTAssertEqual(imported.teamName, "ops-space")
        XCTAssertEqual(accounts.map { $0.accountID }, ["account-2"])
        XCTAssertEqual(accounts.map { $0.teamName }, ["workspace-account-2"])
        XCTAssertEqual(forcedWorkspaceIDs, ["account-2"])
    }

    func testRefreshUsageOnIOSIsUnavailable() async {
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            runtimePlatform: .iOS
        )

        do {
            _ = try await coordinator.refreshUsage(force: true)
            XCTFail("Expected iOS refresh usage to be unavailable")
        } catch {
            XCTAssertEqual(error.localizedDescription, PlatformCapabilities.unsupportedOperationMessage)
        }
    }

    func testRefreshAllUsageDoesNotClearStoredWorkspaceNameWhenAuthLacksTeamName() async throws {
        let now: Int64 = 1_763_216_000
        let existingUsage = UsageSnapshot(
            fetchedAt: now - 60,
            planType: "team",
            fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
            oneWeek: nil,
            credits: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "Test",
                    email: "test@example.com",
                    accountID: "account-1",
                    planType: "team",
                    teamName: "remote-space",
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: now,
                    updatedAt: now,
                    usage: existingUsage,
                    usageError: nil
                )
            ],
            currentSelection: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(store: store)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.refreshUsage(force: true)
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testRefreshAllUsageDoesNotBlockOnWorkspaceMetadataLookup() async throws {
        let now: Int64 = 1_763_216_000
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "Test",
                    email: nil,
                    accountID: "account-1",
                    planType: nil,
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: now,
                    updatedAt: now,
                    usage: nil,
                    usageError: nil
                )
            ],
            currentSelection: nil
        )
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.refreshUsage(force: true)

        XCTAssertEqual(metadataService.callCount, 0)
        XCTAssertNil(accounts.first?.teamName)

        let enrichedAccounts = try await coordinator.refreshWorkspaceMetadata(forceRemoteCheck: true)
        XCTAssertEqual(metadataService.callCount, 1)
        XCTAssertEqual(enrichedAccounts.first?.teamName, "remote-space")
    }

    func testRefreshAllUsageSeriallyStreamsPartialAccountUpdates() async throws {
        let now: Int64 = 1_763_216_000
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "First",
                    email: "first@example.com",
                    accountID: "account-1",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object(["account_id": .string("account-1")]),
                    addedAt: now,
                    updatedAt: now,
                    usage: nil,
                    usageError: nil
                ),
                StoredAccount(
                    id: "acct-2",
                    label: "Second",
                    email: "second@example.com",
                    accountID: "account-2",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object(["account_id": .string("account-2")]),
                    addedAt: now,
                    updatedAt: now,
                    usage: nil,
                    usageError: nil
                )
            ],
            currentSelection: nil
        )
        let usageService = AccountIDUsageService(
            results: [
                "account-1": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: nil,
                    credits: nil
                ),
                "account-2": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 80, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: nil,
                    credits: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-1",
                        email: "first@example.com",
                        planType: "pro",
                        teamName: nil
                    ),
                    "account-2": ExtractedAuth(
                        accountID: "account-2",
                        accessToken: "token-2",
                        email: "second@example.com",
                        planType: "pro",
                        teamName: nil
                    )
                ]
            ),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let recorder = PartialUpdateRecorder()
        let accounts = try await coordinator.refreshUsage(
            force: true,
            serial: true,
            onPartialUpdate: { accounts in
                await recorder.record(accounts)
            }
        )
        let partialUpdates = await recorder.values()

        XCTAssertEqual(partialUpdates.count, 2)
        XCTAssertEqual(partialUpdates.first?.count, 2)
        XCTAssertNotNil(partialUpdates.first?[0].usage)
        XCTAssertNil(partialUpdates.first?[1].usage)
        XCTAssertNotNil(partialUpdates.last?[0].usage)
        XCTAssertNotNil(partialUpdates.last?[1].usage)
        XCTAssertEqual(accounts, partialUpdates.last)
    }

    func testSwitchAccountOnIOSUpdatesAuthButSkipsMacOnlySideEffects() async throws {
        let now: Int64 = 1_763_216_000
        let account = StoredAccount(
            id: "acct-1",
            label: "Test",
            email: "test@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: now,
            updatedAt: now,
            usage: nil,
            usageError: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [account],
            currentSelection: nil
        )
        let codexService = RecordingCodexCLIService()
        let editorService = RecordingEditorAppService()
        let authRepository = RecordingAuthRepository()
        let storeRepository = InMemoryAccountsStoreRepository(store: store)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(settings: AppSettings(
                launchAtStartup: false,
                launchCodexAfterSwitch: true,
                autoSmartSwitch: false,
                syncOpencodeOpenaiAuth: false,
                restartEditorsOnSwitch: true,
                restartEditorTargets: [.cursor],
                autoStartApiProxy: false,
                remoteServers: [],
                locale: AppLocale.english.identifier
            )),
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 0, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 0, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: codexService,
            editorAppService: editorService,
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now),
            runtimePlatform: .iOS
        )

        _ = try await coordinator.switchAccountAndApplySettings(id: account.id)

        XCTAssertEqual(authRepository.writtenAccountCount, 1)
        XCTAssertEqual(codexService.launchCallCount, 0)
        XCTAssertEqual(editorService.restartCallCount, 0)
        XCTAssertEqual(try storeRepository.loadStore().currentSelection?.cardID, account.id)
    }

    func testSwitchAccountWritesCurrentAccountIDToStore() async throws {
        let now: Int64 = 1_763_216_000
        let first = makeStoredAccount(id: "acct-1", accountID: "account-1", now: now)
        let second = makeStoredAccount(id: "acct-2", accountID: "account-2", now: now + 1)
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [first, second],
                currentAccountID: first.id,
                currentSelection: CurrentAccountSelection(
                    cardID: first.id,
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1"),
                    "account-2": makeExtractedAuth(accountID: "account-2")
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.switchAccountAndApplySettings(id: second.id)

        XCTAssertEqual(try storeRepository.loadStore().currentAccountID, second.id)
    }

    func testAutoSmartSwitchReturnsCurrentAccountAfterSwitch() async throws {
        let now: Int64 = 1_763_216_000
        var first = makeStoredAccount(id: "acct-1", accountID: "account-1", now: now)
        first.usage = UsageSnapshot(
            fetchedAt: now,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: nil),
            credits: nil
        )
        var second = makeStoredAccount(id: "acct-2", accountID: "account-2", now: now + 1)
        second.usage = UsageSnapshot(
            fetchedAt: now,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
            credits: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [first, second],
                currentAccountID: first.id,
                currentSelection: CurrentAccountSelection(
                    cardID: first.id,
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1"),
                    "account-2": makeExtractedAuth(accountID: "account-2")
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let result = try await coordinator.autoSmartSwitchIfNeeded()

        XCTAssertEqual(result?.selectedAccount.id, second.id)
        XCTAssertEqual(result?.selectedAccount.isCurrent, true)
    }

    func testAutoSmartSwitchUsesSelectedCardWhenAccountsShareIdentity() async throws {
        let now: Int64 = 1_763_216_000
        let first = StoredAccount(
            id: "acct-1",
            label: "Old Card",
            email: nil,
            accountID: "shared-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([
                "account_id": .string("shared-account"),
                "slot": .string("old")
            ]),
            addedAt: now,
            updatedAt: now,
            usage: UsageSnapshot(
                fetchedAt: now,
                planType: "pro",
                fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            ),
            usageError: nil
        )
        let second = StoredAccount(
            id: "acct-2",
            label: "New Card",
            email: nil,
            accountID: "shared-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([
                "account_id": .string("shared-account"),
                "slot": .string("new")
            ]),
            addedAt: now + 1,
            updatedAt: now + 1,
            usage: UsageSnapshot(
                fetchedAt: now,
                planType: "pro",
                fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            ),
            usageError: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [first, second],
                currentAccountID: first.id,
                currentSelection: CurrentAccountSelection(
                    cardID: first.id,
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let authRepository = RecordingSharedIdentityAuthRepository()
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let result = try await coordinator.autoSmartSwitchIfNeeded()

        XCTAssertEqual(result?.selectedAccount.id, second.id)
        XCTAssertEqual(try storeRepository.loadStore().currentAccountID, second.id)
        XCTAssertEqual(result?.accounts.first(where: \.isCurrent)?.id, second.id)
        XCTAssertEqual(authRepository.writtenSlots, ["new"])
    }

    @MainActor
    func testAccountsPageModelBootstrapsFromInitialAccounts() {
        let account = AccountSummary(
            id: "acct-1",
            label: "Bootstrap",
            email: "bootstrap@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            addedAt: 1,
            updatedAt: 1,
            usage: nil,
            usageError: nil,
            isCurrent: true
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService()
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            onLocalAccountsChanged: nil,
            initialAccounts: [account]
        )

        XCTAssertTrue(model.hasResolvedInitialState)
        XCTAssertEqual(model.state, AccountsPageModel.makeViewState(accounts: [account], cloudSyncAvailable: true))
    }

    @MainActor
    func testAccountsPageModelLoadIfNeededReloadsAfterAlreadyLoadedExternalMutation() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now),
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now + 1)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: AccountIDAwareAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let initialAccounts = try await coordinator.listAccounts(refreshWorkspaceMetadata: false)
        let model = AccountsPageModel(
            coordinator: coordinator,
            initialAccounts: initialAccounts
        )

        await model.loadIfNeeded()
        guard case .content(let firstAccounts) = model.state else {
            return XCTFail("Expected initial accounts content state")
        }
        XCTAssertEqual(firstAccounts.first(where: \.isCurrent)?.accountID, "account-1")

        var mutatedStore = try storeRepository.loadStore()
        mutatedStore.currentSelection = CurrentAccountSelection(
            cardID: "acct-2",
            selectedAt: now * 1_000 + 1,
            sourceDeviceID: "remote-proxy"
        )
        mutatedStore.currentAccountID = "acct-2"
        try storeRepository.saveStore(mutatedStore)

        await model.loadIfNeeded()
        guard case .content(let refreshedAccounts) = model.state else {
            return XCTFail("Expected refreshed accounts content state")
        }
        XCTAssertEqual(refreshedAccounts.first(where: \.isCurrent)?.accountID, "account-2")
    }

    @MainActor
    func testAccountsPageModelRemoteRefreshActivityDoesNotDriveToolbarSpinner() {
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService()
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            manualRefreshService: StubAccountsManualRefreshService()
        )

        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)

        model.syncRemoteUsageRefreshActivity(refreshingAccountIDs: ["acct-1"])
        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)

        model.syncRemoteUsageRefreshActivity(refreshingAccountIDs: [])
        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)
    }


    @MainActor
    func testDeletePendingWorkspaceDoesNotReloadWorkspaceDirectoryAfterPersistingVisibility() async {
        let entry = WorkspaceDirectoryEntry(
            workspaceID: "workspace-1",
            workspaceName: "Workspace 1",
            email: "workspace@example.com",
            planType: "team",
            kind: .workspace,
            source: .consent,
            status: .active,
            visibility: .visible,
            lastSeenAt: 1,
            lastStatusCheckedAt: nil
        )
        let repository = CountingAccountsStoreRepository(
            store: AccountsStore(
                workspaceDirectory: [entry]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: repository,
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService()
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            onLocalAccountsChanged: nil,
            initialAccounts: [
                makeAccountSummary(
                    id: "acct-1",
                    accountID: "account-1",
                    isCurrent: true,
                    usage: nil
                )
            ]
        )
        model.workspaceDirectory = [entry]
        model.pendingWorkspaceAuthorizations = [
            WorkspaceAuthorizationCandidate(
                workspaceID: "workspace-1",
                workspaceName: "Workspace 1",
                email: "workspace@example.com",
                planType: "team"
            )
        ]

        await model.deletePendingWorkspace(id: "workspace-1")

        XCTAssertEqual(repository.loadCount, 1)
        XCTAssertTrue(model.pendingWorkspaceAuthorizations.isEmpty)
        XCTAssertEqual(model.workspaceDirectory.first?.visibility, .deleted)
    }

    @MainActor
    func testDeletePendingWorkspaceCancelsInFlightPendingRefreshBeforeItCanRestoreCard() async {
        let now: Int64 = 1_763_216_000
        let metadataService = ControlledWorkspaceMetadataService(
            resultsByAccessToken: [
                "token-1": [
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "Workspace 2", structure: "workspace")
                ]
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "acct-1",
                            email: "account-1@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "workspace-a",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-1")
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        )
                    ]
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)
        let accounts = [
            makeAccountSummary(
                id: "acct-1",
                accountID: "account-1",
                isCurrent: true,
                usage: nil,
                planType: "team",
                teamName: "workspace-a"
            )
        ]

        model.pendingWorkspaceAuthorizations = [
            WorkspaceAuthorizationCandidate(
                workspaceID: "account-2",
                workspaceName: "Workspace 2",
                email: "account-2@example.com",
                planType: "team"
            )
        ]

        model.schedulePendingWorkspaceRefresh(from: accounts)
        await metadataService.waitForFirstFetchToStart()

        await model.deletePendingWorkspace(id: "account-2")
        await metadataService.resumeFirstFetch()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(model.pendingWorkspaceAuthorizations.isEmpty)
    }

    @MainActor
    func testAccountsPagePresentationDerivesPendingCardsFromUnifiedAccountStatus() {
        let model = makeAccountsPageModelForViewStoreTests(
            initialAccounts: [
                makeAccountSummary(
                    id: "acct-list",
                    accountID: "account-list",
                    isCurrent: true,
                    usage: nil
                ),
                makeAccountSummary(
                    id: "acct-pending",
                    accountID: "account-pending",
                    isCurrent: false,
                    usage: nil,
                    displayStatus: .pending,
                    planType: "team",
                    teamName: "Pending Space"
                ),
                makeAccountSummary(
                    id: "acct-deactivated",
                    accountID: "account-deactivated",
                    isCurrent: false,
                    usage: nil,
                    displayStatus: .deactivated,
                    planType: "team",
                    teamName: "Dead Space"
                ),
                makeAccountSummary(
                    id: "acct-deleted",
                    accountID: "account-deleted",
                    isCurrent: false,
                    usage: nil,
                    displayStatus: .deleted,
                    planType: "team",
                    teamName: "Hidden Space"
                )
            ]
        )

        let contentPresentation = model.makeContentPresentation()

        if case .content(let ids) = contentPresentation.state {
            XCTAssertEqual(ids, ["acct-list"])
        } else {
            XCTFail("Expected content state")
        }
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.id), ["acct-deactivated", "acct-pending"])
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.status), [.deactivated, .pending])
    }

    @MainActor
    func testAccountsPagePresentationHidesPendingSectionOnIOS() {
        let model = makeAccountsPageModelForViewStoreTests(
            runtimePlatform: .iOS,
            initialAccounts: [
                makeAccountSummary(
                    id: "acct-list",
                    accountID: "account-list",
                    isCurrent: true,
                    usage: nil
                ),
                makeAccountSummary(
                    id: "acct-pending",
                    accountID: "account-pending",
                    isCurrent: false,
                    usage: nil,
                    displayStatus: .pending,
                    planType: "team",
                    teamName: "Pending Space"
                ),
                makeAccountSummary(
                    id: "acct-deactivated",
                    accountID: "account-deactivated",
                    isCurrent: false,
                    usage: nil,
                    displayStatus: .deactivated,
                    planType: "team",
                    teamName: "Dead Space"
                )
            ]
        )

        let contentPresentation = model.makeContentPresentation()

        if case .content(let ids) = contentPresentation.state {
            XCTAssertEqual(ids, ["acct-list"])
        } else {
            XCTFail("Expected content state")
        }
        XCTAssertTrue(contentPresentation.pendingWorkspaceCards.isEmpty)
        XCTAssertFalse(contentPresentation.shouldShowPendingWorkspaceSection)
    }

    @MainActor
    func testAccountCardViewStateShowsReauthenticateButtonForExpiredSignIn() {
        let model = makeAccountsPageModelForViewStoreTests(
            initialAccounts: [
                AccountSummary(
                    id: "acct-1",
                    label: "acct-1",
                    email: "account-1@example.com",
                    accountID: "account-1",
                    planType: "team",
                    teamName: "workspace-a",
                    teamAlias: nil,
                    addedAt: 1,
                    updatedAt: 1,
                    usage: nil,
                    usageError: L10n.tr("error.accounts.sign_in_expired"),
                    isCurrent: false
                )
            ]
        )

        let card = model.makeAccountCardViewState(forAccountID: "acct-1")

        XCTAssertEqual(card?.showsReauthenticateButton, true)
    }

    @MainActor
    func testAccountsPageModelManualRefreshShowsSpinnerAndRestoresActionState() async {
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService()
        )

        let started = expectation(description: "manual refresh started")
        let gate = ManualRefreshGate()
        let callCounter = ManualRefreshCallCounter()
        let model = AccountsPageModel(
            coordinator: coordinator,
            manualRefreshService: BlockingAccountsManualRefreshService(
                gate: gate,
                callCounter: callCounter,
                onStart: { started.fulfill() }
            )
        )

        let refreshTask = Task { await model.refreshUsage() }
        await fulfillment(of: [started], timeout: 1.0)

        XCTAssertTrue(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)

        // Toolbar button stays tappable while a refresh is in progress,
        // but refresh action is guarded against concurrent re-entry.
        await model.refreshUsage()
        let callCountDuringRefresh = await callCounter.value
        XCTAssertEqual(callCountDuringRefresh, 1)

        await gate.open()
        _ = await refreshTask.result

        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)
    }

    @MainActor
    func testAccountsPageModelSkipsManualRefreshWhileBackgroundUsageRefreshIsActive() async {
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService()
        )
        let gate = ManualRefreshGate()
        let callCounter = ManualRefreshCallCounter()
        let model = AccountsPageModel(
            coordinator: coordinator,
            manualRefreshService: BlockingAccountsManualRefreshService(
                gate: gate,
                callCounter: callCounter,
                onStart: {}
            )
        )
        model.syncRemoteUsageRefreshActivity(refreshingAccountIDs: ["acct-1"])

        await model.refreshUsage()
        let callCount = await callCounter.value

        XCTAssertEqual(callCount, 0)
        await gate.open()
    }

    @MainActor
    func testAccountsPageModelLocalMutationTriggersImmediateCloudSync() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: "workspace-x",
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService()
        )
        let syncSpy = SpyAccountsLocalMutationSyncService()
        let model = AccountsPageModel(
            coordinator: coordinator,
            localAccountsMutationSyncService: syncSpy,
            onLocalAccountsChanged: { accounts in
                syncSpy.acceptLocalAccountsSnapshot(accounts)
            }
        )

        await model.saveTeamAlias(id: "acct-1", alias: "Renamed")

        for _ in 0..<10 where syncSpy.syncCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(syncSpy.syncCallCount, 1)
        XCTAssertEqual(syncSpy.acceptedSnapshots.last?.first?.teamAlias, "Renamed")
    }

    @MainActor
    func testAccountsPageModelSyncCurrentAccountSelectionShowsNoticeOnFailure() async throws {
        let now: Int64 = 1_763_216_000
        let model = AccountsPageModel(
            coordinator: AccountsCoordinator(
                storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
                settingsRepository: TestSettingsRepository(),
                authRepository: StubAuthRepository(),
                usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
                chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
                codexCLIService: StubCodexCLIService(),
                editorAppService: StubEditorAppService(),
                opencodeAuthSyncService: StubOpencodeAuthSyncService(),
                dateProvider: FixedDateProvider(now: now)
            ),
            currentAccountSelectionSyncService: FailingCurrentAccountSelectionSyncService(message: "selection sync failed")
        )

        await model.syncCurrentAccountSelection(cardID: "acct-1")

        XCTAssertEqual(model.notice?.text, "selection sync failed")
    }

    func testCurrentSelectionSyncDoesNotRewriteLocalStore() async throws {
        let now: Int64 = 1_763_216_000
        let first = makeStoredAccount(id: "acct-1", accountID: "shared-account", now: now)
        let second = makeStoredAccount(id: "acct-2", accountID: "shared-account", now: now + 1)
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [first, second],
                currentAccountID: first.id,
                currentSelection: CurrentAccountSelection(
                    cardID: first.id,
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let service = CloudKitCurrentAccountSelectionSyncService(
            storeRepository: storeRepository,
            authRepository: StubAuthRepository(),
            dateProvider: FixedDateProvider(now: now)
        )

        try await service.recordLocalSelection(cardID: second.id)

        let store = try storeRepository.loadStore()
        XCTAssertEqual(store.currentAccountID, first.id)
        XCTAssertEqual(store.currentSelection?.cardID, first.id)
    }

    @MainActor
    func testAccountsPageModelManualRefreshReloadsAccountsFromStore() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now)
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1"),
                    "account-2": makeExtractedAuth(accountID: "account-2")
                ]
            ),
            usageService: RecordingAccountUsageService(
                results: [
                    "account-2": makeUsageSnapshot(fetchedAt: now + 30, fiveHourResetAt: now + 600)
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            manualRefreshService: StoreUpdatingAccountsManualRefreshService(
                storeRepository: storeRepository,
                refreshedAccounts: [
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now + 30)
                ]
            )
        )

        await model.load()
        await model.refreshUsage()

        guard case .content(let accounts) = model.state else {
            return XCTFail("Expected refreshed accounts content state")
        }

        XCTAssertEqual(accounts.map(\.accountID), ["account-2"])
    }

    @MainActor
    func testAccountsPageModelReauthenticateExpiredTeamAccountUsesWorkspaceLogin() async throws {
        let now: Int64 = 1_763_216_000
        let loginService = RecordingWorkspaceAwareChatGPTOAuthLoginService(
            defaultTokens: ChatGPTOAuthTokens(
                accessToken: "token-default",
                refreshToken: "refresh-default",
                idToken: "id-default",
                apiKey: nil
            ),
            tokensByWorkspaceID: [
                "account-1": ChatGPTOAuthTokens(
                    accessToken: "token-new",
                    refreshToken: "refresh-new",
                    idToken: "id-new",
                    apiKey: nil
                )
            ]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "account-1@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "tokens": .object([
                                "access_token": .string("token-old")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: L10n.tr("error.accounts.sign_in_expired")
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-old": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-old",
                        email: "account-1@example.com",
                        planType: "team",
                        teamName: "workspace-a"
                    ),
                    "token-new": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-new",
                        email: "account-1@example.com",
                        planType: "team",
                        teamName: "workspace-a"
                    )
                ]
            ),
            usageService: ValidatingUsageService(
                validAccessToken: "token-new",
                result: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: loginService,
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        await model.reauthenticateAccount(id: "acct-1")

        let savedStore = try storeRepository.loadStore()
        let forcedWorkspaceIDs = await loginService.readForcedWorkspaceIDs()

        XCTAssertEqual(forcedWorkspaceIDs, ["account-1"])
        XCTAssertEqual(savedStore.accounts.first?.usageError, nil)
        XCTAssertEqual(savedStore.accounts.first?.authJSON["tokens"]?["access_token"]?.stringValue, "token-new")
    }

    @MainActor
    func testDeleteDeactivatedPendingAccountMarksUnifiedAccountDeleted() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now),
                        usageError: L10n.tr("error.accounts.workspace_deactivated"),
                        workspaceStatus: .deactivated,
                        displayStatus: .deactivated
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        await model.deletePendingWorkspace(id: "acct-1")

        let savedStore = try storeRepository.loadStore()
        XCTAssertEqual(savedStore.accounts.first?.displayStatus, .deleted)
        XCTAssertTrue(model.makeContentPresentation().pendingWorkspaceCards.isEmpty)
        XCTAssertTrue(model.makeAccountCardViewStates().isEmpty)
    }

    @MainActor
    func testAccountsPageLoadHidesDeletedTeamAccounts() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Deleted Team",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil,
                        workspaceStatus: .deactivated,
                        displayStatus: .deleted
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()

        XCTAssertTrue(model.makeAccountCardViewStates().isEmpty)
        XCTAssertTrue(model.makeContentPresentation().pendingWorkspaceCards.isEmpty)
    }

    @MainActor
    func testAccountsPageModelSingleAccountRefreshTargetsOnlyOneAccountAndSyncsMutation() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now),
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now),
                ]
            )
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                "account-2": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 600),
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1"),
                    "account-2": makeExtractedAuth(accountID: "account-2"),
                ]
            ),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let syncSpy = SpyAccountsLocalMutationSyncService()
        let model = AccountsPageModel(
            coordinator: coordinator,
            localAccountsMutationSyncService: syncSpy,
            onLocalAccountsChanged: { accounts in
                syncSpy.acceptLocalAccountsSnapshot(accounts)
            }
        )

        await model.refreshUsage(forAccountID: "acct-2")

        let requestedAccountIDs = await usageService.readRequestedAccountIDs()
        XCTAssertEqual(requestedAccountIDs, ["account-2"])

        for _ in 0..<10 where syncSpy.syncCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(syncSpy.syncCallCount, 1)
        XCTAssertTrue(model.refreshingAccountIDs.isEmpty)
        if case .content(let accounts) = model.state {
            XCTAssertEqual(accounts.count, 2)
            XCTAssertNil(accounts.first(where: { $0.id == "acct-1" })?.usage)
            XCTAssertNotNil(accounts.first(where: { $0.id == "acct-2" })?.usage)
        } else {
            XCTFail("Expected refreshed accounts content state")
        }
    }

    @MainActor
    func testAccountsPageModelRefreshUsageOnIOSShowsUnsupportedNotice() async {
        let usageService = RecordingAccountUsageService(results: [:])
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            runtimePlatform: .iOS
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            runtimePlatform: .iOS
        )

        await model.refreshUsage()

        let requestedAccountIDs = await usageService.readRequestedAccountIDs()
        XCTAssertEqual(requestedAccountIDs, [])
        XCTAssertEqual(model.notice?.text, PlatformCapabilities.unsupportedOperationMessage)
    }

    @MainActor
    func testAccountsPageModelRefreshUsageOnIOSEnqueuesRemoteRefreshCommand() async throws {
        let cloudSyncService = RecordingProxyControlCloudSyncService()
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: RecordingAccountUsageService(results: [:]),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            runtimePlatform: .iOS
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            proxyControlCloudSyncService: cloudSyncService,
            runtimePlatform: .iOS
        )

        await model.refreshUsage()

        let commands = await cloudSyncService.readEnqueuedCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.kind, .refreshAccounts)
        XCTAssertEqual(model.notice?.text, L10n.tr("accounts.notice.remote_refresh_requested"))
    }

    @MainActor
    func testAccountsPageModelHidesPerAccountRefreshOnIOS() {
        let account = makeAccountSummary(
            id: "acct-1",
            accountID: "account-1",
            isCurrent: true,
            usage: nil
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            runtimePlatform: .iOS
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            runtimePlatform: .iOS,
            initialAccounts: [account]
        )

        let cards = model.makeAccountCardViewStates()

        XCTAssertEqual(cards.first?.showsRefreshButton, false)
        XCTAssertEqual(model.canRefreshAccount("acct-1"), false)
    }

    @MainActor
    func testAccountsPageModelAddAccountViaLoginPopulatesPendingWorkspaceCardsFromConsentSource() async {
        let now: Int64 = 1_763_216_000
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: AccountIDAwareAuthRepository(),
            usageService: RecordingAccountUsageService(
                results: [
                    "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: FixedChatGPTOAuthLoginService(
                tokens: ChatGPTOAuthTokens(
                    accessToken: "token-1",
                    refreshToken: "refresh-1",
                    idToken: "id-1",
                    apiKey: nil,
                    consentWorkspaces: [
                        ConsentWorkspaceOption(
                            workspaceID: "account-1",
                            workspaceName: "remote-space",
                            kind: .workspace
                        ),
                        ConsentWorkspaceOption(
                            workspaceID: "account-2",
                            workspaceName: "ops-space",
                            kind: .workspace
                        )
                    ]
                )
            ),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.addAccountViaLogin()

        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceName), ["ops-space"])
    }

    @MainActor
    func testAccountsPageModelAddAccountViaLoginPopulatesPendingWorkspaceCardsFromWorkspaceMetadataWhenConsentUnavailable() async {
        let now: Int64 = 1_763_216_000
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: AccountIDAwareAuthRepository(),
            usageService: RecordingAccountUsageService(
                results: [
                    "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: FixedChatGPTOAuthLoginService(
                tokens: ChatGPTOAuthTokens(
                    accessToken: "token-1",
                    refreshToken: "refresh-1",
                    idToken: "id-1",
                    apiKey: nil,
                    consentWorkspaces: []
                )
            ),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.addAccountViaLogin()

        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceName), ["ops-space"])
    }

    @MainActor
    func testAccountsPageModelCancelAddAccountStopsPendingLoginTask() async {
        let loginService = HangingChatGPTOAuthLoginService()
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(metadata: []),
            chatGPTOAuthLoginService: loginService,
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: 1)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        let addTask = Task { await model.addAccountViaLogin() }
        await loginService.waitUntilStarted()
        XCTAssertTrue(model.isAdding)

        model.cancelAddAccount()
        await addTask.value

        XCTAssertFalse(model.isAdding)
        XCTAssertEqual(model.notice?.text, L10n.tr("error.oauth.request_cancelled"))
    }

    @MainActor
    func testAccountsPageModelImportAuthDocumentAddsNewAccountWithoutChangingCurrentSelection() async throws {
        let now: Int64 = 1_763_216_000
        let currentAuth = JSONValue.object([
            "tokens": .object([
                "access_token": .string("token-account-current"),
                "account_id": .string("account-current")
            ])
        ])
        let importedAuth = JSONValue.object([
            "tokens": .object([
                "access_token": .string("token-account-imported"),
                "account_id": .string("account-imported")
            ])
        ])
        let importURL = URL(fileURLWithPath: "/tmp/imported-auth.json")
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-current",
                        label: "Current",
                        email: "current@example.com",
                        accountID: "account-current",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: currentAuth,
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                        usageError: nil
                    )
                ]
            )
        )
        let authRepository = URLMappedAuthRepository(
            currentAuth: currentAuth,
            importedAuthByURL: [importURL: importedAuth],
            extractedByAccessToken: [
                "token-account-current": makeExtractedAuth(accountID: "account-current"),
                "token-account-imported": makeExtractedAuth(accountID: "account-imported")
            ]
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-imported": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 600)
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            usageService: usageService,
            workspaceMetadataService: StubWorkspaceMetadataService(metadata: []),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.importAuthDocument(from: importURL, setAsCurrent: false)

        guard case .content(let accounts) = model.state else {
            return XCTFail("Expected imported accounts content state")
        }
        XCTAssertEqual(accounts.map { $0.accountID }, ["account-current", "account-imported"])
        XCTAssertEqual(model.notice?.text, L10n.tr("accounts.notice.imported_new_format", "account-imported@example.com"))
        XCTAssertEqual(try authRepository.readCurrentAuth(), currentAuth)
    }

    @MainActor
    func testAccountsPageModelImportAuthFileImportsSelectedDocumentWithoutChangingCurrentSelection() async throws {
        let now: Int64 = 1_763_216_000
        let currentAuth = JSONValue.object([
            "tokens": .object([
                "access_token": .string("token-account-current"),
                "account_id": .string("account-current")
            ])
        ])
        let importedAuth = JSONValue.object([
            "tokens": .object([
                "access_token": .string("token-account-imported"),
                "account_id": .string("account-imported")
            ])
        ])
        let importURL = URL(fileURLWithPath: "/tmp/imported-auth.json")
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-current",
                        label: "Current",
                        email: "current@example.com",
                        accountID: "account-current",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: currentAuth,
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                        usageError: nil
                    )
                ]
            )
        )
        let authRepository = URLMappedAuthRepository(
            currentAuth: currentAuth,
            importedAuthByURL: [importURL: importedAuth],
            extractedByAccessToken: [
                "token-account-current": makeExtractedAuth(accountID: "account-current"),
                "token-account-imported": makeExtractedAuth(accountID: "account-imported")
            ]
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-imported": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 600)
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            usageService: usageService,
            workspaceMetadataService: StubWorkspaceMetadataService(metadata: []),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            chooseAuthDocumentURL: { importURL }
        )

        await model.handlePageAction(.importAuthFile)

        guard case .content(let accounts) = model.state else {
            return XCTFail("Expected imported accounts content state")
        }
        XCTAssertEqual(accounts.map { $0.accountID }, ["account-current", "account-imported"])
        XCTAssertEqual(model.notice?.text, L10n.tr("accounts.notice.imported_new_format", "account-imported@example.com"))
        XCTAssertEqual(try authRepository.readCurrentAuth(), currentAuth)
    }

    @MainActor
    func testAccountsPageModelAuthorizePendingWorkspaceImportsAndClearsCandidate() async {
        let now: Int64 = 1_763_216_000
        let loginService = RecordingWorkspaceAwareChatGPTOAuthLoginService(
            defaultTokens: ChatGPTOAuthTokens(
                accessToken: "token-1",
                refreshToken: "refresh-1",
                idToken: "id-1",
                apiKey: nil
            ),
            tokensByWorkspaceID: [
                "account-2": ChatGPTOAuthTokens(
                    accessToken: "token-2",
                    refreshToken: "refresh-2",
                    idToken: "id-2",
                    apiKey: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "Current",
                            email: "test@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "remote-space",
                            teamAlias: nil,
                            authJSON: .object([
                                "tokens": .object([
                                    "access_token": .string("token-1"),
                                    "account_id": .string("account-1")
                                ])
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                            usageError: nil
                        )
                    ],
                    workspaceDirectory: [
                        WorkspaceDirectoryEntry(
                            workspaceID: "account-2",
                            workspaceName: "ops-space",
                            email: "test@example.com",
                            planType: "team",
                            kind: .workspace,
                            source: .consent,
                            status: .active,
                            visibility: .visible,
                            lastSeenAt: now,
                            lastStatusCheckedAt: nil
                        )
                    ]
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil),
                    "token-2": makeExtractedAuth(accountID: "account-2", planType: "team", teamName: nil)
                ]
            ),
            usageService: RecordingAccountUsageService(
                results: [
                    "account-2": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 600)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: loginService,
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map { $0.workspaceID }, ["account-2"])

        await model.authorizePendingWorkspace(id: "account-2")

        let accounts = try? await coordinator.listAccounts()
        let forcedWorkspaceIDs = await loginService.readForcedWorkspaceIDs()
        XCTAssertEqual(accounts?.map { $0.accountID }, ["account-1", "account-2"])
        XCTAssertTrue(model.pendingWorkspaceAuthorizations.isEmpty)
        XCTAssertEqual(forcedWorkspaceIDs, ["account-2"])
    }

    @MainActor
    func testAccountsPageModelCancelPendingWorkspaceAuthorizationStopsPendingLoginTask() async {
        let now: Int64 = 1_763_216_000
        let loginService = HangingChatGPTOAuthLoginService()
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "Current",
                            email: "test@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "remote-space",
                            teamAlias: nil,
                            authJSON: .object([
                                "tokens": .object([
                                    "access_token": .string("token-1"),
                                    "account_id": .string("account-1")
                                ])
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                            usageError: nil
                        )
                    ],
                    workspaceDirectory: [
                        WorkspaceDirectoryEntry(
                            workspaceID: "account-2",
                            workspaceName: "ops-space",
                            email: "test@example.com",
                            planType: "team",
                            kind: .workspace,
                            source: .consent,
                            status: .active,
                            visibility: .visible,
                            lastSeenAt: now,
                            lastStatusCheckedAt: nil
                        )
                    ]
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil)
                ]
            ),
            usageService: RecordingAccountUsageService(results: [:]),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: loginService,
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])

        let authorizationTask = Task { await model.authorizePendingWorkspace(id: "account-2") }
        await loginService.waitUntilStarted()
        XCTAssertEqual(model.authorizingWorkspaceID, "account-2")

        model.cancelPendingWorkspaceAuthorization()
        await authorizationTask.value

        XCTAssertNil(model.authorizingWorkspaceID)
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])
        XCTAssertEqual(model.notice?.text, L10n.tr("error.oauth.request_cancelled"))
    }

    @MainActor
    func testAccountsPageModelPendingWorkspaceDiscoveryShowsErrorWhenMetadataLookupFails() async {
        let now: Int64 = 1_763_216_000
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "acct-1",
                            email: "account-1@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "workspace-a",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-1"),
                                "tokens": .object([
                                    "access_token": .string("token-1")
                                ])
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        )
                    ]
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: RecordingAccountUsageService(
                results: [
                    "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
                ]
            ),
            workspaceMetadataService: ThrowingWorkspaceMetadataService(
                error: AppError.unauthorized("Provided authentication token is expired. Please try signing in again.")
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()

        XCTAssertTrue(model.pendingWorkspaceAuthorizations.isEmpty)
        XCTAssertEqual(
            model.pendingWorkspaceAuthorizationError,
            "Provided authentication token is expired. Please try signing in again."
        )
    }

    @MainActor
    func testAddAccountViaLoginImportsAccountWhenWorkspaceMetadataLookupFails() async {
        let now: Int64 = 1_763_216_000
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: AccountIDAwareAuthRepository(),
            usageService: RecordingAccountUsageService(
                results: [
                    "account-1": makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300)
                ]
            ),
            workspaceMetadataService: ThrowingWorkspaceMetadataService(
                error: AppError.unauthorized("workspace metadata failed")
            ),
            chatGPTOAuthLoginService: FixedChatGPTOAuthLoginService(
                tokens: ChatGPTOAuthTokens(
                    accessToken: "token-1",
                    refreshToken: "refresh-1",
                    idToken: "id-1",
                    apiKey: nil
                )
            ),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.addAccountViaLogin()

        let accounts = try? await coordinator.listAccounts()
        XCTAssertEqual(accounts?.map(\.accountID), ["account-1"])
        XCTAssertNil(accounts?.first?.teamName)
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(model.pendingWorkspaceAuthorizationError, "workspace metadata failed")
    }

    @MainActor
    func testAccountsPageModelAuthorizePendingWorkspaceKeepsCandidateWhenWorkspaceIsDeactivated() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Current",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "tokens": .object([
                                "access_token": .string("token-1"),
                                "account_id": .string("account-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                        usageError: nil
                    )
                ],
                workspaceDirectory: [
                    WorkspaceDirectoryEntry(
                        workspaceID: "account-2",
                        workspaceName: "ops-space",
                        email: "test@example.com",
                        planType: "team",
                        kind: .workspace,
                        source: .consent,
                        status: .active,
                        visibility: .visible,
                        lastSeenAt: now,
                        lastStatusCheckedAt: nil
                    )
                ]
            )
        )
        let loginService = RecordingWorkspaceAwareChatGPTOAuthLoginService(
            defaultTokens: ChatGPTOAuthTokens(
                accessToken: "token-1",
                refreshToken: "refresh-1",
                idToken: "id-1",
                apiKey: nil
            ),
            tokensByWorkspaceID: [
                "account-2": ChatGPTOAuthTokens(
                    accessToken: "token-2",
                    refreshToken: "refresh-2",
                    idToken: "id-2",
                    apiKey: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil),
                    "token-2": makeExtractedAuth(accountID: "account-2", planType: nil, teamName: nil)
                ]
            ),
            usageService: SequencedAccountUsageService(
                resultsByAccountID: [
                    "account-1": [.success(makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300))],
                    "account-2": [
                        .failure(AppError.network("{\"detail\":{\"code\":\"deactivated_workspace\"}}"))
                    ]
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: loginService,
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])

        await model.authorizePendingWorkspace(id: "account-2")

        let accounts = try? await coordinator.listAccounts()
        let contentPresentation = model.makeContentPresentation()
        XCTAssertEqual(accounts?.map(\.accountID), ["account-1"])
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.status), [.deactivated])
        XCTAssertEqual(model.notice?.text, L10n.tr("error.accounts.workspace_deactivated"))
    }

    @MainActor
    func testAccountsPageModelAuthorizePendingWorkspaceKeepsCandidateWhenWorkspaceUsesTypedDeactivatedError() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Current",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "tokens": .object([
                                "access_token": .string("token-1"),
                                "account_id": .string("account-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300),
                        usageError: nil
                    )
                ],
                workspaceDirectory: [
                    WorkspaceDirectoryEntry(
                        workspaceID: "account-2",
                        workspaceName: "ops-space",
                        email: "test@example.com",
                        planType: "team",
                        kind: .workspace,
                        source: .consent,
                        status: .active,
                        visibility: .visible,
                        lastSeenAt: now,
                        lastStatusCheckedAt: nil
                    )
                ]
            )
        )
        let loginService = RecordingWorkspaceAwareChatGPTOAuthLoginService(
            defaultTokens: ChatGPTOAuthTokens(
                accessToken: "token-1",
                refreshToken: "refresh-1",
                idToken: "id-1",
                apiKey: nil
            ),
            tokensByWorkspaceID: [
                "account-2": ChatGPTOAuthTokens(
                    accessToken: "token-2",
                    refreshToken: "refresh-2",
                    idToken: "id-2",
                    apiKey: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil),
                    "token-2": makeExtractedAuth(accountID: "account-2", planType: nil, teamName: nil)
                ]
            ),
            usageService: SequencedAccountUsageService(
                resultsByAccountID: [
                    "account-1": [.success(makeUsageSnapshot(fetchedAt: now, fiveHourResetAt: now + 300))],
                    "account-2": [
                        .failure(AppError.workspaceDeactivated)
                    ]
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: loginService,
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])

        await model.authorizePendingWorkspace(id: "account-2")

        let accounts = try? await coordinator.listAccounts()
        let contentPresentation = model.makeContentPresentation()
        XCTAssertEqual(accounts?.map(\.accountID), ["account-1"])
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.status), [.deactivated])
        XCTAssertEqual(model.notice?.text, L10n.tr("error.accounts.workspace_deactivated"))
    }

    @MainActor
    func testAccountsPageModelRefreshUsageMovesDeactivatedAccountIntoPendingSection() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now),
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: ThrowingUsageService(
                error: AppError.network("{\"detail\":{\"code\":\"deactivated_workspace\"}}")
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.makeAccountCardViewStates().map(\.id), ["acct-1"])
        XCTAssertTrue(model.makeContentPresentation().pendingWorkspaceCards.isEmpty)

        await model.refreshUsage(forAccountID: "acct-1")

        let contentPresentation = model.makeContentPresentation()
        XCTAssertTrue(model.makeAccountCardViewStates().isEmpty)
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.id), ["acct-1"])
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.status), [.deactivated])
        if case .content(let ids) = contentPresentation.state {
            XCTAssertTrue(ids.isEmpty)
        } else {
            XCTFail("Expected content state after moving deactivated account into pending section")
        }
    }

    @MainActor
    func testPendingWorkspaceCardRulesSortDeactivatedBeforeNameOrder() {
        let cards = [
            PendingWorkspaceAuthorizationCardViewState(
                id: "pending-z",
                workspaceID: "workspace-z",
                workspaceName: "Zulu",
                email: nil,
                planType: "team",
                status: .pending,
                authorizing: false
            ),
            PendingWorkspaceAuthorizationCardViewState(
                id: "deactivated-b",
                workspaceID: "workspace-b",
                workspaceName: "Beta",
                email: nil,
                planType: "team",
                status: .deactivated,
                authorizing: false
            ),
            PendingWorkspaceAuthorizationCardViewState(
                id: "pending-a",
                workspaceID: "workspace-a",
                workspaceName: "Alpha",
                email: nil,
                planType: "team",
                status: .pending,
                authorizing: false
            )
        ]

        XCTAssertEqual(
            PendingWorkspaceCardRules.sortedForDisplay(cards).map(\.id),
            ["deactivated-b", "pending-a", "pending-z"]
        )
    }

    @MainActor
    func testAccountsPageModelRefreshUsageMovesDeactivatedAccountIntoPendingSectionForTypedError() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now),
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: ThrowingUsageService(error: AppError.workspaceDeactivated),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.makeAccountCardViewStates().map(\.id), ["acct-1"])
        XCTAssertTrue(model.makeContentPresentation().pendingWorkspaceCards.isEmpty)

        await model.refreshUsage(forAccountID: "acct-1")

        let contentPresentation = model.makeContentPresentation()
        XCTAssertTrue(model.makeAccountCardViewStates().isEmpty)
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.id), ["acct-1"])
        XCTAssertEqual(contentPresentation.pendingWorkspaceCards.map(\.status), [.deactivated])
        if case .content(let ids) = contentPresentation.state {
            XCTAssertTrue(ids.isEmpty)
        } else {
            XCTFail("Expected content state after moving deactivated account into pending section")
        }
    }

    @MainActor
    func testAccountsPageModelDeletePendingWorkspaceMarksDeactivatedAccountDeleted() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now),
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: ThrowingUsageService(
                error: AppError.network("{\"detail\":{\"code\":\"deactivated_workspace\"}}")
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        await model.refreshUsage(forAccountID: "acct-1")
        XCTAssertEqual(model.makeContentPresentation().pendingWorkspaceCards.map(\.id), ["acct-1"])

        await model.deletePendingWorkspace(id: "acct-1")

        let accounts = try? await coordinator.listAccounts()
        XCTAssertEqual(accounts?.map(\.displayStatus), [.deleted])
        XCTAssertTrue(model.makeContentPresentation().pendingWorkspaceCards.isEmpty)
    }

    @MainActor
    func testAccountsPageModelLoadShowsOnlyUnauthorizedWorkspaceCandidatesFromWorkspaceDirectory() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now),
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: AccountIDMappedResultUsageService(
                resultsByAccountID: [
                    "account-1": .success(makeUsageSnapshot(fetchedAt: now)),
                    "account-2": .success(makeUsageSnapshot(fetchedAt: now)),
                    "account-3": .failure(AppError.workspaceDeactivated)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "workspace-b", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-3", workspaceName: "workspace-c", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()

        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2", "account-3"])
        XCTAssertEqual(model.makeContentPresentation().pendingWorkspaceCards.map(\.id), ["account-2", "account-3"])
    }

    @MainActor
    func testAccountsPageModelLoadDoesNotMoveAuthCardIntoPendingSectionWithoutStoredDeactivatedDirectoryEntry() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now),
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: AccountIDMappedResultUsageService(
                resultsByAccountID: [
                    "account-1": .failure(AppError.workspaceDeactivated)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()

        XCTAssertEqual(model.makeAccountCardViewStates().map(\.id), ["acct-1"])
        XCTAssertTrue(model.makeContentPresentation().pendingWorkspaceCards.isEmpty)
    }

    @MainActor
    func testAccountsPageModelLoadDoesNotShowDeletedTeamAccountFromWorkspaceDirectoryEntry() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Deleted Team",
                        email: "dev@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: makeUsageSnapshot(fetchedAt: now),
                        usageError: nil,
                        workspaceStatus: .deactivated,
                        displayStatus: .deleted
                    )
                ],
                workspaceDirectory: [
                    WorkspaceDirectoryEntry(
                        workspaceID: "account-1",
                        workspaceName: "workspace-a",
                        email: "dev@example.com",
                        planType: "team",
                        kind: .workspace,
                        source: .deactivated,
                        status: .deactivated,
                        visibility: .visible,
                        lastSeenAt: now,
                        lastStatusCheckedAt: now
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: AccountIDMappedResultUsageService(
                resultsByAccountID: [
                    "account-1": .failure(AppError.workspaceDeactivated)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()

        XCTAssertTrue(model.makeAccountCardViewStates().isEmpty)
        XCTAssertTrue(model.makeContentPresentation().pendingWorkspaceCards.isEmpty)
    }

    func testWorkspaceMetadataCancellationPrefersFriendlyMessage() async throws {
        let message = DefaultWorkspaceMetadataService.debugPreferredUserFacingFailureMessage(
            from: [
                "https://chatgpt.com/backend-api/accounts -> cancelled",
                "https://chatgpt.com/accounts -> cancelled"
            ]
        )

        XCTAssertEqual(message, L10n.tr("error.workspace.discovery_cancelled"))
    }

    func testWorkspaceMetadataTimeoutPrefersFriendlyMessage() async throws {
        let message = DefaultWorkspaceMetadataService.debugPreferredUserFacingFailureMessage(
            from: [
                "https://chatgpt.com/backend-api/accounts -> The request timed out."
            ]
        )

        XCTAssertEqual(message, L10n.tr("error.workspace.discovery_timed_out"))
    }

    func testWorkspaceMetadataHTMLForbiddenPrefersFriendlyMessage() async throws {
        let message = DefaultWorkspaceMetadataService.debugPreferredUserFacingFailureMessage(
            from: [
                "https://chatgpt.com/backend-api/accounts -> 403: <html><head><meta name=\"viewport\"></head></html>"
            ]
        )

        XCTAssertEqual(message, L10n.tr("error.workspace.discovery_forbidden"))
    }

    @MainActor
    func testAccountsPageModelPendingWorkspaceRefreshUsesWorkspaceMetadataServiceForUnauthorizedDiscovery() async {
        let now: Int64 = 1_763_216_000
        let metadataService = RecordingAccessTokenMappedWorkspaceMetadataService(
            metadataByAccessToken: [
                "token-1": [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ],
                "token-2": [
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "workspace-b", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-3", workspaceName: "workspace-c", structure: "workspace")
                ]
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "acct-1",
                            email: "account-1@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "workspace-a",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-1")
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        ),
                        StoredAccount(
                            id: "acct-2",
                            label: "acct-2",
                            email: "account-2@example.com",
                            accountID: "account-2",
                            planType: "team",
                            teamName: "workspace-b",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-2")
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        )
                    ],
                    currentSelection: CurrentAccountSelection(
                    cardID: "account-1",
                        selectedAt: now,
                        sourceDeviceID: "device"
                    )
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-1",
                        email: "account-1@example.com",
                        planType: "team",
                        teamName: "workspace-a"
                    ),
                    "account-2": ExtractedAuth(
                        accountID: "account-2",
                        accessToken: "token-2",
                        email: "account-2@example.com",
                        planType: "team",
                        teamName: "workspace-b"
                    )
                ]
            ),
            usageService: RecordingAccountUsageService(results: [:]),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)
        let accounts = [
            AccountSummary(
                id: "acct-1",
                label: "acct-1",
                email: "account-1@example.com",
                accountID: "account-1",
                planType: "team",
                teamName: "workspace-a",
                teamAlias: nil,
                addedAt: now,
                updatedAt: now,
                usage: nil,
                usageError: nil,
                isCurrent: true
            ),
            AccountSummary(
                id: "acct-2",
                label: "acct-2",
                email: "account-2@example.com",
                accountID: "account-2",
                planType: "team",
                teamName: "workspace-b",
                teamAlias: nil,
                addedAt: now,
                updatedAt: now,
                usage: nil,
                usageError: nil,
                isCurrent: false
            )
        ]

        await model.refreshPendingWorkspaceAuthorizations(from: accounts)

        let requestedTokens = await metadataService.readRequestedAccessTokens()
        XCTAssertEqual(requestedTokens, ["token-1", "token-2"])
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-3"])
        XCTAssertNil(model.pendingWorkspaceAuthorizationError)
    }

    @MainActor
    func testAccountsPageModelBackgroundRefreshDoesNotTouchPendingWorkspaceDiscovery() async {
        let now: Int64 = 1_763_216_000
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace"),
                WorkspaceMetadata(accountID: "account-2", workspaceName: "workspace-b", structure: "workspace")
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "acct-1",
                            email: "account-1@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "workspace-a",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-1")
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        )
                    ]
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-1",
                        email: "account-1@example.com",
                        planType: "team",
                        teamName: "workspace-a"
                    )
                ]
            ),
            usageService: RecordingAccountUsageService(results: [:]),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(metadataService.callCount, 1)
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])

        model.syncFromBackgroundRefresh([
            AccountSummary(
                id: "acct-1",
                label: "acct-1",
                email: "account-1@example.com",
                accountID: "account-1",
                planType: "team",
                teamName: "workspace-a",
                teamAlias: nil,
                addedAt: now,
                updatedAt: now + 30,
                usage: makeUsageSnapshot(fetchedAt: now + 30, fiveHourResetAt: now + 600),
                usageError: nil,
                isCurrent: false
            )
        ])
        await Task.yield()

        XCTAssertEqual(metadataService.callCount, 1)
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])
    }

    @MainActor
    func testAccountsPageModelPendingWorkspaceDiscoveryCancellationDoesNotShowError() async {
        let now: Int64 = 1_763_216_000
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "acct-1",
                            email: "account-1@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "workspace-a",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-1")
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        )
                    ]
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-1",
                        email: "account-1@example.com",
                        planType: "team",
                        teamName: "workspace-a"
                    )
                ]
            ),
            usageService: RecordingAccountUsageService(results: [:]),
            workspaceMetadataService: ThrowingWorkspaceMetadataService(error: CancellationError()),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)
        let accounts = [
            AccountSummary(
                id: "acct-1",
                label: "acct-1",
                email: "account-1@example.com",
                accountID: "account-1",
                planType: "team",
                teamName: "workspace-a",
                teamAlias: nil,
                addedAt: now,
                updatedAt: now,
                usage: nil,
                usageError: nil,
                isCurrent: true
            )
        ]

        await model.refreshPendingWorkspaceAuthorizations(from: accounts)

        XCTAssertTrue(model.pendingWorkspaceAuthorizations.isEmpty)
        XCTAssertNil(model.pendingWorkspaceAuthorizationError)
    }

    @MainActor
    func testAccountsPageModelPendingWorkspaceDiscoveryStopsAfterCancellation() async {
        let now: Int64 = 1_763_216_000
        let metadataService = ControlledWorkspaceMetadataService(
            resultsByAccessToken: [
                "token-1": [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "workspace-a", structure: "workspace")
                ],
                "token-2": [
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "workspace-b", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-3", workspaceName: "workspace-c", structure: "workspace")
                ]
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "acct-1",
                            email: "account-1@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "workspace-a",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-1")
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        ),
                        StoredAccount(
                            id: "acct-2",
                            label: "acct-2",
                            email: "account-2@example.com",
                            accountID: "account-2",
                            planType: "team",
                            teamName: "workspace-b",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-2")
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: nil,
                            usageError: nil
                        )
                    ],
                    currentSelection: CurrentAccountSelection(
                    cardID: "account-1",
                        selectedAt: now,
                        sourceDeviceID: "device"
                    )
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-1",
                        email: "account-1@example.com",
                        planType: "team",
                        teamName: "workspace-a"
                    ),
                    "account-2": ExtractedAuth(
                        accountID: "account-2",
                        accessToken: "token-2",
                        email: "account-2@example.com",
                        planType: "team",
                        teamName: "workspace-b"
                    )
                ]
            ),
            usageService: RecordingAccountUsageService(results: [:]),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)
        let accounts = [
            AccountSummary(
                id: "acct-1",
                label: "acct-1",
                email: "account-1@example.com",
                accountID: "account-1",
                planType: "team",
                teamName: "workspace-a",
                teamAlias: nil,
                addedAt: now,
                updatedAt: now,
                usage: nil,
                usageError: nil,
                isCurrent: true
            ),
            AccountSummary(
                id: "acct-2",
                label: "acct-2",
                email: "account-2@example.com",
                accountID: "account-2",
                planType: "team",
                teamName: "workspace-b",
                teamAlias: nil,
                addedAt: now,
                updatedAt: now,
                usage: nil,
                usageError: nil,
                isCurrent: false
            )
        ]

        let refreshTask = Task {
            await model.refreshPendingWorkspaceAuthorizations(from: accounts)
        }
        await metadataService.waitForFirstFetchToStart()
        refreshTask.cancel()
        await metadataService.resumeFirstFetch()
        _ = await refreshTask.result

        let requestedTokens = await metadataService.readRequestedAccessTokens()
        XCTAssertEqual(requestedTokens, ["token-1"])
    }

    func testListAccountsMarksWorkspaceDeactivatedWhenRemoteMetadataSaysSo() async throws {
        let now: Int64 = 1_763_216_000
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        StoredAccount(
                            id: "acct-1",
                            label: "Primary",
                            email: "dev@example.com",
                            accountID: "account-1",
                            planType: "team",
                            teamName: "workspace-a",
                            teamAlias: nil,
                            authJSON: .object([
                                "account_id": .string("account-1"),
                                "tokens": .object([
                                    "access_token": .string("token-1")
                                ])
                            ]),
                            addedAt: now,
                            updatedAt: now,
                            usage: makeUsageSnapshot(fetchedAt: now),
                            usageError: nil
                        )
                    ]
                )
            ),
            settingsRepository: TestSettingsRepository(),
            authRepository: TokenMappedAuthRepository(
                extractedByAccessToken: [
                    "token-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "workspace-a")
                ]
            ),
            usageService: RecordingAccountUsageService(results: [:]),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(
                        accountID: "account-1",
                        workspaceName: "workspace-a",
                        structure: "deactivated"
                    )
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()

        XCTAssertEqual(accounts.first?.workspaceStatus, .active)
        XCTAssertEqual(accounts.first?.teamName, "workspace-a")
    }

    func testSyncWorkspaceDirectoryKeepsUnauthorizedCandidatesAndPreservesDeletedDeactivatedEntries() async throws {
        let now: Int64 = 1_763_216_000
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
            ]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                workspaceDirectory: [
                    WorkspaceDirectoryEntry(
                        workspaceID: "account-2",
                        workspaceName: "ops-space",
                        email: "test@example.com",
                        planType: "team",
                        kind: .workspace,
                        status: .active,
                        visibility: .visible,
                        lastSeenAt: now - 100,
                        lastStatusCheckedAt: now - 50
                    ),
                    WorkspaceDirectoryEntry(
                        workspaceID: "account-3",
                        workspaceName: "old-space",
                        email: "test@example.com",
                        planType: "team",
                        kind: .workspace,
                        status: .deactivated,
                        visibility: .deleted,
                        lastSeenAt: now - 80,
                        lastStatusCheckedAt: now - 40
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil)
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let entries = try await coordinator.syncWorkspaceDirectory()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(metadataService.callCount, 1)
        XCTAssertEqual(entries, savedStore.workspaceDirectory)
        XCTAssertEqual(entries.map(\.workspaceID), ["account-3", "account-2"])
        XCTAssertEqual(entries.map(\.status), [.deactivated, .active])
        XCTAssertEqual(entries.map(\.kind), [.workspace, .workspace])
        XCTAssertEqual(entries.map(\.visibility), [.deleted, .visible])
        XCTAssertEqual(entries.map(\.lastSeenAt), [now - 80, now])
        XCTAssertEqual(entries.map(\.lastStatusCheckedAt), [now - 40, now - 50])
    }

    func testSyncWorkspaceDirectoryIgnoresDeletedAccountsForDiscovery() async throws {
        let now: Int64 = 1_763_216_000
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
            ]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Deleted",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil,
                        displayStatus: .deleted
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil)
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let entries = try await coordinator.syncWorkspaceDirectory()

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(metadataService.callCount, 0)
    }

    func testSyncWorkspaceDirectoryThrowsWhenUnauthorizedWorkspaceDiscoveryFails() async throws {
        let now: Int64 = 1_763_216_000
        let existingEntry = WorkspaceDirectoryEntry(
            workspaceID: "account-2",
            workspaceName: "ops-space",
            email: "test@example.com",
            planType: "team",
            kind: .workspace,
            status: .deactivated,
            visibility: .deleted,
            lastSeenAt: now - 100,
            lastStatusCheckedAt: now - 50
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                workspaceDirectory: [existingEntry]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil)
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: ThrowingWorkspaceMetadataService(
                error: AppError.network("workspace discovery failed")
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        do {
            _ = try await coordinator.syncWorkspaceDirectory()
            XCTFail("Expected syncWorkspaceDirectory to throw")
        } catch {
            let savedStore = try storeRepository.loadStore()
            XCTAssertEqual(savedStore.workspaceDirectory, [existingEntry])
        }
    }

    func testSyncWorkspaceDirectoryBuildsPendingEntriesFromWorkspaceMetadataAndPreservesDeletedVisibility() async throws {
        let now: Int64 = 1_763_216_000
        let deletedEntry = WorkspaceDirectoryEntry(
            workspaceID: "account-2",
            workspaceName: "ops-space",
            email: "test@example.com",
            planType: "team",
            kind: .workspace,
            source: .legacyMetadata,
            status: .active,
            visibility: .deleted,
            lastSeenAt: now - 100,
            lastStatusCheckedAt: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                workspaceDirectory: [deletedEntry]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space"
                    )
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-3", workspaceName: "new-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let entries = try await coordinator.syncWorkspaceDirectory()

        XCTAssertEqual(Set(entries.map(\.workspaceID)), Set(["account-2", "account-3"]))
        XCTAssertEqual(
            entries.first(where: { $0.workspaceID == "account-2" })?.visibility,
            .deleted
        )
        XCTAssertEqual(
            entries.first(where: { $0.workspaceID == "account-2" })?.status,
            .active
        )
        XCTAssertEqual(
            entries.first(where: { $0.workspaceID == "account-3" })?.visibility,
            .visible
        )
        XCTAssertEqual(
            entries.first(where: { $0.workspaceID == "account-3" })?.status,
            .active
        )
    }

    func testSyncWorkspaceDirectoryPreservesConsentEntriesNotPresentInWorkspaceMetadata() async throws {
        let now: Int64 = 1_763_216_000
        let consentEntry = WorkspaceDirectoryEntry(
            workspaceID: "account-2",
            workspaceName: "ops-space",
            email: "test@example.com",
            planType: "team",
            kind: .workspace,
            source: .consent,
            status: .active,
            visibility: .visible,
            lastSeenAt: now - 100,
            lastStatusCheckedAt: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1"),
                            "tokens": .object([
                                "access_token": .string("token-1")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                workspaceDirectory: [consentEntry]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space"
                    )
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let entries = try await coordinator.syncWorkspaceDirectory()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(entries, [consentEntry])
        XCTAssertEqual(savedStore.workspaceDirectory, [consentEntry])
    }

    func testSyncWorkspaceDirectoryMergesWorkspaceMetadataAcrossAllEligibleAccounts() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "primary-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Secondary",
                        email: "secondary@example.com",
                        accountID: "account-2",
                        planType: "enterprise",
                        teamName: "secondary-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-2")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let metadataService = RecordingAccessTokenMappedWorkspaceMetadataService(
            metadataByAccessToken: [
                "token-account-1": [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "primary-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-3", workspaceName: "ops-space", structure: "workspace")
                ],
                "token-account-2": [
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "secondary-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-4", workspaceName: "research-space", structure: "workspace")
                ]
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(
                        accountID: "account-1",
                        planType: "team",
                        teamName: "primary-space"
                    ),
                    "account-2": makeExtractedAuth(
                        accountID: "account-2",
                        planType: "enterprise",
                        teamName: "secondary-space"
                    )
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let entries = try await coordinator.syncWorkspaceDirectory()
        let requestedTokens = await metadataService.readRequestedAccessTokens()

        XCTAssertEqual(Set(requestedTokens), Set(["token-account-1", "token-account-2"]))
        XCTAssertEqual(Set(entries.map(\.workspaceID)), Set(["account-3", "account-4"]))
        XCTAssertEqual(
            Set(entries.map(\.workspaceName)),
            Set(["ops-space", "research-space"])
        )
    }

    func testSyncWorkspaceDirectoryRestoresVisibilityWhenWorkspaceBecomesActive() async throws {
        let now: Int64 = 1_763_216_000
        let existingEntry = WorkspaceDirectoryEntry(
            workspaceID: "account-2",
            workspaceName: "ops-space",
            email: "test@example.com",
            planType: "team",
            kind: .workspace,
            status: .deactivated,
            visibility: .deleted,
            lastSeenAt: now - 100,
            lastStatusCheckedAt: now - 50
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                workspaceDirectory: [existingEntry]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil)
                ]
            ),
            usageService: AccountIDMappedResultUsageService(
                resultsByAccountID: [
                    "account-2": .success(makeUsageSnapshot(fetchedAt: now))
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "ops-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let entries = try await coordinator.syncWorkspaceDirectory()

        XCTAssertEqual(
            entries,
            [
                WorkspaceDirectoryEntry(
                    workspaceID: "account-2",
                    workspaceName: "ops-space",
                    email: "test@example.com",
                    planType: "team",
                    kind: .workspace,
                    source: .legacyMetadata,
                    status: .deactivated,
                    visibility: .deleted,
                    lastSeenAt: now,
                    lastStatusCheckedAt: now - 50
                )
            ]
        )
    }

    func testRefreshUsageMarksDeactivatedAccountWithoutWritingWorkspaceDirectoryEntry() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: "remote-space")
                ]
            ),
            usageService: AccountIDMappedResultUsageService(
                resultsByAccountID: [
                    "account-1": .failure(AppError.workspaceDeactivated)
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.refreshUsage(force: true)
        let savedStore = try storeRepository.loadStore()

        XCTAssertTrue(savedStore.workspaceDirectory.isEmpty)
        XCTAssertEqual(savedStore.accounts[0].workspaceStatus, .deactivated)
        XCTAssertEqual(savedStore.accounts[0].displayStatus, .deactivated)
    }

    func testImportAccountRemovesStoredWorkspaceDirectoryEntryForAuthorizedWorkspace() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                workspaceDirectory: [
                    WorkspaceDirectoryEntry(
                        workspaceID: "account-1",
                        workspaceName: "remote-space",
                        email: "test@example.com",
                        planType: "team",
                        kind: .workspace,
                        status: .deactivated,
                        visibility: .visible,
                        lastSeenAt: now - 50,
                        lastStatusCheckedAt: now - 50
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: AccountIDAwareAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: FixedChatGPTOAuthLoginService(
                tokens: ChatGPTOAuthTokens(
                    accessToken: "access-token",
                    refreshToken: "refresh-token",
                    idToken: makeUnsignedJWT(
                        payload: [
                            "https://api.openai.com/auth": [
                                "chatgpt_account_id": "account-1"
                            ]
                        ]
                    ),
                    apiKey: nil
                )
            ),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.addAccountViaLogin(customLabel: nil)
        let savedStore = try storeRepository.loadStore()

        XCTAssertTrue(savedStore.workspaceDirectory.isEmpty)
    }

    @MainActor
    func testAccountsPageModelDeletePendingWorkspacePersistsDismissalForStoredDeactivatedEntry() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                workspaceDirectory: [
                    WorkspaceDirectoryEntry(
                        workspaceID: "account-2",
                        workspaceName: "ops-space",
                        email: "test@example.com",
                        planType: "team",
                        kind: .workspace,
                        status: .deactivated,
                        visibility: .visible,
                        lastSeenAt: now - 20,
                        lastStatusCheckedAt: now - 20
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil)
                ]
            ),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: StubWorkspaceMetadataService(metadata: []),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.pendingWorkspaceAuthorizations.map(\.workspaceID), ["account-2"])

        await model.deletePendingWorkspace(id: "account-2")

        let savedStore = try? storeRepository.loadStore()
        XCTAssertTrue(model.pendingWorkspaceAuthorizations.isEmpty)
        XCTAssertEqual(savedStore?.workspaceDirectory.count, 1)
        XCTAssertEqual(
            savedStore?.workspaceDirectory.first(where: { $0.workspaceID == "account-2" })?.visibility,
            .deleted
        )
    }

    @MainActor
    func testDeletingDeactivatedPendingAccountAlsoDismissesWorkspaceFromFutureDiscovery() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Dormant",
                        email: "test@example.com",
                        accountID: "account-2",
                        planType: "team",
                        teamName: "old-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-2")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: L10n.tr("error.accounts.workspace_deactivated"),
                        workspaceStatus: .deactivated
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil),
                    "account-2": makeExtractedAuth(accountID: "account-2", planType: "team", teamName: nil)
                ]
            ),
            usageService: AccountIDMappedResultUsageService(
                resultsByAccountID: [
                    "account-1": .success(makeUsageSnapshot(fetchedAt: now)),
                    "account-2": .failure(AppError.workspaceDeactivated)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "old-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.makeContentPresentation().pendingWorkspaceCards.map(\.id), ["acct-2"])

        await model.deletePendingWorkspace(id: "acct-2")

        let accounts = try? await coordinator.listAccounts()
        await model.refreshPendingWorkspaceAuthorizations(from: accounts ?? [])

        XCTAssertEqual(accounts?.map(\.accountID), ["account-1", "account-2"])
        XCTAssertEqual(accounts?.map(\.displayStatus), [.list, .deleted])
        XCTAssertTrue(model.pendingWorkspaceAuthorizations.isEmpty)
        XCTAssertEqual(model.makeContentPresentation().pendingWorkspaceCards.map(\.id), [])
    }

    @MainActor
    func testDeletingDeactivatedPendingAccountRemovesCardImmediately() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = DelayedAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Dormant",
                        email: "test@example.com",
                        accountID: "account-2",
                        planType: "team",
                        teamName: "old-space",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-2")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: L10n.tr("error.accounts.workspace_deactivated"),
                        workspaceStatus: .deactivated
                    )
                ]
            ),
            saveDelay: 0.4
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1", planType: "team", teamName: nil),
                    "account-2": makeExtractedAuth(accountID: "account-2", planType: "team", teamName: nil)
                ]
            ),
            usageService: AccountIDMappedResultUsageService(
                resultsByAccountID: [
                    "account-1": .success(makeUsageSnapshot(fetchedAt: now)),
                    "account-2": .failure(AppError.workspaceDeactivated)
                ]
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "old-space", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = AccountsPageModel(coordinator: coordinator)

        await model.load()
        XCTAssertEqual(model.makeContentPresentation().pendingWorkspaceCards.map(\.id), ["acct-2"])

        let deleteTask = Task { @MainActor in
            await model.deletePendingWorkspace(id: "acct-2")
        }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.makeContentPresentation().pendingWorkspaceCards.map(\.id), [])

        await deleteTask.value
    }

    @MainActor
    func testContentPresentationHidesPendingSectionForErrorWithoutCards() {
        let account = makeAccountSummary(
            id: "acct-1",
            accountID: "account-1",
            isCurrent: true,
            usage: nil
        )
        let model = AccountsPageModel(
            coordinator: AccountsCoordinator(
                storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
                settingsRepository: TestSettingsRepository(),
                authRepository: StubAuthRepository(),
                usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: 1)),
                chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
                codexCLIService: StubCodexCLIService(),
                editorAppService: StubEditorAppService(),
                opencodeAuthSyncService: StubOpencodeAuthSyncService(),
                dateProvider: FixedDateProvider(now: 1)
            ),
            initialAccounts: [account]
        )
        model.pendingWorkspaceAuthorizationError = L10n.tr("error.workspace.discovery_forbidden")

        let contentPresentation = model.makeContentPresentation()

        XCTAssertTrue(contentPresentation.pendingWorkspaceCards.isEmpty)
        XCTAssertNil(contentPresentation.pendingWorkspaceError)
        XCTAssertFalse(contentPresentation.shouldShowPendingWorkspaceSection)
    }

    @MainActor
    func testTrayMenuModelPushesInitialLocalAccountsBaselineDuringCloudReconciliation() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now)
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RecordingAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let cloudSyncService = SpyAccountsCloudSyncService(pullResult: .noChange)
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: cloudSyncService,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(3),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        await trayModel.reconcileCloudStateNow()

        let pushCallCount = await cloudSyncService.readPushCallCount()
        XCTAssertEqual(pushCallCount, 1)
        XCTAssertEqual(trayModel.accounts.map(\.accountID), ["account-1"])
    }

    @MainActor
    func testTrayMenuModelSyncLocalMutationAlsoSyncsConfiguredRemoteAccounts() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now)
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RecordingAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let cloudSyncService = SpyAccountsCloudSyncService(pullResult: .noChange)
        let remoteSyncService = SpyRemoteAccountsMutationSyncService()
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: cloudSyncService,
            currentAccountSelectionSyncService: nil,
            remoteAccountsMutationSyncService: remoteSyncService,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(3),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        await trayModel.syncLocalAccountsMutationNow()

        let pushCallCount = await cloudSyncService.readPushCallCount()
        XCTAssertEqual(pushCallCount, 1)
        let remoteSyncCallCount = await remoteSyncService.readCallCount()
        XCTAssertEqual(remoteSyncCallCount, 1)
    }

    @MainActor
    func testTrayMenuModelRecurringRefreshStillRefreshesUsageOnMacWhenCloudSnapshotIsFresh() async {
        let now: Int64 = 1_763_216_000
        let usageService = CountingUsageService(result: makeUsageSnapshot(fetchedAt: now))
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now - 60)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RecordingAuthRepository(),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let cloudSyncService = SpyAccountsCloudSyncService(
            pullResult: AccountsCloudSyncPullResult(
                didUpdateAccounts: false,
                remoteSyncedAt: now
            )
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: cloudSyncService,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(3),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: true,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        await trayModel.refreshNow(forceUsageRefresh: true)

        XCTAssertEqual(usageService.callCount, 1)
    }

    @MainActor
    func testTrayMenuModelRefreshLocalAccountsPushesCurrentSelectionAfterAutoSmartSwitch() async throws {
        let now: Int64 = 1_763_216_000
        let currentSelectionSyncService = RecordingCurrentAccountSelectionSyncService()
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now - 60),
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now - 60)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                ),
                "account-2": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1"),
                    "account-2": makeExtractedAuth(accountID: "account-2")
                ]
            ),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: nil,
            currentAccountSelectionSyncService: currentSelectionSyncService,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )
        trayModel.autoSmartSwitchEnabled = true

        _ = try await trayModel.refreshLocalAccounts(
            forceUsageRefresh: true,
            prefersSerialUsageRefresh: false,
            bypassUsageThrottle: true,
            targetAccountIDs: nil,
            onPartialUpdate: nil
        )

        let recordedAccountIDs = await currentSelectionSyncService.readRecordedAccountIDs()
        let pushCallCount = await currentSelectionSyncService.readPushCallCount()
        XCTAssertEqual(try storeRepository.loadStore().currentSelection?.cardID, "acct-2")
        XCTAssertEqual(recordedAccountIDs, ["acct-2"])
        XCTAssertEqual(pushCallCount, 1)
    }

    @MainActor
    func testTrayMenuModelRefreshLocalAccountsShowsNoticeWhenSelectionSyncFails() async throws {
        let now: Int64 = 1_763_216_000
        let currentSelectionSyncService = FailingCurrentAccountSelectionSyncService(message: "selection sync failed")
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now - 60),
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now - 60)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                ),
                "account-2": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": makeExtractedAuth(accountID: "account-1"),
                    "account-2": makeExtractedAuth(accountID: "account-2")
                ]
            ),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: nil,
            currentAccountSelectionSyncService: currentSelectionSyncService,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )
        trayModel.autoSmartSwitchEnabled = true

        _ = try await trayModel.refreshLocalAccounts(
            forceUsageRefresh: true,
            prefersSerialUsageRefresh: false,
            bypassUsageThrottle: true,
            targetAccountIDs: nil,
            onPartialUpdate: nil
        )

        XCTAssertEqual(trayModel.notice, "selection sync failed")
    }

    @MainActor
    func testTrayMenuModelAutoSmartSwitchWritesAuthAndLaunchesCodex() async throws {
        let now: Int64 = 1_763_216_000
        let authRepository = RecordingMultiAccountAuthRepository(
            extractedByAccountID: [
                "account-1": makeExtractedAuth(accountID: "account-1"),
                "account-2": makeExtractedAuth(accountID: "account-2")
            ]
        )
        let codexService = RecordingCodexCLIService()
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now - 60),
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now - 60)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                ),
                "account-2": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: codexService,
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
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
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )
        trayModel.autoSmartSwitchEnabled = true

        _ = try await trayModel.refreshLocalAccounts(
            forceUsageRefresh: true,
            prefersSerialUsageRefresh: false,
            bypassUsageThrottle: true,
            targetAccountIDs: nil,
            onPartialUpdate: nil
        )

        XCTAssertEqual(authRepository.writtenAccountIDs.last, "account-2")
        XCTAssertEqual(codexService.launchCallCount, 1)
        XCTAssertEqual(try storeRepository.loadStore().currentSelection?.cardID, "acct-2")
    }

    @MainActor
    func testExecuteRefreshKeepsAutoSwitchedAccountWhenRemoteSelectionArrivesInSameCycle() async throws {
        let now: Int64 = 1_763_216_000
        let authRepository = RecordingMultiAccountAuthRepository(
            extractedByAccountID: [
                "account-1": makeExtractedAuth(accountID: "account-1"),
                "account-2": makeExtractedAuth(accountID: "account-2")
            ]
        )
        var first = makeStoredAccount(id: "acct-1", accountID: "account-1", now: now - 60)
        first.usage = UsageSnapshot(
            fetchedAt: now,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: nil),
            credits: nil
        )
        var second = makeStoredAccount(id: "acct-2", accountID: "account-2", now: now - 60)
        second.usage = UsageSnapshot(
            fetchedAt: now,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
            credits: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    first,
                    second
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                ),
                "account-2": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
                    credits: nil
                )
            ]
        )
        var settings = AppSettings.defaultValue
        settings.autoSmartSwitch = true
        let settingsRepository = TestSettingsRepository(settings: settings)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: settingsRepository,
            authRepository: authRepository,
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let currentSelectionSyncService = SameCycleRemoteOverrideCurrentSelectionSyncService(
            remoteCardID: "acct-1",
            remoteSelection: CurrentAccountSelection(
                cardID: "acct-1",
                selectedAt: now * 1_000 + 10_000,
                sourceDeviceID: "remote-device"
            )
        )
        let directAutoSwitch = try await coordinator.autoSmartSwitchIfNeeded()
        XCTAssertEqual(directAutoSwitch?.selectedAccount.accountID, "account-2")
        XCTAssertEqual(try storeRepository.loadStore().currentSelection?.cardID, "acct-2")

        var resetStore = try storeRepository.loadStore()
        resetStore.currentSelection = CurrentAccountSelection(
            cardID: "acct-1",
            selectedAt: now * 1_000,
            sourceDeviceID: "macos-local"
        )
        resetStore.currentAccountID = "acct-1"
        try storeRepository.saveStore(resetStore)
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: settingsRepository,
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: nil,
            currentAccountSelectionSyncService: currentSelectionSyncService,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: true
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        let latestAccounts = try await trayModel.executeRefresh(
            forceUsageRefresh: true,
            failOnCloudSyncError: false
        )

        XCTAssertEqual(latestAccounts.first(where: \.isCurrent)?.accountID, "account-2")
        XCTAssertEqual(try storeRepository.loadStore().currentSelection?.cardID, "acct-2")
        XCTAssertEqual(authRepository.writtenAccountIDs.last, "account-2")
    }

    func testIOSBackgroundRefreshPolicyAppliesRemoteSelectionSwitchEffects() {
        let policy = TrayMenuModel.BackgroundRefreshPolicy.forPlatform(.iOS)

        XCTAssertEqual(policy.cloudSyncMode, .pullRemoteAccounts)
        XCTAssertTrue(policy.applyRemoteSelectionSwitchEffects)
    }

    @MainActor
    func testTrayMenuModelStartBackgroundRefreshReconcilesCloudStateImmediately() async {
        let now: Int64 = 1_763_216_000
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            settingsRepository: TestSettingsRepository(),
            authRepository: RecordingAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let cloudSyncService = SpyAccountsCloudSyncService(pullResult: .noChange)
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: cloudSyncService,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .seconds(10),
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pullRemoteAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        trayModel.startBackgroundRefresh()
        try? await Task.sleep(for: .milliseconds(150))
        trayModel.stopBackgroundRefresh()

        let pullCallCount = await cloudSyncService.readPullCallCount()
        XCTAssertEqual(pullCallCount, 1)
    }

    func testBackgroundRefreshPolicyForMacUsesThirtySecondUsageRefresh() {
        let policy = TrayMenuModel.BackgroundRefreshPolicy.forPlatform(.macOS)

        XCTAssertEqual(policy.usageRefreshInterval, .seconds(30))
    }

    @MainActor
    func testTrayMenuModelStartBackgroundRefreshRefreshesUsageOnRecurringTick() async {
        let now: Int64 = 1_763_216_000
        let usageService = RecordingAccountUsageService(
            results: [
                "account-1": makeUsageSnapshot(fetchedAt: now)
            ]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RecordingAuthRepository(),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: nil,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .milliseconds(30),
                refreshUsageOnRecurringTick: true,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        trayModel.startBackgroundRefresh()
        try? await Task.sleep(for: .milliseconds(120))
        trayModel.stopBackgroundRefresh()

        let requestedAccountIDs = await usageService.readRequestedAccountIDs()
        XCTAssertFalse(requestedAccountIDs.isEmpty)
        XCTAssertTrue(requestedAccountIDs.allSatisfy { $0 == "account-1" })
    }

    @MainActor
    func testTrayMenuModelStartBackgroundRefreshDoesNotRunWorkspaceHealthCheckOnRecurringTick() async {
        let now: Int64 = 1_763_216_000
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")
            ]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "acct-1",
                        email: "account-1@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-a",
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
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
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        trayModel.startBackgroundRefresh()
        try? await Task.sleep(for: .milliseconds(120))
        trayModel.stopBackgroundRefresh()

        XCTAssertEqual(metadataService.callCount, 0)
    }

    @MainActor
    func testTrayMenuModelRecurringRefreshDoesNotTriggerWorkspaceMetadataLookup() async {
        let now: Int64 = 1_763_216_000
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [
                WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")
            ]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "acct-1",
                        email: "account-1@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([
                            "account_id": .string("account-1")
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: nil,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .zero,
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .milliseconds(30),
                refreshUsageOnRecurringTick: true,
                cloudSyncMode: .pushLocalAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        await trayModel.refreshNow(forceUsageRefresh: true)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(metadataService.callCount, 0)
    }

    @MainActor
    func testTrayMenuModelCurrentSelectionPushRefreshesAccountsOnIOSWithoutAuthSwitchEffects() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now),
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now + 1)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "ios-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: RecordingAuthRepository(),
            usageService: CountingUsageService(result: makeUsageSnapshot(fetchedAt: now)),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let initialAccounts = try await coordinator.listAccounts()
        XCTAssertEqual(initialAccounts.first(where: \.isCurrent)?.accountID, "account-1")

        let currentSelectionSyncService = PushDrivenCurrentAccountSelectionSyncService(
            remoteCardID: "acct-2",
            remoteSelection: CurrentAccountSelection(
                cardID: "acct-2",
                selectedAt: now * 1_000 + 1,
                sourceDeviceID: "macos-remote"
            )
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: coordinator,
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: nil,
            currentAccountSelectionSyncService: currentSelectionSyncService,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .seconds(10),
                cloudReconciliationInterval: .seconds(30),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .pullRemoteAccounts,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: initialAccounts
        )

        trayModel.configureCurrentSelectionPushHandlingIfNeeded()
        NotificationCenter.default.post(name: .copoolCurrentAccountSelectionPushDidArrive, object: nil)
        try? await Task.sleep(for: .milliseconds(100))

        let ensurePushSubscriptionCallCount = await currentSelectionSyncService.readEnsurePushSubscriptionCallCount()
        let pullCallCount = await currentSelectionSyncService.readPullCallCount()
        let accountsPageModel = makeAccountsPageModelForViewStoreTests(initialAccounts: initialAccounts)
        accountsPageModel.syncFromBackgroundRefresh(trayModel.accounts)

        XCTAssertEqual(ensurePushSubscriptionCallCount, 1)
        XCTAssertEqual(pullCallCount, 1)
        XCTAssertEqual(trayModel.accounts.first(where: \.isCurrent)?.accountID, "account-2")

        guard case .content(let displayedAccounts) = accountsPageModel.state else {
            return XCTFail("Expected accounts page to render account content")
        }
        XCTAssertEqual(displayedAccounts.first?.accountID, "account-2")
        XCTAssertEqual(displayedAccounts.first?.isCurrent, true)
    }

    @MainActor
    func testApplyRemoteSelectionSwitchEffectsRequiresExactAccountKeyMatch() async throws {
        let now: Int64 = 1_763_216_000
        let authRepository = RecordingMultiAccountAuthRepository(
            extractedByAccountID: [
                "account-1": makeExtractedAuth(accountID: "account-1"),
                "account-2": makeExtractedAuth(accountID: "account-2")
            ]
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "acct-1", accountID: "account-1", now: now - 60),
                    makeStoredAccount(id: "acct-2", accountID: "account-2", now: now - 60)
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "acct-1",
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let trayModel = TrayMenuModel(
            accountsCoordinator: AccountsCoordinator(
                storeRepository: storeRepository,
                settingsRepository: TestSettingsRepository(),
                authRepository: authRepository,
                usageService: RecordingAccountUsageService(results: [:]),
                chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
                codexCLIService: StubCodexCLIService(),
                editorAppService: StubEditorAppService(),
                opencodeAuthSyncService: StubOpencodeAuthSyncService(),
                dateProvider: FixedDateProvider(now: now)
            ),
            settingsCoordinator: SettingsCoordinator(
                settingsRepository: TestSettingsRepository(),
                launchAtStartupService: StubLaunchAtStartupService()
            ),
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
            dateProvider: FixedDateProvider(now: now),
            initialAccounts: []
        )

        try await trayModel.applyRemoteSelectionSwitchEffects(cardID: "missing-card-id")

        XCTAssertEqual(authRepository.writtenAccountIDs.count, 0)
        XCTAssertEqual(try storeRepository.loadStore().currentAccountID, "acct-1")
    }

    func testRefreshUsageDoesNotOverwriteConcurrentProxySwitchProjection() async throws {
        let now: Int64 = 1_763_216_000
        let first = makeStoredAccount(id: "acct-1", accountID: "account-1", now: now - 60)
        let second = makeStoredAccount(id: "acct-2", accountID: "account-2", now: now - 60)
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [first, second],
                currentAccountID: first.id,
                currentSelection: CurrentAccountSelection(
                    cardID: first.id,
                    selectedAt: now * 1_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let authRepository = MutableCurrentAuthRepository(
            extractedByAccountID: [
                "account-1": makeExtractedAuth(accountID: "account-1"),
                "account-2": makeExtractedAuth(accountID: "account-2")
            ],
            currentAuth: first.authJSON
        )
        let usageService = ControlledUsageService(
            resultsByAccountID: [
                "account-1": makeUsageSnapshot(fetchedAt: now),
                "account-2": makeUsageSnapshot(fetchedAt: now)
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: makeTestFileSystemPaths(),
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            switchAccount: { cardID in
                _ = try await coordinator.switchAccountAndApplySettings(id: cardID)
            },
            dateProvider: FixedDateProvider(now: now)
        )
        let switchedCandidate = ProxyCandidate(
            id: second.id,
            label: second.label,
            accountID: second.accountID,
            accountKey: second.accountKey,
            accessToken: "token-\(second.accountID)",
            authJSON: second.authJSON,
            addedAt: second.addedAt,
            isPreferredCurrent: false,
            oneWeekUsed: second.usage?.oneWeek?.usedPercent,
            fiveHourUsed: second.usage?.fiveHour?.usedPercent
        )

        let refreshTask = Task {
            try await coordinator.refreshUsage(force: true)
        }
        await usageService.waitForFirstFetchToStart()

        try await runtime.recordSuccessfulCandidate(switchedCandidate)
        await usageService.resumeFirstFetch()

        _ = try await refreshTask.value

        let store = try storeRepository.loadStore()
        XCTAssertEqual(store.currentAccountID, second.id)
        XCTAssertEqual(store.currentSelection?.cardID, second.id)
        XCTAssertEqual(authRepository.readCurrentExtractedAuth()?.accountID, second.accountID)
        XCTAssertEqual(authRepository.writtenAccountIDs.last, second.accountID)

        let accounts = try await coordinator.listAccounts(refreshWorkspaceMetadata: false)
        XCTAssertEqual(accounts.first(where: \.isCurrent)?.id, second.id)
    }
}

private func makeAccountSummary(
    id: String,
    accountID: String,
    isCurrent: Bool,
    usage: UsageSnapshot?,
    displayStatus: AccountDisplayStatus = .list,
    planType: String? = "pro",
    teamName: String? = nil
) -> AccountSummary {
    AccountSummary(
        id: id,
        label: id,
        email: "\(accountID)@example.com",
        accountID: accountID,
        planType: planType,
        teamName: teamName,
        teamAlias: nil,
        addedAt: 1,
        updatedAt: 1,
        usage: usage,
        usageError: nil,
        displayStatus: displayStatus,
        isCurrent: isCurrent
    )
}

@MainActor
private func makeAccountsPageModelForViewStoreTests(
    runtimePlatform: RuntimePlatform = .macOS,
    initialAccounts: [AccountSummary]
) -> AccountsPageModel {
    let coordinator = AccountsCoordinator(
        storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
        settingsRepository: TestSettingsRepository(),
        authRepository: StubAuthRepository(),
        usageService: CountingUsageService(
            result: UsageSnapshot(
                fetchedAt: 1,
                planType: "pro",
                fiveHour: nil,
                oneWeek: nil,
                credits: nil
            )
        ),
        chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        codexCLIService: StubCodexCLIService(),
        editorAppService: StubEditorAppService(),
        opencodeAuthSyncService: StubOpencodeAuthSyncService()
    )

    return AccountsPageModel(
        coordinator: coordinator,
        runtimePlatform: runtimePlatform,
        onLocalAccountsChanged: nil,
        initialAccounts: initialAccounts
    )
}

private func makeStoredAccount(
    id: String,
    accountID: String,
    now: Int64
) -> StoredAccount {
    StoredAccount(
        id: id,
        label: id,
        email: "\(accountID)@example.com",
        accountID: accountID,
        planType: "pro",
        teamName: nil,
        teamAlias: nil,
        authJSON: .object([
            "account_id": .string(accountID)
        ]),
        addedAt: now,
        updatedAt: now,
        usage: nil,
        usageError: nil
    )
}

private func makeUsageSnapshot(
    fetchedAt: Int64,
    fiveHourResetAt: Int64? = nil,
    oneWeekResetAt: Int64? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        fetchedAt: fetchedAt,
        planType: "pro",
        fiveHour: UsageWindow(
            usedPercent: 10,
            windowSeconds: 18_000,
            resetAt: fiveHourResetAt
        ),
        oneWeek: UsageWindow(
            usedPercent: 20,
            windowSeconds: 604_800,
            resetAt: oneWeekResetAt
        ),
        credits: nil
    )
}

private func makeExtractedAuth(
    accountID: String,
    planType: String? = "pro",
    teamName: String? = nil
) -> ExtractedAuth {
    ExtractedAuth(
        accountID: accountID,
        accessToken: "token-\(accountID)",
        email: "\(accountID)@example.com",
        planType: planType,
        teamName: teamName ?? "workspace-\(accountID)"
    )
}

private func makeTestAuthJSON(accountID: String, accessToken: String) -> JSONValue {
    .object([
        "auth_mode": .string("chatgpt"),
        "tokens": .object([
            "access_token": .string(accessToken),
            "refresh_token": .string("refresh-\(accountID)"),
            "id_token": .string("id-\(accountID)"),
            "account_id": .string(accountID)
        ])
    ])
}

private func makeUnsignedJWT(payload: [String: Any]) -> String {
    let header = ["alg": "none", "typ": "JWT"]
    return "\(base64URL(header)).\(base64URL(payload)).signature"
}

private func base64URL(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private final class InMemoryAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private var store: AccountsStore

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store
    }
}

private final class CountingAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private var store: AccountsStore
    private(set) var loadCount = 0

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        loadCount += 1
        return store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store
    }
}

private final class DelayedAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private var store: AccountsStore
    private let saveDelay: TimeInterval

    init(store: AccountsStore, saveDelay: TimeInterval) {
        self.store = store
        self.saveDelay = saveDelay
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        Thread.sleep(forTimeInterval: saveDelay)
        self.store = store
    }
}

private actor ControlledUsageService: UsageService {
    private let resultsByAccountID: [String: UsageSnapshot]
    private var firstFetchStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstFetchResumeContinuation: CheckedContinuation<Void, Never>?
    private var didStartFirstFetch = false

    init(resultsByAccountID: [String: UsageSnapshot]) {
        self.resultsByAccountID = resultsByAccountID
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        if !didStartFirstFetch {
            didStartFirstFetch = true
            firstFetchStartedContinuation?.resume()
            firstFetchStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstFetchResumeContinuation = continuation
            }
        }
        guard let result = resultsByAccountID[accountID] else {
            throw AppError.invalidData("Missing usage result for test account")
        }
        return result
    }

    func waitForFirstFetchToStart() async {
        if didStartFirstFetch {
            return
        }
        await withCheckedContinuation { continuation in
            firstFetchStartedContinuation = continuation
        }
    }

    func resumeFirstFetch() {
        firstFetchResumeContinuation?.resume()
        firstFetchResumeContinuation = nil
    }
}

private final class CountingUsageService: UsageService, @unchecked Sendable {
    private(set) var callCount = 0
    private let result: UsageSnapshot

    init(result: UsageSnapshot) {
        self.result = result
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        _ = accountID
        callCount += 1
        return result
    }
}

private final class AccountIDUsageService: UsageService, @unchecked Sendable {
    private let results: [String: UsageSnapshot]

    init(results: [String: UsageSnapshot]) {
        self.results = results
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        guard let result = results[accountID] else {
            throw AppError.invalidData("Missing usage snapshot for \(accountID)")
        }
        return result
    }
}

private final class AccountIDMappedResultUsageService: UsageService, @unchecked Sendable {
    private let resultsByAccountID: [String: Result<UsageSnapshot, Error>]

    init(resultsByAccountID: [String: Result<UsageSnapshot, Error>]) {
        self.resultsByAccountID = resultsByAccountID
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        guard let result = resultsByAccountID[accountID] else {
            throw AppError.invalidData("Missing usage result for \(accountID)")
        }
        return try result.get()
    }
}

private actor SequencedAccountUsageService: UsageService {
    private let resultsByAccountID: [String: [Result<UsageSnapshot, Error>]]
    private var callCounts: [String: Int] = [:]

    init(resultsByAccountID: [String: [Result<UsageSnapshot, Error>]]) {
        self.resultsByAccountID = resultsByAccountID
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        guard let results = resultsByAccountID[accountID], !results.isEmpty else {
            throw AppError.invalidData("Missing usage sequence for \(accountID)")
        }

        let nextIndex = callCounts[accountID, default: 0]
        callCounts[accountID] = nextIndex + 1
        let result = results[min(nextIndex, results.count - 1)]
        return try result.get()
    }
}

private final class ThrowingUsageService: UsageService, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        _ = accountID
        throw error
    }
}

private actor RecordingAccountUsageService: UsageService {
    private let results: [String: UsageSnapshot]
    private(set) var requestedAccountIDs: [String] = []

    init(results: [String: UsageSnapshot]) {
        self.results = results
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        requestedAccountIDs.append(accountID)
        guard let result = results[accountID] else {
            throw AppError.invalidData("Missing usage snapshot for \(accountID)")
        }
        return result
    }

    func readRequestedAccountIDs() -> [String] {
        requestedAccountIDs
    }
}

private actor ValidatingUsageService: UsageService {
    private let validAccessToken: String
    private let result: UsageSnapshot
    private var requestedAccessTokens: [String] = []

    init(validAccessToken: String, result: UsageSnapshot) {
        self.validAccessToken = validAccessToken
        self.result = result
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accountID
        requestedAccessTokens.append(accessToken)
        guard accessToken == validAccessToken else {
            throw AppError.unauthorized("Provided authentication token is expired. Please try signing in again.")
        }
        return result
    }

    func readRequestedAccessTokens() -> [String] {
        requestedAccessTokens
    }
}

private struct FixedDateProvider: DateProviding {
    let now: Int64

    func unixSecondsNow() -> Int64 {
        now
    }
}

private final class StubWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private let metadata: [WorkspaceMetadata]

    init(metadata: [WorkspaceMetadata]) {
        self.metadata = metadata
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        _ = accessToken
        return metadata
    }
}

private final class RecordingWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private(set) var callCount = 0
    private let metadata: [WorkspaceMetadata]

    init(metadata: [WorkspaceMetadata]) {
        self.metadata = metadata
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        _ = accessToken
        callCount += 1
        return metadata
    }
}

private final class ThrowingWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        _ = accessToken
        throw error
    }
}

private final class AccessTokenMappedWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private let metadataByAccessToken: [String: [WorkspaceMetadata]]

    init(metadataByAccessToken: [String: [WorkspaceMetadata]]) {
        self.metadataByAccessToken = metadataByAccessToken
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        metadataByAccessToken[accessToken] ?? []
    }
}

private actor RecordingAccessTokenMappedWorkspaceMetadataService: WorkspaceMetadataService {
    private let metadataByAccessToken: [String: [WorkspaceMetadata]]
    private var requestedAccessTokens: [String] = []

    init(metadataByAccessToken: [String: [WorkspaceMetadata]]) {
        self.metadataByAccessToken = metadataByAccessToken
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        requestedAccessTokens.append(accessToken)
        return metadataByAccessToken[accessToken] ?? []
    }

    func readRequestedAccessTokens() -> [String] {
        requestedAccessTokens
    }
}

private actor ControlledWorkspaceMetadataService: WorkspaceMetadataService {
    private let resultsByAccessToken: [String: [WorkspaceMetadata]]
    private var requestedAccessTokens: [String] = []
    private var firstFetchStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstFetchResumeContinuation: CheckedContinuation<Void, Never>?
    private var didStartFirstFetch = false

    init(resultsByAccessToken: [String: [WorkspaceMetadata]]) {
        self.resultsByAccessToken = resultsByAccessToken
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        requestedAccessTokens.append(accessToken)
        if !didStartFirstFetch {
            didStartFirstFetch = true
            firstFetchStartedContinuation?.resume()
            firstFetchStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstFetchResumeContinuation = continuation
            }
        }
        return resultsByAccessToken[accessToken] ?? []
    }

    func waitForFirstFetchToStart() async {
        if didStartFirstFetch {
            return
        }
        await withCheckedContinuation { continuation in
            firstFetchStartedContinuation = continuation
        }
    }

    func resumeFirstFetch() {
        firstFetchResumeContinuation?.resume()
        firstFetchResumeContinuation = nil
    }

    func readRequestedAccessTokens() -> [String] {
        requestedAccessTokens
    }
}

private final class StubAccountsManualRefreshService: AccountsManualRefreshServiceProtocol, @unchecked Sendable {
    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary] {
        _ = onPartialUpdate
        return []
    }
}

private final class StoreUpdatingAccountsManualRefreshService: AccountsManualRefreshServiceProtocol, @unchecked Sendable {
    private let storeRepository: InMemoryAccountsStoreRepository
    private let refreshedAccounts: [StoredAccount]

    init(
        storeRepository: InMemoryAccountsStoreRepository,
        refreshedAccounts: [StoredAccount]
    ) {
        self.storeRepository = storeRepository
        self.refreshedAccounts = refreshedAccounts
    }

    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary] {
        _ = onPartialUpdate
        try storeRepository.saveStore(
            AccountsStore(
                accounts: refreshedAccounts
            )
        )
        return []
    }
}

private actor SpyRemoteAccountsMutationSyncService: RemoteAccountsMutationSyncServiceProtocol {
    private var callCount = 0

    func syncConfiguredRemoteAccounts() async -> RemoteAccountsMutationSyncReport {
        callCount += 1
        return .empty
    }

    func readCallCount() -> Int {
        callCount
    }
}

private actor RecordingProxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol {
    private var enqueuedCommands: [ProxyControlCommand] = []

    func pushLocalSnapshot(_ snapshot: ProxyControlSnapshot) async throws {
        _ = snapshot
    }

    func pullRemoteSnapshot() async throws -> ProxyControlSnapshot? {
        nil
    }

    func enqueueCommand(_ command: ProxyControlCommand) async throws {
        enqueuedCommands.append(command)
    }

    func pullPendingCommand() async throws -> ProxyControlCommand? {
        nil
    }

    func ensurePushSubscriptionIfNeeded() async throws {}

    func readEnqueuedCommands() -> [ProxyControlCommand] {
        enqueuedCommands
    }
}

@MainActor
private final class SpyAccountsLocalMutationSyncService: AccountsLocalMutationSyncServiceProtocol {
    private(set) var acceptedSnapshots: [[AccountSummary]] = []
    private(set) var syncCallCount = 0

    func acceptLocalAccountsSnapshot(_ accounts: [AccountSummary]) {
        acceptedSnapshots.append(accounts)
    }

    func syncLocalAccountsMutationNow() async {
        syncCallCount += 1
    }
}

private actor ManualRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ManualRefreshCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class BlockingAccountsManualRefreshService: AccountsManualRefreshServiceProtocol, @unchecked Sendable {
    private let gate: ManualRefreshGate
    private let callCounter: ManualRefreshCallCounter
    private let onStart: @Sendable () -> Void

    init(
        gate: ManualRefreshGate,
        callCounter: ManualRefreshCallCounter,
        onStart: @escaping @Sendable () -> Void
    ) {
        self.gate = gate
        self.callCounter = callCounter
        self.onStart = onStart
    }

    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary] {
        _ = onPartialUpdate
        await callCounter.increment()
        onStart()
        await gate.wait()
        return []
    }
}

private final class StubAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        return ExtractedAuth(
            accountID: "account-1",
            accessToken: "token-1",
            email: "test@example.com",
            planType: "pro",
            teamName: "workspace-x"
        )
    }
}

private final class RemoteLookupAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .object([:]) }
    func readCurrentAuthOptional() throws -> JSONValue? { .object([:]) }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .object([:])
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .object([:])
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        return ExtractedAuth(
            accountID: "account-1",
            accessToken: "token-1",
            email: "test@example.com",
            planType: "team",
            teamName: nil
        )
    }
}

private final class AccountIDAwareAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        .object([
            "tokens": .object([
                "access_token": .string(tokens.accessToken),
                "refresh_token": .string(tokens.refreshToken),
                "id_token": .string(tokens.idToken),
                "account_id": .string("account-1")
            ])
        ])
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard let tokens = auth["tokens"]?.objectValue,
              let accessToken = tokens["access_token"]?.stringValue,
              let accountID = tokens["account_id"]?.stringValue else {
            throw AppError.invalidData("Missing test auth payload")
        }

        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: "test@example.com",
            planType: "team",
            teamName: nil,
            principalID: nil
        )
    }
}

private final class ReconciledPrincipalAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let payload) = auth,
              case .string(let slot)? = payload["slot"] else {
            throw AppError.invalidData("Missing test slot")
        }
        return ExtractedAuth(
            accountID: "workspace-1",
            accessToken: "token-\(slot)",
            email: "\(slot)@example.com",
            planType: "pro",
            teamName: nil,
            principalID: "principal-\(slot)"
        )
    }
}

private final class RecordingAuthRepository: AuthRepository, @unchecked Sendable {
    private(set) var writtenAccountCount = 0

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
        writtenAccountCount += 1
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        return ExtractedAuth(
            accountID: "account-1",
            accessToken: "token-1",
            email: "test@example.com",
            planType: "pro",
            teamName: "workspace-x"
        )
    }
}

private final class MultiAccountAuthRepository: AuthRepository, @unchecked Sendable {
    private let extractedByAccountID: [String: ExtractedAuth]

    init(extractedByAccountID: [String: ExtractedAuth]) {
        self.extractedByAccountID = extractedByAccountID
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"],
              let extracted = extractedByAccountID[accountID] else {
            throw AppError.invalidData("Missing extracted auth for test payload")
        }
        return extracted
    }
}

private final class RecordingMultiAccountAuthRepository: AuthRepository, @unchecked Sendable {
    private let extractedByAccountID: [String: ExtractedAuth]
    private(set) var writtenAccountIDs: [String] = []

    init(extractedByAccountID: [String: ExtractedAuth]) {
        self.extractedByAccountID = extractedByAccountID
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"] else {
            throw AppError.invalidData("Missing written auth payload for test")
        }
        writtenAccountIDs.append(accountID)
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"],
              let extracted = extractedByAccountID[accountID] else {
            throw AppError.invalidData("Missing extracted auth for test payload")
        }
        return extracted
    }
}

private final class MutableCurrentAuthRepository: AuthRepository, @unchecked Sendable {
    private let extractedByAccountID: [String: ExtractedAuth]
    private(set) var writtenAccountIDs: [String] = []
    private var currentAuth: JSONValue

    init(extractedByAccountID: [String: ExtractedAuth], currentAuth: JSONValue) {
        self.extractedByAccountID = extractedByAccountID
        self.currentAuth = currentAuth
    }

    func readCurrentAuth() throws -> JSONValue {
        currentAuth
    }

    func readCurrentAuthOptional() throws -> JSONValue? {
        currentAuth
    }

    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return currentAuth
    }

    func writeCurrentAuth(_ auth: JSONValue) throws {
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"] else {
            throw AppError.invalidData("Missing written auth payload for test")
        }
        currentAuth = auth
        writtenAccountIDs.append(accountID)
    }

    func removeCurrentAuth() throws {}

    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }

    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"],
              let extracted = extractedByAccountID[accountID] else {
            throw AppError.invalidData("Missing extracted auth for test payload")
        }
        return extracted
    }
}

private final class RecordingSharedIdentityAuthRepository: AuthRepository, @unchecked Sendable {
    private(set) var writtenSlots: [String] = []

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        guard case .object(let payload) = auth,
              case .string(let slot)? = payload["slot"] else {
            throw AppError.invalidData("Missing written auth slot for test")
        }
        writtenSlots.append(slot)
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"] else {
            throw AppError.invalidData("Missing extracted auth account for test")
        }
        return ExtractedAuth(
            accountID: accountID,
            accessToken: "token-\(accountID)",
            email: nil,
            planType: "pro",
            teamName: nil,
            principalID: nil
        )
    }
}

private func makeTestFileSystemPaths() -> FileSystemPaths {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return FileSystemPaths(
        applicationSupportDirectory: tempDir,
        accountStorePath: tempDir.appendingPathComponent("accounts.json"),
        settingsStorePath: tempDir.appendingPathComponent("settings.json"),
        codexAuthPath: tempDir.appendingPathComponent("auth.json"),
        codexConfigPath: tempDir.appendingPathComponent("config.toml"),
        proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
        proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
        cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
    )
}

private final class URLMappedAuthRepository: AuthRepository, @unchecked Sendable {
    private let currentAuth: JSONValue
    private let importedAuthByURL: [URL: JSONValue]
    private let extractedByAccessToken: [String: ExtractedAuth]

    init(
        currentAuth: JSONValue,
        importedAuthByURL: [URL: JSONValue],
        extractedByAccessToken: [String: ExtractedAuth]
    ) {
        self.currentAuth = currentAuth
        self.importedAuthByURL = importedAuthByURL
        self.extractedByAccessToken = extractedByAccessToken
    }

    func readCurrentAuth() throws -> JSONValue { currentAuth }
    func readCurrentAuthOptional() throws -> JSONValue? { currentAuth }
    func readAuth(from url: URL) throws -> JSONValue {
        guard let auth = importedAuthByURL[url] else {
            throw AppError.io("Missing test auth for URL \(url.path)")
        }
        return auth
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard let accessToken = auth["tokens"]?["access_token"]?.stringValue,
              let extracted = extractedByAccessToken[accessToken] else {
            throw AppError.invalidData("Missing extracted auth for test access token")
        }
        return extracted
    }
}

private final class TokenMappedAuthRepository: AuthRepository, @unchecked Sendable {
    private let extractedByAccessToken: [String: ExtractedAuth]

    init(extractedByAccessToken: [String: ExtractedAuth]) {
        self.extractedByAccessToken = extractedByAccessToken
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        .object([
            "tokens": .object([
                "access_token": .string(tokens.accessToken),
                "refresh_token": .string(tokens.refreshToken),
                "id_token": .string(tokens.idToken)
            ])
        ])
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard let accessToken = auth["tokens"]?["access_token"]?.stringValue,
              let extracted = extractedByAccessToken[accessToken] else {
            throw AppError.invalidData("Missing extracted auth for test access token")
        }
        return extracted
    }
}

private final class RefreshingAuthRepository: AuthRepository, @unchecked Sendable {
    private let refreshedAuth: JSONValue
    private var refreshCallCount = 0

    init(refreshedAuth: JSONValue) {
        self.refreshedAuth = refreshedAuth
    }

    func readCurrentAuth() throws -> JSONValue { refreshedAuth }
    func readCurrentAuthOptional() throws -> JSONValue? { refreshedAuth }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return refreshedAuth
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return refreshedAuth
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard let tokens = auth["tokens"]?.objectValue,
              let accessToken = tokens["access_token"]?.stringValue,
              let accountID = tokens["account_id"]?.stringValue else {
            throw AppError.invalidData("Missing test auth payload")
        }
        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: "test@example.com",
            planType: "team",
            teamName: nil,
            principalID: nil
        )
    }
    func refreshChatGPTAuth(_ auth: JSONValue) async throws -> JSONValue {
        _ = auth
        refreshCallCount += 1
        return refreshedAuth
    }
    func readRefreshCallCount() -> Int {
        refreshCallCount
    }
}

private final class FailingRefreshingAuthRepository: AuthRepository, @unchecked Sendable {
    private let message: String
    private var refreshCallCount = 0

    init(message: String) {
        self.message = message
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard let tokens = auth["tokens"]?.objectValue,
              let accessToken = tokens["access_token"]?.stringValue,
              let accountID = tokens["account_id"]?.stringValue else {
            throw AppError.invalidData("Missing test auth payload")
        }
        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: "test@example.com",
            planType: "team",
            teamName: nil,
            principalID: nil
        )
    }
    func refreshChatGPTAuth(_ auth: JSONValue) async throws -> JSONValue {
        _ = auth
        refreshCallCount += 1
        throw AppError.unauthorized(message)
    }
    func readRefreshCallCount() -> Int {
        refreshCallCount
    }
}

private actor PartialUpdateRecorder {
    private var snapshots: [[AccountSummary]] = []

    func record(_ accounts: [AccountSummary]) {
        snapshots.append(accounts)
    }

    func values() -> [[AccountSummary]] {
        snapshots
    }
}

private final class StubChatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol, @unchecked Sendable {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        return ChatGPTOAuthTokens(accessToken: "", refreshToken: "", idToken: "", apiKey: nil)
    }
}

private final class FixedChatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol, @unchecked Sendable {
    private let tokens: ChatGPTOAuthTokens

    init(tokens: ChatGPTOAuthTokens) {
        self.tokens = tokens
    }

    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        return tokens
    }
}

private actor RecordingCurrentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol {
    private var recordedAccountIDs: [String] = []
    private var pushCallCount = 0

    func recordLocalSelection(cardID: String) async throws {
        recordedAccountIDs.append(cardID)
    }

    func pushLocalSelectionIfNeeded() async throws {
        pushCallCount += 1
    }

    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult {
        .noChange
    }

    func ensurePushSubscriptionIfNeeded() async throws {}

    func readRecordedAccountIDs() -> [String] {
        recordedAccountIDs
    }

    func readPushCallCount() -> Int {
        pushCallCount
    }
}

private actor FailingCurrentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func recordLocalSelection(cardID: String) async throws {
        _ = cardID
        throw AppError.io(message)
    }

    func pushLocalSelectionIfNeeded() async throws {
        throw AppError.io(message)
    }

    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult {
        .noChange
    }

    func ensurePushSubscriptionIfNeeded() async throws {}
}

private actor PushDrivenCurrentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol {
    private let remoteCardID: String
    private let remoteSelection: CurrentAccountSelection
    private var ensurePushSubscriptionCallCount = 0
    private var pullCallCount = 0

    init(
        remoteCardID: String,
        remoteSelection: CurrentAccountSelection
    ) {
        self.remoteCardID = remoteCardID
        self.remoteSelection = remoteSelection
    }

    func recordLocalSelection(cardID: String) async throws {
        _ = cardID
    }

    func pushLocalSelectionIfNeeded() async throws {}

    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult {
        pullCallCount += 1
        return CurrentAccountSelectionPullResult(
            didUpdateSelection: true,
            changedCurrentAccount: false,
            cardID: remoteCardID
        )
    }

    func ensurePushSubscriptionIfNeeded() async throws {
        ensurePushSubscriptionCallCount += 1
    }

    func readEnsurePushSubscriptionCallCount() -> Int {
        ensurePushSubscriptionCallCount
    }

    func readPullCallCount() -> Int {
        pullCallCount
    }
}

private actor SameCycleRemoteOverrideCurrentSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol {
    private let remoteCardID: String
    private let remoteSelection: CurrentAccountSelection
    private var pullCallCount = 0

    init(
        remoteCardID: String,
        remoteSelection: CurrentAccountSelection
    ) {
        self.remoteCardID = remoteCardID
        self.remoteSelection = remoteSelection
    }

    func recordLocalSelection(cardID: String) async throws {
        _ = cardID
    }

    func pushLocalSelectionIfNeeded() async throws {}

    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult {
        pullCallCount += 1
        guard pullCallCount > 1 else { return .noChange }
        return CurrentAccountSelectionPullResult(
            didUpdateSelection: true,
            changedCurrentAccount: true,
            cardID: remoteCardID
        )
    }

    func ensurePushSubscriptionIfNeeded() async throws {}
}

private actor WorkspaceLoginRecorder {
    private var forcedWorkspaceIDs: [String] = []

    func record(_ forcedWorkspaceID: String?) {
        if let forcedWorkspaceID {
            forcedWorkspaceIDs.append(forcedWorkspaceID)
        }
    }

    func values() -> [String] {
        forcedWorkspaceIDs
    }
}

private actor HangingLoginState {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func markStarted() {
        hasStarted = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private final class HangingChatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol, @unchecked Sendable {
    private let state = HangingLoginState()

    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        await state.markStarted()
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        return ChatGPTOAuthTokens(accessToken: "", refreshToken: "", idToken: "", apiKey: nil)
    }

    func waitUntilStarted() async {
        await state.waitUntilStarted()
    }
}

private final class RecordingWorkspaceAwareChatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol, @unchecked Sendable {
    private let defaultTokens: ChatGPTOAuthTokens
    private let tokensByWorkspaceID: [String: ChatGPTOAuthTokens]
    private let recorder = WorkspaceLoginRecorder()

    init(
        defaultTokens: ChatGPTOAuthTokens,
        tokensByWorkspaceID: [String: ChatGPTOAuthTokens]
    ) {
        self.defaultTokens = defaultTokens
        self.tokensByWorkspaceID = tokensByWorkspaceID
    }

    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        return defaultTokens
    }

    func signInWithChatGPT(
        timeoutSeconds: TimeInterval,
        forcedWorkspaceID: String?
    ) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        await recorder.record(forcedWorkspaceID)
        guard let forcedWorkspaceID else { return defaultTokens }
        return tokensByWorkspaceID[forcedWorkspaceID] ?? defaultTokens
    }

    func readForcedWorkspaceIDs() async -> [String] {
        await recorder.values()
    }
}

private final class StubCodexCLIService: CodexCLIServiceProtocol, @unchecked Sendable {
    func launchApp(workspacePath: String?) throws -> Bool {
        _ = workspacePath
        return false
    }
}

private final class RecordingCodexCLIService: CodexCLIServiceProtocol, @unchecked Sendable {
    private(set) var launchCallCount = 0

    func launchApp(workspacePath: String?) throws -> Bool {
        _ = workspacePath
        launchCallCount += 1
        return false
    }
}

private final class StubEditorAppService: EditorAppServiceProtocol, @unchecked Sendable {
    func listInstalledApps() -> [InstalledEditorApp] { [] }
    func restartSelectedApps(_ targets: [EditorAppID]) -> (restarted: [EditorAppID], error: String?) {
        _ = targets
        return ([], nil)
    }
}

private final class RecordingEditorAppService: EditorAppServiceProtocol, @unchecked Sendable {
    private(set) var restartCallCount = 0

    func listInstalledApps() -> [InstalledEditorApp] { [] }

    func restartSelectedApps(_ targets: [EditorAppID]) -> (restarted: [EditorAppID], error: String?) {
        _ = targets
        restartCallCount += 1
        return ([], nil)
    }
}

private final class StubOpencodeAuthSyncService: OpencodeAuthSyncServiceProtocol, @unchecked Sendable {
    func syncFromCodexAuth(_ authJSON: JSONValue) throws {
        _ = authJSON
    }
}

private actor SpyAccountsCloudSyncService: AccountsCloudSyncServiceProtocol {
    private(set) var pushCallCount = 0
    private(set) var pullCallCount = 0
    private let pullResult: AccountsCloudSyncPullResult

    init(pullResult: AccountsCloudSyncPullResult) {
        self.pullResult = pullResult
    }

    func pushLocalAccountsIfNeeded() async throws {
        pushCallCount += 1
    }

    func pullRemoteAccountsIfNeeded(
        currentTime: Int64,
        maximumSnapshotAgeSeconds: Int64
    ) async throws -> AccountsCloudSyncPullResult {
        _ = currentTime
        _ = maximumSnapshotAgeSeconds
        pullCallCount += 1
        return pullResult
    }

    func ensurePushSubscriptionIfNeeded() async throws {}

    func readPushCallCount() -> Int {
        pushCallCount
    }

    func readPullCallCount() -> Int {
        pullCallCount
    }
}

private final class StubLaunchAtStartupService: LaunchAtStartupServiceProtocol, @unchecked Sendable {
    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        _ = enabled
    }
}
