import Foundation

enum AccountWorkspaceStatus: String, Codable, Equatable {
    case active
    case deactivated
}

enum AccountDisplayStatus: String, Codable, Equatable {
    case list
    case pending
    case deactivated
    case deleted
}

enum WorkspaceDirectoryKind: String, Codable, Equatable {
    case workspace
    case personal
}

enum WorkspaceDirectoryStatus: String, Codable, Equatable {
    case unknown
    case active
    case deactivated
}

enum WorkspaceDirectoryVisibility: String, Codable, Equatable {
    case visible
    case deleted
}

enum WorkspaceDirectorySource: String, Codable, Equatable {
    case legacyMetadata
    case consent
    case deactivated
}

enum AccountPlanLabel {
    static func normalized(from planType: String?) -> String {
        let normalized = planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "free":
            return "FREE"
        case "plus":
            return "PLUS"
        case "pro":
            return "PRO"
        case "enterprise":
            return "ENTERPRISE"
        case "business":
            return "BUSINESS"
        default:
            return "TEAM"
        }
    }

    static func normalized(usagePlanType: String?, storedPlanType: String?) -> String {
        let usagePlanType = usagePlanType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let usagePlanType, !usagePlanType.isEmpty {
            return normalized(from: usagePlanType)
        }

        let storedPlanType = storedPlanType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedPlanType, !storedPlanType.isEmpty {
            return normalized(from: storedPlanType)
        }

        return normalized(from: nil as String?)
    }
}

enum WorkspaceDisplayName {
    static func normalized(from value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct WorkspaceDirectoryEntry: Codable, Equatable, Identifiable {
    var workspaceID: String
    var workspaceName: String?
    var email: String?
    var planType: String?
    var kind: WorkspaceDirectoryKind
    var source: WorkspaceDirectorySource = .legacyMetadata
    var status: WorkspaceDirectoryStatus = .unknown
    var visibility: WorkspaceDirectoryVisibility = .visible
    var lastSeenAt: Int64
    var lastStatusCheckedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case workspaceName
        case email
        case planType
        case kind
        case source
        case status
        case visibility
        case lastSeenAt
        case lastStatusCheckedAt
    }

    var id: String {
        workspaceID
    }

    init(
        workspaceID: String,
        workspaceName: String?,
        email: String?,
        planType: String?,
        kind: WorkspaceDirectoryKind,
        source: WorkspaceDirectorySource = .legacyMetadata,
        status: WorkspaceDirectoryStatus = .unknown,
        visibility: WorkspaceDirectoryVisibility = .visible,
        lastSeenAt: Int64,
        lastStatusCheckedAt: Int64?
    ) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.email = email
        self.planType = planType
        self.kind = kind
        self.source = source
        self.status = status
        self.visibility = visibility
        self.lastSeenAt = lastSeenAt
        self.lastStatusCheckedAt = lastStatusCheckedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        kind = try container.decode(WorkspaceDirectoryKind.self, forKey: .kind)
        source = try container.decodeIfPresent(WorkspaceDirectorySource.self, forKey: .source) ?? .legacyMetadata
        status = try container.decodeIfPresent(WorkspaceDirectoryStatus.self, forKey: .status) ?? .unknown
        visibility = try container.decodeIfPresent(WorkspaceDirectoryVisibility.self, forKey: .visibility) ?? .visible
        lastSeenAt = try container.decode(Int64.self, forKey: .lastSeenAt)
        lastStatusCheckedAt = try container.decodeIfPresent(Int64.self, forKey: .lastStatusCheckedAt)
    }
}

struct AccountsStore: Codable, Equatable {
    var version: Int = 1
    var accounts: [StoredAccount] = []
    var workspaceDirectory: [WorkspaceDirectoryEntry] = []
    var currentAccountID: String?
    var currentSelection: CurrentAccountSelection?

    enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case workspaceDirectory
        case currentAccountID = "currentAccountId"
        case currentSelection
    }

    init(
        version: Int = 1,
        accounts: [StoredAccount] = [],
        workspaceDirectory: [WorkspaceDirectoryEntry] = [],
        currentAccountID: String? = nil,
        currentSelection: CurrentAccountSelection? = nil
    ) {
        self.version = version
        self.accounts = accounts
        self.workspaceDirectory = workspaceDirectory
        self.currentAccountID = currentAccountID
        self.currentSelection = currentSelection
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accounts = try container.decodeIfPresent([StoredAccount].self, forKey: .accounts) ?? []
        workspaceDirectory = try container.decodeIfPresent([WorkspaceDirectoryEntry].self, forKey: .workspaceDirectory) ?? []
        currentSelection = try container.decodeIfPresent(CurrentAccountSelection.self, forKey: .currentSelection)
        currentAccountID = try container.decodeIfPresent(String.self, forKey: .currentAccountID)
    }
}

struct CurrentAccountSelection: Codable, Equatable, Sendable {
    var cardID: String
    var selectedAt: Int64
    var sourceDeviceID: String

    enum CodingKeys: String, CodingKey {
        case cardID = "cardId"
        case legacyAccountID = "accountId"
        case selectedAt
        case sourceDeviceID
    }

