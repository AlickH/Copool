import Foundation

protocol AccountsStoreRepository: Sendable {
    func loadStore() throws -> AccountsStore
    func saveStore(_ store: AccountsStore) throws
    func mutateStore(_ transform: (inout AccountsStore) throws -> Void) throws -> AccountsStore
}

extension AccountsStoreRepository {
    func mutateStore(_ transform: (inout AccountsStore) throws -> Void) throws -> AccountsStore {
        var store = try loadStore()
        try transform(&store)
        try saveStore(store)
        return store
    }
}

protocol SettingsRepository: Sendable {
    func loadSettings() throws -> AppSettings
    func saveSettings(_ settings: AppSettings) throws
}

protocol AuthRepository: Sendable {
    func readCurrentAuth() throws -> JSONValue
    func readCurrentAuthOptional() throws -> JSONValue?
    func readAuth(from url: URL) throws -> JSONValue
    func writeCurrentAuth(_ auth: JSONValue) throws
    func removeCurrentAuth() throws
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue
    func exchangeAuth(email: String, refreshToken: String) async throws -> JSONValue
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth
    func refreshChatGPTAuth(_ auth: JSONValue) async throws -> JSONValue
}

protocol UsageService: Sendable {
    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot
}

protocol WorkspaceMetadataService: Sendable {
    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata]
}

protocol DateProviding: Sendable {
    func unixSecondsNow() -> Int64
    func unixMillisecondsNow() -> Int64
}

extension DateProviding {
    func unixMillisecondsNow() -> Int64 {
        unixSecondsNow() * 1_000
    }
}

extension AuthRepository {
    func exchangeAuth(email: String, refreshToken: String) async throws -> JSONValue {
        _ = email
        _ = refreshToken
        throw AppError.invalidData(L10n.tr("error.opencode.missing_refresh_token"))
    }

    func readCurrentExtractedAuth() -> ExtractedAuth? {
        guard let auth = try? readCurrentAuthOptional(),
              let extracted = try? extractAuth(from: auth) else {
            return nil
        }
        return extracted
    }

    func currentAuthAccountKey() -> String? {
        readCurrentExtractedAuth()?.accountKey
    }

    func refreshChatGPTAuth(_ auth: JSONValue) async throws -> JSONValue {
        auth
    }
}

protocol ProxyRuntimeService: Sendable {
    func status() async -> ApiProxyStatus
    func start(preferredPort: Int?) async throws -> ApiProxyStatus
    func stop() async -> ApiProxyStatus
    func refreshAPIKey() async throws -> ApiProxyStatus
    func syncAccountsStore() async throws
}

protocol CloudflaredServiceProtocol: Sendable {
    func status() async -> CloudflaredStatus
    func install() async throws -> CloudflaredStatus
    func start(_ input: StartCloudflaredTunnelInput) async throws -> CloudflaredStatus
    func stop() async -> CloudflaredStatus
}

protocol RemoteProxyServiceProtocol: Sendable {
    func status(server: RemoteServerConfig) async -> RemoteProxyStatus
    func discover(server: RemoteServerConfig) async throws -> [DiscoveredRemoteProxyInstance]
    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func syncAccounts(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String
    func uninstall(server: RemoteServerConfig, removeRemoteDirectory: Bool) async throws -> RemoteProxyStatus
}

protocol RemoteAccountsMutationSyncServiceProtocol: Sendable {
    func syncConfiguredRemoteAccounts() async -> RemoteAccountsMutationSyncReport
}

protocol CodexCLIServiceProtocol: Sendable {
    func launchApp(workspacePath: String?) throws -> Bool
}

protocol ChatGPTOAuthLoginServiceProtocol: Sendable {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens
    func signInWithChatGPT(timeoutSeconds: TimeInterval, forcedWorkspaceID: String?) async throws -> ChatGPTOAuthTokens
}

extension ChatGPTOAuthLoginServiceProtocol {
    func signInWithChatGPT(timeoutSeconds: TimeInterval, forcedWorkspaceID: String?) async throws -> ChatGPTOAuthTokens {
        _ = forcedWorkspaceID
        return try await signInWithChatGPT(timeoutSeconds: timeoutSeconds)
    }
}

protocol EditorAppServiceProtocol: Sendable {
    func listInstalledApps() -> [InstalledEditorApp]
    func restartSelectedApps(_ targets: [EditorAppID]) -> (restarted: [EditorAppID], error: String?)
}

protocol OpencodeAuthSyncServiceProtocol: Sendable {
    func syncFromCodexAuth(_ authJSON: JSONValue) throws
}

protocol LaunchAtStartupServiceProtocol: Sendable {
    func setEnabled(_ enabled: Bool) throws
    func syncWithStoreValue(_ enabled: Bool) throws
}

protocol ProxyControlRemoteCommandServiceProtocol: Sendable {
    func pushLocalSnapshot(_ snapshot: ProxyControlSnapshot) async throws
    func pullRemoteSnapshot() async throws -> ProxyControlSnapshot?
    func enqueueCommand(_ command: ProxyControlCommand) async throws
    func pullPendingCommand() async throws -> ProxyControlCommand?
}

protocol ProxyLocalCommandServiceProtocol: Sendable {
    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot
}

@MainActor
protocol AccountsManualRefreshServiceProtocol: AnyObject {
    func performManualRefresh() async throws -> [AccountSummary]
    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary]
}

extension AccountsManualRefreshServiceProtocol {
    func performManualRefresh() async throws -> [AccountSummary] {
        try await performManualRefresh(onPartialUpdate: { _ in })
    }
}

@MainActor
protocol AccountsLocalMutationSyncServiceProtocol: AnyObject {
    func acceptLocalAccountsSnapshot(_ accounts: [AccountSummary])
    func syncLocalAccountsMutationNow() async
}
