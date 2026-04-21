import XCTest
@testable import Copool

final class AccountsIdentityRegressionTests: XCTestCase {
    func testImportCurrentAuthKeepsDistinctPrincipalsForSameAccountID() async throws {
        let authRepository = IdentityRegressionAuthRepository()
        let storeRepository = IdentityRegressionStoreRepository()
        let coordinator = makeCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository
        )

        authRepository.currentAuth = makeAuth(
            principalID: "principal-1",
            email: "first@example.com",
            accountID: "shared-account"
        )
        _ = try await coordinator.importCurrentAuthAccount(customLabel: nil)

        authRepository.currentAuth = makeAuth(
            principalID: "principal-2",
            email: "second@example.com",
            accountID: "shared-account"
        )
        _ = try await coordinator.importCurrentAuthAccount(customLabel: nil)

        let store = try storeRepository.loadStore()
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(
            Set(store.accounts.map(\.accountKey)),
            Set([
                "principal-1|shared-account",
                "principal-2|shared-account"
            ])
        )
    }

    func testListAccountsMarksOnlyCurrentMatchingVariant() async throws {
        let authRepository = IdentityRegressionAuthRepository()
        let storeRepository = IdentityRegressionStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "First",
                        email: "first@example.com",
                        accountID: "shared-account",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: makeAuth(
                            principalID: "principal-1",
                            email: "first@example.com",
                            accountID: "shared-account"
                        ),
                        addedAt: 1,
                        updatedAt: 1,
                        usage: nil,
                        usageError: nil,
                        principalID: "principal-1"
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Second",
                        email: "second@example.com",
                        accountID: "shared-account",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: makeAuth(
                            principalID: "principal-2",
                            email: "second@example.com",
                            accountID: "shared-account"
                        ),
                        addedAt: 1,
                        updatedAt: 1,
                        usage: nil,
                        usageError: nil,
                        principalID: "principal-2"
                    )
                ],
                currentAccountID: "acct-2",
                currentSelection: nil
            )
        )
        authRepository.currentAuth = makeAuth(
            principalID: "principal-2",
            email: "second@example.com",
            accountID: "shared-account"
        )
        let coordinator = makeCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository
        )

        let accounts = try await coordinator.listAccounts()

        XCTAssertEqual(accounts.filter(\.isCurrent).count, 1)
        XCTAssertEqual(accounts.first(where: \.isCurrent)?.email, "second@example.com")
    }

    func testListAccountsKeepsCurrentCardIDWhenSelectionIsStale() async throws {
        let authRepository = IdentityRegressionAuthRepository()
        let storeRepository = IdentityRegressionStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Old Card",
                        email: "old@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: makeAuth(
                            principalID: "principal-1",
                            email: "old@example.com",
                            accountID: "account-1"
                        ),
                        addedAt: 1,
                        updatedAt: 1,
                        usage: nil,
                        usageError: nil,
                        principalID: "principal-1"
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "New Card",
                        email: "new@example.com",
                        accountID: "account-2",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: makeAuth(
                            principalID: "principal-2",
                            email: "new@example.com",
                            accountID: "account-2"
                        ),
                        addedAt: 2,
                        updatedAt: 2,
                        usage: nil,
                        usageError: nil,
                        principalID: "principal-2"
                    )
                ],
                currentAccountID: "acct-1",
                currentSelection: CurrentAccountSelection(
                    cardID: "account-2",
                    selectedAt: 2_000,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = makeCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository
        )

        let accounts = try await coordinator.listAccounts()

        XCTAssertEqual(accounts.filter(\.isCurrent).count, 1)
        XCTAssertEqual(accounts.first(where: \.isCurrent)?.id, "acct-1")
    }

    func testImportCurrentAuthPrefersExactPrincipalMatchOverLegacyWildcardRow() async throws {
        let authRepository = IdentityRegressionAuthRepository()
        let legacyAuth = makeAuth(
            principalID: "principal-1",
            email: "legacy@example.com",
            accountID: "shared-account"
        )
        let exactAuth = makeAuth(
            principalID: "principal-2",
            email: "exact@example.com",
            accountID: "shared-account"
        )
        let storeRepository = IdentityRegressionStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "legacy",
                        label: "Legacy",
                        email: nil,
                        accountID: "shared-account",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: legacyAuth,
                        addedAt: 1,
                        updatedAt: 1,
                        usage: nil,
                        usageError: nil,
                        principalID: nil
                    ),
                    StoredAccount(
                        id: "exact",
                        label: "Exact",
                        email: "exact@example.com",
                        accountID: "shared-account",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: exactAuth,
                        addedAt: 1,
                        updatedAt: 1,
                        usage: nil,
                        usageError: nil,
                        principalID: "principal-2"
                    )
                ],
                currentSelection: nil
            )
        )
        let coordinator = makeCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository
        )
        authRepository.currentAuth = makeAuth(
            principalID: "principal-2",
            email: "exact@example.com",
            accountID: "shared-account"
        )

        let imported = try await coordinator.importCurrentAuthAccount(customLabel: "Updated Exact")
        let store = try storeRepository.loadStore()

        XCTAssertEqual(imported.id, "exact")
        XCTAssertEqual(store.accounts.first(where: { $0.id == "exact" })?.label, "Updated Exact")
        XCTAssertNil(store.accounts.first(where: { $0.id == "legacy" })?.email)
    }

    private func makeCoordinator(
        storeRepository: IdentityRegressionStoreRepository,
        authRepository: IdentityRegressionAuthRepository
    ) -> AccountsCoordinator {
        AccountsCoordinator(
            storeRepository: storeRepository,
            settingsRepository: TestSettingsRepository(),
            authRepository: authRepository,
            usageService: IdentityRegressionUsageService(),
            chatGPTOAuthLoginService: IdentityRegressionLoginService(),
            codexCLIService: IdentityRegressionCodexCLIService(),
            editorAppService: IdentityRegressionEditorAppService(),
            opencodeAuthSyncService: IdentityRegressionOpencodeAuthSyncService(),
            dateProvider: IdentityRegressionDateProvider()
        )
    }

    private func makeAuth(principalID: String, email: String, accountID: String) -> JSONValue {
        .object([
            "principal_id": .string(principalID),
            "email": .string(email),
            "account_id": .string(accountID),
            "access_token": .string("token-\(principalID)"),
            "plan_type": .string("pro")
        ])
    }
}

