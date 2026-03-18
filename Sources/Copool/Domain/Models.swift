import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case accounts
    case inviteTool
    case proxy
    case settings

    var id: String { rawValue }
}

struct AccountsStore: Codable, Equatable {
    var version: Int = 1
    var accounts: [StoredAccount] = []
    var currentSelection: CurrentAccountSelection?
    var settings: AppSettings = .defaultValue
}

struct CurrentAccountSelection: Codable, Equatable {
    var accountID: String
    var selectedAt: Int64
    var sourceDeviceID: String
}

struct CurrentAccountSelectionPullResult: Equatable, Sendable {
    var didUpdateSelection: Bool
    var changedCurrentAccount: Bool
    var accountID: String?

    static let noChange = CurrentAccountSelectionPullResult(
        didUpdateSelection: false,
        changedCurrentAccount: false,
        accountID: nil
    )
}

struct StoredAccount: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var email: String?
    var accountID: String
    var planType: String?
    var teamName: String?
    var teamAlias: String?
    var authJSON: JSONValue
    var addedAt: Int64
    var updatedAt: Int64
    var usage: UsageSnapshot?
    var usageError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case email
        case accountID = "accountId"
        case planType
        case teamName
        case teamAlias
        case authJSON = "authJson"
        case addedAt
        case updatedAt
        case usage
        case usageError
    }
}

struct AccountSummary: Equatable, Identifiable {
    var id: String
    var label: String
    var email: String?
    var accountID: String
    var planType: String?
    var teamName: String?
    var teamAlias: String?
    var addedAt: Int64
    var updatedAt: Int64
    var usage: UsageSnapshot?
    var usageError: String?
    var isCurrent: Bool

    var displayTeamName: String? {
        if let alias = teamAlias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        if let teamName = teamName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !teamName.isEmpty {
            return teamName
        }
        return nil
    }
}

extension AccountsStore {
    func accountSummaries(currentAccountID: String?) -> [AccountSummary] {
        let resolvedCurrentAccountID = resolvedCurrentAccountID(fallbackAuthAccountID: currentAccountID)

        return accounts.map { account in
            AccountSummary(
                id: account.id,
                label: account.label,
                email: account.email,
                accountID: account.accountID,
                planType: account.planType,
                teamName: account.teamName,
                teamAlias: account.teamAlias,
                addedAt: account.addedAt,
                updatedAt: account.updatedAt,
                usage: account.usage,
                usageError: account.usageError,
                isCurrent: resolvedCurrentAccountID == account.accountID
            )
        }
    }

    private func resolvedCurrentAccountID(fallbackAuthAccountID: String?) -> String? {
        if let selection = currentSelection?.accountID,
           accounts.contains(where: { $0.accountID == selection }) {
            return selection
        }
        return fallbackAuthAccountID
    }
}

struct UsageSnapshot: Codable, Equatable {
    var fetchedAt: Int64
    var planType: String?
    var fiveHour: UsageWindow?
    var oneWeek: UsageWindow?
    var credits: CreditSnapshot?
}

struct UsageWindow: Codable, Equatable {
    var usedPercent: Double
    var windowSeconds: Int64
    var resetAt: Int64?
}

struct CreditSnapshot: Codable, Equatable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

struct ExtractedAuth: Equatable {
    var accountID: String
    var accessToken: String
    var email: String?
    var planType: String?
    var teamName: String?
}

struct ChatGPTOAuthTokens: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var apiKey: String?
}

enum EditorAppID: String, Codable, CaseIterable, Identifiable {
    case vscode
    case vscodeInsiders
    case cursor
    case antigravity
    case kiro
    case trae
    case qoder

    var id: String { rawValue }
}

struct InstalledEditorApp: Equatable, Identifiable {
    var id: EditorAppID
    var label: String
}

struct SwitchAccountExecutionResult: Equatable {
    var usedFallbackCLI: Bool
    var opencodeSynced: Bool
    var opencodeSyncError: String?
    var restartedEditorApps: [EditorAppID]
    var editorRestartError: String?

    static let idle = SwitchAccountExecutionResult(
        usedFallbackCLI: false,
        opencodeSynced: false,
        opencodeSyncError: nil,
        restartedEditorApps: [],
        editorRestartError: nil
    )
}

