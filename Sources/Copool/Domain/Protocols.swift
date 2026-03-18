import Foundation

protocol AccountsStoreRepository: Sendable {
    func loadStore() throws -> AccountsStore
    func saveStore(_ store: AccountsStore) throws
}

protocol AuthRepository: Sendable {
    func readCurrentAuth() throws -> JSONValue
    func readCurrentAuthOptional() throws -> JSONValue?
    func readAuth(from url: URL) throws -> JSONValue
    func writeCurrentAuth(_ auth: JSONValue) throws
    func removeCurrentAuth() throws
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth
    func currentAuthAccountID() -> String?
}

protocol UsageService: Sendable {
    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot
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
    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String
}

protocol UpdateCheckingService: Sendable {
    func checkForUpdates(currentVersion: String) async throws -> PendingUpdateInfo?
}

protocol CodexCLIServiceProtocol: Sendable {
    func launchApp(workspacePath: String?) throws -> Bool
}

protocol ChatGPTOAuthLoginServiceProtocol: Sendable {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens
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

protocol AccountsCloudSyncServiceProtocol: Sendable {
    func pushLocalAccountsIfNeeded() async throws
    func pullRemoteAccountsIfNeeded() async throws -> Bool
}

protocol CloudSyncAvailabilityServiceProtocol: Sendable {
    func isICloudAvailable() async -> Bool
}

protocol ProxyControlCloudSyncServiceProtocol: Sendable {
    func pushLocalSnapshot(_ snapshot: ProxyControlSnapshot) async throws
    func pullRemoteSnapshot() async throws -> ProxyControlSnapshot?
    func enqueueCommand(_ command: ProxyControlCommand) async throws
    func pullPendingCommand() async throws -> ProxyControlCommand?
    func ensurePushSubscriptionIfNeeded() async throws
}

protocol CurrentAccountSelectionSyncServiceProtocol: Sendable {
    func recordLocalSelection(accountID: String) async throws
    func pushLocalSelectionIfNeeded() async throws
    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult
    func ensurePushSubscriptionIfNeeded() async throws
}

protocol InviteToolServiceProtocol: Sendable {
    func redeem(code: String, email: String) async throws -> InviteToolResponsePayload
    func checkWarranty(code: String) async throws -> InviteToolResponsePayload
    func redeemWarranty(code: String, email: String, lastUsedEmail: String) async throws -> InviteToolResponsePayload
    func queryStatus(code: String) async throws -> InviteToolResponsePayload
}

@MainActor
protocol AccountsManualRefreshServiceProtocol: AnyObject {
    func performManualRefresh() async throws -> [AccountSummary]
}