private final class IdentityRegressionStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private var store: AccountsStore

    init(store: AccountsStore = AccountsStore()) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store
    }
}

private final class IdentityRegressionAuthRepository: AuthRepository, @unchecked Sendable {
    var currentAuth: JSONValue?

    func readCurrentAuth() throws -> JSONValue {
        guard let currentAuth else {
            throw AppError.fileNotFound("missing auth")
        }
        return currentAuth
    }

    func readCurrentAuthOptional() throws -> JSONValue? {
        currentAuth
    }

    func readAuth(from url: URL) throws -> JSONValue {
        try readCurrentAuth()
    }

    func writeCurrentAuth(_ auth: JSONValue) throws {
        currentAuth = auth
    }

    func removeCurrentAuth() throws {
        currentAuth = nil
    }

    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        .object([:])
    }

    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        ExtractedAuth(
            accountID: auth["account_id"]?.stringValue ?? "",
            accessToken: auth["access_token"]?.stringValue ?? "",
            email: auth["email"]?.stringValue,
            planType: auth["plan_type"]?.stringValue,
            teamName: auth["team_name"]?.stringValue,
            principalID: auth["principal_id"]?.stringValue
        )
    }

}

private struct IdentityRegressionUsageService: UsageService {
    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        UsageSnapshot(
            fetchedAt: 1,
            planType: "pro",
            fiveHour: nil,
            oneWeek: nil,
            credits: nil
        )
    }
}

private struct IdentityRegressionDateProvider: DateProviding {
    func unixSecondsNow() -> Int64 { 100 }
    func unixMillisecondsNow() -> Int64 { 100_000 }
}

private struct IdentityRegressionLoginService: ChatGPTOAuthLoginServiceProtocol {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        ChatGPTOAuthTokens(accessToken: "", refreshToken: "", idToken: "", apiKey: nil)
    }
}

private struct IdentityRegressionCodexCLIService: CodexCLIServiceProtocol {
    func launchApp(workspacePath: String?) throws -> Bool { false }
}

private struct IdentityRegressionEditorAppService: EditorAppServiceProtocol {
    func listInstalledApps() -> [InstalledEditorApp] { [] }
    func restartSelectedApps(_ targets: [EditorAppID]) -> (restarted: [EditorAppID], error: String?) {
        ([], nil)
    }
}

private struct IdentityRegressionOpencodeAuthSyncService: OpencodeAuthSyncServiceProtocol {
    func syncFromCodexAuth(_ authJSON: JSONValue) throws {}
}