struct RemoteServerConfig: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var host: String
    var sshPort: Int
    var sshUser: String
    var authMode: String
    var identityFile: String?
    var privateKey: String?
    var password: String?
    var remoteDir: String
    var listenPort: Int
}

struct AppSettings: Codable, Equatable {
    var launchAtStartup: Bool
    var launchCodexAfterSwitch: Bool
    var autoSmartSwitch: Bool
    var syncOpencodeOpenaiAuth: Bool
    var restartEditorsOnSwitch: Bool
    var restartEditorTargets: [EditorAppID]
    var autoStartApiProxy: Bool
    var remoteServers: [RemoteServerConfig]
    var locale: String

    enum CodingKeys: String, CodingKey {
        case launchAtStartup
        case launchCodexAfterSwitch
        case autoSmartSwitch
        case syncOpencodeOpenaiAuth
        case restartEditorsOnSwitch
        case restartEditorTargets
        case autoStartApiProxy
        case remoteServers
        case locale
    }

    init(
        launchAtStartup: Bool,
        launchCodexAfterSwitch: Bool,
        autoSmartSwitch: Bool,
        syncOpencodeOpenaiAuth: Bool,
        restartEditorsOnSwitch: Bool,
        restartEditorTargets: [EditorAppID],
        autoStartApiProxy: Bool,
        remoteServers: [RemoteServerConfig],
        locale: String
    ) {
        self.launchAtStartup = launchAtStartup
        self.launchCodexAfterSwitch = launchCodexAfterSwitch
        self.autoSmartSwitch = autoSmartSwitch
        self.syncOpencodeOpenaiAuth = syncOpencodeOpenaiAuth
        self.restartEditorsOnSwitch = restartEditorsOnSwitch
        self.restartEditorTargets = restartEditorTargets
        self.autoStartApiProxy = autoStartApiProxy
        self.remoteServers = remoteServers
        self.locale = AppLocale.resolve(locale).identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.defaultValue

        launchAtStartup = try container.decodeIfPresent(Bool.self, forKey: .launchAtStartup) ?? fallback.launchAtStartup
        launchCodexAfterSwitch = try container.decodeIfPresent(Bool.self, forKey: .launchCodexAfterSwitch) ?? fallback.launchCodexAfterSwitch
        autoSmartSwitch = try container.decodeIfPresent(Bool.self, forKey: .autoSmartSwitch) ?? fallback.autoSmartSwitch
        syncOpencodeOpenaiAuth = try container.decodeIfPresent(Bool.self, forKey: .syncOpencodeOpenaiAuth) ?? fallback.syncOpencodeOpenaiAuth
        restartEditorsOnSwitch = try container.decodeIfPresent(Bool.self, forKey: .restartEditorsOnSwitch) ?? fallback.restartEditorsOnSwitch
        restartEditorTargets = try container.decodeIfPresent([EditorAppID].self, forKey: .restartEditorTargets) ?? fallback.restartEditorTargets
        autoStartApiProxy = try container.decodeIfPresent(Bool.self, forKey: .autoStartApiProxy) ?? fallback.autoStartApiProxy
        remoteServers = try container.decodeIfPresent([RemoteServerConfig].self, forKey: .remoteServers) ?? fallback.remoteServers

        let rawLocale = try container.decodeIfPresent(String.self, forKey: .locale) ?? fallback.locale
        locale = AppLocale.resolve(rawLocale).identifier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtStartup, forKey: .launchAtStartup)
        try container.encode(launchCodexAfterSwitch, forKey: .launchCodexAfterSwitch)
        try container.encode(autoSmartSwitch, forKey: .autoSmartSwitch)
        try container.encode(syncOpencodeOpenaiAuth, forKey: .syncOpencodeOpenaiAuth)
        try container.encode(restartEditorsOnSwitch, forKey: .restartEditorsOnSwitch)
        try container.encode(restartEditorTargets, forKey: .restartEditorTargets)
        try container.encode(autoStartApiProxy, forKey: .autoStartApiProxy)
        try container.encode(remoteServers, forKey: .remoteServers)
        try container.encode(locale, forKey: .locale)
    }

    static var defaultValue: AppSettings {
        AppSettings(
            launchAtStartup: false,
            launchCodexAfterSwitch: true,
            autoSmartSwitch: false,
            syncOpencodeOpenaiAuth: false,
            restartEditorsOnSwitch: false,
            restartEditorTargets: [],
            autoStartApiProxy: false,
            remoteServers: [],
            locale: AppLocale.systemDefault.identifier
        )
    }
}