    init(cardID: String, selectedAt: Int64, sourceDeviceID: String) {
        self.cardID = cardID
        self.selectedAt = selectedAt
        self.sourceDeviceID = sourceDeviceID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardID = try container.decodeIfPresent(String.self, forKey: .cardID)
            ?? container.decode(String.self, forKey: .legacyAccountID)
        selectedAt = try container.decode(Int64.self, forKey: .selectedAt)
        sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardID, forKey: .cardID)
        try container.encode(selectedAt, forKey: .selectedAt)
        try container.encode(sourceDeviceID, forKey: .sourceDeviceID)
    }
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
    var usageStateUpdatedAt: Int64 = 0
    var workspaceStatus: AccountWorkspaceStatus = .active
    var displayStatus: AccountDisplayStatus = .list
    var principalID: String? = nil

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
        case usageStateUpdatedAt
        case workspaceStatus
        case displayStatus
        case principalID = "principalId"
    }

    var accountKey: String {
        AccountIdentity.key(for: self)
    }

    init(
        id: String,
        label: String,
        email: String?,
        accountID: String,
        planType: String?,
        teamName: String?,
        teamAlias: String?,
        authJSON: JSONValue,
        addedAt: Int64,
        updatedAt: Int64,
        usage: UsageSnapshot?,
        usageError: String?,
        usageStateUpdatedAt: Int64? = nil,
        workspaceStatus: AccountWorkspaceStatus = .active,
        displayStatus: AccountDisplayStatus = .list,
        principalID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.accountID = accountID
        self.planType = planType
        self.teamName = teamName
        self.teamAlias = teamAlias
        self.authJSON = authJSON
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.usage = usage
        self.usageError = usageError
        self.usageStateUpdatedAt = usageStateUpdatedAt
            ?? usage?.fetchedAt
            ?? (usageError == nil ? 0 : updatedAt)
        self.workspaceStatus = workspaceStatus
        self.displayStatus = displayStatus
        self.principalID = principalID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        accountID = try container.decode(String.self, forKey: .accountID)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        teamName = try container.decodeIfPresent(String.self, forKey: .teamName)
        teamAlias = try container.decodeIfPresent(String.self, forKey: .teamAlias)
        authJSON = try container.decode(JSONValue.self, forKey: .authJSON)
        addedAt = try container.decode(Int64.self, forKey: .addedAt)
        updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        usage = try container.decodeIfPresent(UsageSnapshot.self, forKey: .usage)
        usageError = try container.decodeIfPresent(String.self, forKey: .usageError)
        usageStateUpdatedAt = try container.decodeIfPresent(Int64.self, forKey: .usageStateUpdatedAt)
            ?? usage?.fetchedAt
            ?? (usageError == nil ? 0 : updatedAt)
        workspaceStatus = try container.decodeIfPresent(AccountWorkspaceStatus.self, forKey: .workspaceStatus) ?? .active
        displayStatus = try container.decodeIfPresent(AccountDisplayStatus.self, forKey: .displayStatus)
            ?? (workspaceStatus == .deactivated ? .deactivated : .list)
        principalID = try container.decodeIfPresent(String.self, forKey: .principalID)
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
    var workspaceStatus: AccountWorkspaceStatus = .active
    var displayStatus: AccountDisplayStatus = .list
    var isCurrent: Bool
    var principalID: String? = nil

    var accountKey: String {
        AccountIdentity.key(for: self)
    }

    var normalizedPlanLabel: String {
        AccountPlanLabel.normalized(
            usagePlanType: usage?.planType,
            storedPlanType: planType
        )
    }

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

    var shouldDisplayWorkspaceTag: Bool {
        switch normalizedPlanLabel {
        case "TEAM", "BUSINESS", "ENTERPRISE":
            return displayTeamName != nil
        default:
            return false
        }
    }

    var isWorkspaceDeactivated: Bool {
        if displayStatus == .deleted {
            return false
        }
        return displayStatus == .deactivated || workspaceStatus == .deactivated
    }

    var isPendingDisplay: Bool {
        displayStatus == .pending
    }

    var isHidden: Bool {
        displayStatus == .deleted
    }

    var isVisibleInMainList: Bool {
        displayStatus == .list
    }
}

extension AccountsStore {
    func accountSummaries() -> [AccountSummary] {
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
                workspaceStatus: account.workspaceStatus,
                displayStatus: account.displayStatus,
                isCurrent: currentAccountID == account.id,
                principalID: account.principalID
            )
        }
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
    var principalID: String? = nil

    var accountKey: String {
        AccountIdentity.key(for: self)
    }
}

struct WorkspaceMetadata: Equatable, Sendable {
    var accountID: String
    var workspaceName: String?
    var structure: String?
}

enum WorkspaceAuthorizationCandidateStatus: Equatable, Sendable {
    case pending
    case deactivated
}

struct WorkspaceAuthorizationCandidate: Equatable, Identifiable, Sendable {
    var workspaceID: String
    var workspaceName: String
    var email: String?
    var planType: String?
    var status: WorkspaceAuthorizationCandidateStatus = .pending

    var id: String {
        workspaceID
    }
}

struct ConsentWorkspaceOption: Equatable, Sendable {
    var workspaceID: String
    var workspaceName: String
    var kind: WorkspaceDirectoryKind
}

struct ChatGPTOAuthTokens: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var apiKey: String?
    var consentWorkspaces: [ConsentWorkspaceOption] = []
}
