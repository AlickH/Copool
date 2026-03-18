import XCTest
@testable import Copool

final class AccountsCoordinatorTests: XCTestCase {
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
            currentSelection: nil,
            settings: .defaultValue
        )
        let usageService = CountingUsageService(result: existingUsage)
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            authRepository: StubAuthRepository(),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            codexCLIService: StubCodexCLIService(),
            editorAppService: StubEditorAppService(),
            opencodeAuthSyncService: StubOpencodeAuthSyncService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.refreshAllUsage()
        XCTAssertEqual(usageService.callCount, 0)

        _ = try await coordinator.refreshAllUsage(force: true)
        XCTAssertEqual(usageService.callCount, 1)
    }

    func testSwitchAccountOnIOSSkipsMacOnlySideEffects() async throws {
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
            currentSelection: nil,
            settings: AppSettings(
                launchAtStartup: false,
                launchCodexAfterSwitch: true,
                autoSmartSwitch: false,
                syncOpencodeOpenaiAuth: false,
                restartEditorsOnSwitch: true,
                restartEditorTargets: [.cursor],
                autoStartApiProxy: false,
                remoteServers: [],
                locale: AppLocale.english.identifier
            )
        )
        let codexService = RecordingCodexCLIService()
        let editorService = RecordingEditorAppService()
        let authRepository = RecordingAuthRepository(currentAccountID: nil)
        let storeRepository = InMemoryAccountsStoreRepository(store: store)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
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

        XCTAssertEqual(authRepository.writtenAccountCount, 0)
        XCTAssertEqual(codexService.launchCallCount, 0)
        XCTAssertEqual(editorService.restartCallCount, 0)
        XCTAssertEqual(try storeRepository.loadStore().currentSelection?.accountID, account.accountID)
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

private struct FixedDateProvider: DateProviding {
    let now: Int64

    func unixSecondsNow() -> Int64 {
        now
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
            teamName: nil
        )
    }
    func currentAuthAccountID() -> String? { "account-1" }
}

private final class RecordingAuthRepository: AuthRepository, @unchecked Sendable {
    private(set) var writtenAccountCount = 0
    private let currentAccountIDValue: String?

    init(currentAccountID: String?) {
        self.currentAccountIDValue = currentAccountID
    }

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
            teamName: nil
        )
    }
    func currentAuthAccountID() -> String? { currentAccountIDValue }
}

private final class StubChatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol, @unchecked Sendable {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        return ChatGPTOAuthTokens(accessToken: "", refreshToken: "", idToken: "", apiKey: nil)
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