struct AppSettingsPatch {
    var launchAtStartup: Bool? = nil
    var launchCodexAfterSwitch: Bool? = nil
    var autoSmartSwitch: Bool? = nil
    var syncOpencodeOpenaiAuth: Bool? = nil
    var restartEditorsOnSwitch: Bool? = nil
    var restartEditorTargets: [EditorAppID]? = nil
    var autoStartApiProxy: Bool? = nil
    var remoteServers: [RemoteServerConfig]? = nil
    var locale: String? = nil
}

struct ApiProxyStatus: Codable, Equatable {
    var running: Bool
    var port: Int?
    var apiKey: String?
    var baseURL: String?
    var availableAccounts: Int
    var activeAccountID: String?
    var activeAccountLabel: String?
    var lastError: String?

    static let idle = ApiProxyStatus(
        running: false,
        port: nil,
        apiKey: nil,
        baseURL: nil,
        availableAccounts: 0,
        activeAccountID: nil,
        activeAccountLabel: nil,
        lastError: nil
    )
}

enum CloudflaredTunnelMode: String, Codable, CaseIterable {
    case quick
    case named
}

struct StartCloudflaredTunnelInput: Codable, Equatable {
    var apiProxyPort: Int
    var useHTTP2: Bool
    var mode: CloudflaredTunnelMode
    var named: NamedCloudflaredTunnelInput?
}

struct NamedCloudflaredTunnelInput: Codable, Equatable {
    var apiToken: String
    var accountID: String
    var zoneID: String
    var hostname: String
}

struct CloudflaredStatus: Codable, Equatable {
    var installed: Bool
    var binaryPath: String?
    var running: Bool
    var tunnelMode: CloudflaredTunnelMode?
    var publicURL: String?
    var customHostname: String?
    var useHTTP2: Bool
    var lastError: String?

    static let idle = CloudflaredStatus(
        installed: false,
        binaryPath: nil,
        running: false,
        tunnelMode: nil,
        publicURL: nil,
        customHostname: nil,
        useHTTP2: false,
        lastError: nil
    )
}

struct RemoteProxyStatus: Codable, Equatable {
    var installed: Bool
    var serviceInstalled: Bool
    var running: Bool
    var enabled: Bool
    var serviceName: String
    var pid: Int?
    var baseURL: String
    var apiKey: String?
    var lastError: String?
}

struct ProxyControlSnapshot: Codable, Equatable {
    var syncedAt: Int64
    var sourceDeviceID: String
    var proxyStatus: ApiProxyStatus
    var preferredProxyPort: Int?
    var autoStartProxy: Bool
    var cloudflaredStatus: CloudflaredStatus
    var cloudflaredTunnelMode: CloudflaredTunnelMode
    var cloudflaredNamedInput: NamedCloudflaredTunnelInput
    var cloudflaredUseHTTP2: Bool
    var publicAccessEnabled: Bool
    var remoteServers: [RemoteServerConfig]
    var remoteStatuses: [String: RemoteProxyStatus]
    var remoteLogs: [String: String]
    var lastHandledCommandID: String?
    var lastCommandError: String?
}

enum ProxyControlCommandKind: String, Codable {
    case refreshStatus
    case startProxy
    case stopProxy
    case refreshAPIKey
    case setAutoStartProxy
    case installCloudflared
    case startCloudflared
    case stopCloudflared
    case refreshCloudflared
    case addRemoteServer
    case saveRemoteServer
    case removeRemoteServer
    case refreshRemote
    case deployRemote
    case startRemote
    case stopRemote
    case readRemoteLogs
}

struct ProxyControlCommand: Codable, Equatable, Identifiable {
    var id: String
    var createdAt: Int64
    var sourceDeviceID: String
    var kind: ProxyControlCommandKind
    var preferredProxyPort: Int?
    var autoStartProxy: Bool?
    var cloudflaredInput: StartCloudflaredTunnelInput?
    var remoteServer: RemoteServerConfig?
    var remoteServerID: String?
    var logLines: Int?
}

struct PendingUpdateInfo: Equatable {
    var currentVersion: String
    var latestVersion: String
    var releaseURL: String
    var notes: String?
    var publishedAt: String?
}
