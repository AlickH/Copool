import XCTest
@testable import Copool

final class StoreFileRepositoryTests: XCTestCase {
    func testLoadStoreTreatsTrailingGarbageAsCorruption() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let raw = "{\"version\":1,\"accounts\":[],\"settings\":{\"launchAtStartup\":false,\"trayUsageDisplayMode\":\"remaining\",\"launchCodexAfterSwitch\":true,\"syncOpencodeOpenaiAuth\":false,\"restartEditorsOnSwitch\":false,\"restartEditorTargets\":[],\"autoStartApiProxy\":false,\"remoteServers\":[],\"locale\":\"zh-CN\"}}\nINVALID".data(using: .utf8)!
        try raw.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()

        XCTAssertEqual(store, AccountsStore())
        let rewritten = try Data(contentsOf: storePath)
        XCTAssertEqual(try JSONDecoder().decode(AccountsStore.self, from: rewritten), AccountsStore())

        let backups = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("accounts.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), raw)
    }

    func testLoadStoreBacksUpInvalidStoreAndResetsPrimaryStore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let invalid = "{\"version\":1,\"accounts\":[".data(using: .utf8)!
        try invalid.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()

        XCTAssertEqual(store, AccountsStore())
        let rewritten = try Data(contentsOf: storePath)
        XCTAssertNotEqual(rewritten, invalid)
        XCTAssertEqual(try JSONDecoder().decode(AccountsStore.self, from: rewritten), AccountsStore())

        let backups = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("accounts.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), invalid)
    }

    func testLoadStoreDecodesLegacyIdentityShapeWithoutPrincipalOrSelectionKey() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let legacyRoot: [String: Any] = [
            "version": 1,
            "accounts": [
                StoredAccount(
                    id: "acct-1",
                    label: "Legacy",
                    email: "legacy@example.com",
                    accountID: "legacy-account",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: 1,
                    updatedAt: 2,
                    usage: nil,
                    usageError: nil,
                    principalID: nil
                )
            ].map { account in
                try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(account)) as! [String: Any]
            },
            "currentSelection": [
                "accountId": "legacy-account",
                "selectedAt": 123,
                "sourceDeviceID": "device-a",
                "accountKey": "legacy-account"
            ],
            "settings": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaultValue))
        ]
        var root = legacyRoot
        var accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
        accounts[0].removeValue(forKey: "principalId")
        root["accounts"] = accounts
        var currentSelection = try XCTUnwrap(root["currentSelection"] as? [String: Any])
        currentSelection.removeValue(forKey: "accountKey")
        root["currentSelection"] = currentSelection
        let raw = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try raw.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()
        let summaries = store.accountSummaries()

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertNil(store.accounts[0].principalID)
        XCTAssertNil(store.currentAccountID)
        XCTAssertEqual(store.currentSelection?.cardID, "legacy-account")
        XCTAssertTrue(summaries.filter(\.isCurrent).isEmpty)
    }

    func testLoadStoreUsesCurrentAccountIDAsSingleCurrentSource() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let raw = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "currentAccountId": "acct-2",
                "accounts": [
                    [
                        "id": "acct-1",
                        "label": "First",
                        "email": "first@example.com",
                        "accountId": "account-1",
                        "planType": "pro",
                        "authJson": [:],
                        "addedAt": 1,
                        "updatedAt": 1,
                        "workspaceStatus": "active",
                        "displayStatus": "list"
                    ],
                    [
                        "id": "acct-2",
                        "label": "Second",
                        "email": "second@example.com",
                        "accountId": "account-2",
                        "planType": "pro",
                        "authJson": [:],
                        "addedAt": 2,
                        "updatedAt": 2,
                        "workspaceStatus": "active",
                        "displayStatus": "list"
                    ]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try raw.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()
        let summaries = store.accountSummaries()

        XCTAssertEqual(summaries.filter(\.isCurrent).map(\.id), ["acct-2"])
    }

    func testLoadStoreDefaultsMissingWorkspaceStatusToActive() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let account = StoredAccount(
            id: "acct-1",
            label: "Legacy",
            email: "legacy@example.com",
            accountID: "legacy-account",
            planType: "team",
            teamName: "workspace-a",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        var rawAccount = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        )
        rawAccount.removeValue(forKey: "workspaceStatus")
        let raw = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "accounts": [rawAccount]
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try raw.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].workspaceStatus, .active)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                .contains(where: { $0.lastPathComponent.hasPrefix("accounts.corrupt-") })
        )
    }

    func testStoreRoundTripsWorkspaceDirectoryEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )
        let repository = StoreFileRepository(paths: paths)
        let store = AccountsStore(
            version: 1,
            accounts: [],
            workspaceDirectory: [
                WorkspaceDirectoryEntry(
                    workspaceID: "workspace-1",
                    workspaceName: "Workspace One",
                    email: "team@example.com",
                    planType: "team",
                    kind: .workspace,
                    status: .deactivated,
                    visibility: .deleted,
                    lastSeenAt: 123,
                    lastStatusCheckedAt: 456
                )
            ],
            currentSelection: nil
        )

        try repository.saveStore(store)
        let loaded = try repository.loadStore()

        XCTAssertEqual(loaded.workspaceDirectory, store.workspaceDirectory)
    }

    func testLoadSettingsMigratesLegacyMergedStoreIntoSeparateFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let settingsPath = tempDir.appendingPathComponent("settings.json")
        let legacySettings = AppSettings(
            launchAtStartup: true,
            launchCodexAfterSwitch: false,
            autoSmartSwitch: true,
            syncOpencodeOpenaiAuth: true,
            restartEditorsOnSwitch: true,
            restartEditorTargets: [.cursor],
            autoStartApiProxy: true,
            remoteServers: [],
            locale: AppLocale.english.identifier
        )
        let account = StoredAccount(
            id: "acct-1",
            label: "Legacy",
            email: "legacy@example.com",
            accountID: "legacy-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let legacyRoot: [String: Any] = [
            "version": 1,
            "accounts": [
                try! JSONSerialization.jsonObject(with: JSONEncoder().encode(account))
            ],
            "currentSelection": [
                "accountId": "legacy-account",
                "selectedAt": 123,
                "sourceDeviceID": "device-a"
            ],
            "settings": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(legacySettings))
        ]
        try JSONSerialization.data(withJSONObject: legacyRoot, options: [.prettyPrinted, .sortedKeys]).write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            settingsStorePath: settingsPath,
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let settingsRepository = SettingsFileRepository(paths: paths)
        let migrated = try settingsRepository.loadSettings()
        let migratedAccounts = try JSONDecoder().decode(AccountsStore.self, from: Data(contentsOf: storePath))
        let storedSettings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsPath))

        XCTAssertEqual(migrated, legacySettings)
        XCTAssertEqual(storedSettings, legacySettings)
        XCTAssertEqual(migratedAccounts.accounts, [account])
        XCTAssertEqual(migratedAccounts.currentSelection?.cardID, "legacy-account")
    }

    func testCloudKitAccountsStoreMergePreservesSelection() {
        let latestStore = AccountsStore(
            version: 1,
            accounts: [],
            currentSelection: CurrentAccountSelection(
                    cardID: "current-account",
                selectedAt: 123,
                sourceDeviceID: "device-a"
            )
        )
        let remoteAccounts = [
            StoredAccount(
                id: "acct-1",
                label: "Remote",
                email: "remote@example.com",
                accountID: "remote-account",
                planType: "pro",
                teamName: nil,
                teamAlias: nil,
                authJSON: .object([:]),
                addedAt: 1,
                updatedAt: 2,
                usage: nil,
                usageError: nil
            )
        ]

        let merged = CloudKitAccountsStoreMerge.applyingRemoteAccounts(remoteAccounts, to: latestStore)

        XCTAssertEqual(merged.accounts, remoteAccounts)
        XCTAssertEqual(merged.currentSelection, latestStore.currentSelection)
    }

    func testCloudKitAccountsStoreMergeKeepsLocalAccountsFromEmptyRemoteSnapshot() {
        let localAccount = StoredAccount(
            id: "acct-1",
            label: "Local",
            email: "local@example.com",
            accountID: "local-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let latestStore = AccountsStore(
            version: 1,
            accounts: [localAccount],
            currentSelection: CurrentAccountSelection(
                    cardID: "local-account",
                selectedAt: 123,
                sourceDeviceID: "device-a"
            )
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [],
            remoteSyncedAt: 999,
            to: latestStore
        )

        XCTAssertEqual(merged.accounts, [localAccount])
        XCTAssertEqual(merged.currentSelection, latestStore.currentSelection)
    }

    func testCloudKitAccountsStoreMergePrefersNewerRemoteUsageOverLocalMetadataTimestamp() {
        let localUsage = UsageSnapshot(
            fetchedAt: 100,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
            oneWeek: nil,
            credits: nil
        )
        let remoteUsage = UsageSnapshot(
            fetchedAt: 200,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 80, windowSeconds: 18_000, resetAt: nil),
            oneWeek: nil,
            credits: nil
        )
        let localAccount = StoredAccount(
            id: "local-id",
            label: "Local",
            email: "local@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: "Local Alias",
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 300,
            usage: localUsage,
            usageError: nil
        )
        let remoteAccount = StoredAccount(
            id: "remote-id",
            label: "Remote",
            email: "local@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 200,
            usage: remoteUsage,
            usageError: nil,
            principalID: "principal-1"
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [remoteAccount],
            remoteSyncedAt: 200,
            to: AccountsStore(
                version: 1,
                accounts: [localAccount],
                currentSelection: nil
            )
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].id, localAccount.id)
        XCTAssertEqual(merged.accounts[0].teamAlias, localAccount.teamAlias)
        XCTAssertEqual(merged.accounts[0].usage, remoteUsage)
    }

    func testCloudKitAccountsStoreMergePreservesDeletedDisplayStatus() {
        let localAccount = StoredAccount(
            id: "local-id",
            label: "Local",
            email: "local@example.com",
            accountID: "account-1",
            planType: "team",
            teamName: "Hidden Space",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 100,
            usage: nil,
            usageError: nil,
            displayStatus: .deleted
        )
        let remoteAccount = StoredAccount(
            id: "remote-id",
            label: "Remote",
            email: "local@example.com",
            accountID: "account-1",
            planType: "team",
            teamName: "Hidden Space",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 200,
            usage: nil,
            usageError: nil,
            displayStatus: .list
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [remoteAccount],
            remoteSyncedAt: 200,
            to: AccountsStore(accounts: [localAccount])
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].displayStatus, .deleted)
    }

    func testCloudKitAccountsStoreMergePrefersSuccessfulUsageOverNewerRemoteUsageError() {
        let localUsage = UsageSnapshot(
            fetchedAt: 200,
            planType: "team",
            fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: 1_000),
            oneWeek: UsageWindow(usedPercent: 80, windowSeconds: 604_800, resetAt: 2_000),
            credits: nil
        )
        let localAccount = StoredAccount(
            id: "local-id",
            label: "Local",
            email: "local@example.com",
            accountID: "account-1",
            planType: "team",
            teamName: "WandaFox8745",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 200,
            usage: localUsage,
            usageError: nil
        )
        let remoteAccount = StoredAccount(
            id: "remote-id",
            label: "Remote",
            email: "local@example.com",
            accountID: "account-1",
            planType: "team",
            teamName: "WandaFox8745",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 300,
            usage: localUsage,
            usageError: "Usage API request failed: timeout"
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [remoteAccount],
            remoteSyncedAt: 300,
            to: AccountsStore(
                version: 1,
                accounts: [localAccount],
                currentSelection: nil
            )
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].usage, localUsage)
        XCTAssertNil(merged.accounts[0].usageError)
    }

    func testCloudKitAccountsStoreMergeKeepsRecentLocalOnlyAccounts() {
        let localOnlyAccount = StoredAccount(
            id: "local-only",
            label: "Local",
            email: "local@example.com",
            accountID: "local-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 500,
            usage: nil,
            usageError: nil
        )
        let remoteAccount = StoredAccount(
            id: "remote-only",
            label: "Remote",
            email: "remote@example.com",
            accountID: "remote-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 200,
            usage: nil,
            usageError: nil
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [remoteAccount],
            remoteSyncedAt: 200,
            to: AccountsStore(
                version: 1,
                accounts: [localOnlyAccount],
                currentSelection: nil
            )
        )

        XCTAssertEqual(merged.accounts.map(\.accountID), ["remote-account", "local-account"])
    }

    func testCloudKitAccountsStoreMergePreservesLocalWorkspaceMetadataWhenRemoteValueIsEmpty() {
        let localAccount = StoredAccount(
            id: "local-id",
            label: "Local",
            email: "local@example.com",
            accountID: "account-1",
            planType: "team",
            teamName: "workspace-a",
            teamAlias: "Alias A",
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 100,
            usage: nil,
            usageError: nil,
            principalID: "principal-1"
        )
        let remoteAccount = StoredAccount(
            id: "remote-id",
            label: "Remote",
            email: "local@example.com",
            accountID: "account-1",
            planType: "team",
            teamName: nil,
            teamAlias: "   ",
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 200,
            usage: nil,
            usageError: nil,
            principalID: "principal-1"
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [remoteAccount],
            remoteSyncedAt: 200,
            to: AccountsStore(
                version: 1,
                accounts: [localAccount],
                currentSelection: nil
            )
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].teamName, "workspace-a")
        XCTAssertEqual(merged.accounts[0].teamAlias, "Alias A")
    }

    func testCloudKitAccountsStoreMergeKeepsAccountsWithSameAccountIDDifferentPrincipals() {
        let localAccount = StoredAccount(
            id: "local-id",
            label: "Local",
            email: "local@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 500,
            usage: nil,
            usageError: nil,
            principalID: "principal-local"
        )
        let remoteAccount = StoredAccount(
            id: "remote-id",
            label: "Remote",
            email: "remote@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 200,
            usage: nil,
            usageError: nil,
            principalID: "principal-remote"
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [remoteAccount],
            remoteSyncedAt: 200,
            to: AccountsStore(
                version: 1,
                accounts: [localAccount],
                currentSelection: nil
            )
        )

        XCTAssertEqual(merged.accounts.count, 2)
        XCTAssertEqual(
            Set(merged.accounts.map(\.accountKey)),
            Set([localAccount.accountKey, remoteAccount.accountKey])
        )
    }

    func testAccountSummariesMarkOnlyMatchingVariantAsCurrent() {
        let firstAccount = StoredAccount(
            id: "acct-1",
            label: "First",
            email: "first@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 1,
            usage: nil,
            usageError: nil,
            principalID: "principal-1"
        )
        let secondAccount = StoredAccount(
            id: "acct-2",
            label: "Second",
            email: "second@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 1,
            usage: nil,
            usageError: nil,
            principalID: "principal-2"
        )
        let store = AccountsStore(
            version: 1,
            accounts: [firstAccount, secondAccount],
            currentAccountID: secondAccount.id,
            currentSelection: CurrentAccountSelection(
                cardID: secondAccount.id,
                selectedAt: 123,
                sourceDeviceID: "device-a"
            )
        )

        let summaries = store.accountSummaries()

        XCTAssertEqual(summaries.filter(\.isCurrent).count, 1)
        XCTAssertEqual(summaries.first(where: \.isCurrent)?.id, secondAccount.id)
    }

    func testCloudKitSelectionMergeOnlyAppliesNewerSelection() {
        let local = CurrentAccountSelection(
                    cardID: "account-a",
            selectedAt: 100,
            sourceDeviceID: "device-a"
        )
        let remoteSameTimestamp = CurrentAccountSelection(
                    cardID: "account-b",
            selectedAt: 100,
            sourceDeviceID: "device-z"
        )
        let newerRemote = CurrentAccountSelection(
                    cardID: "account-c",
            selectedAt: 101,
            sourceDeviceID: "device-x"
        )

        XCTAssertFalse(
            CloudKitSelectionMerge.shouldApplyRemoteSelection(
                remoteSameTimestamp,
                over: local
            )
        )
        XCTAssertFalse(
            CloudKitSelectionMerge.shouldKeepServerSelection(
                remoteSameTimestamp,
                over: local
            )
        )
        XCTAssertTrue(
            CloudKitSelectionMerge.shouldApplyRemoteSelection(
                newerRemote,
                over: local
            )
        )
        XCTAssertTrue(
            CloudKitSelectionMerge.shouldKeepServerSelection(
                newerRemote,
                over: local
            )
        )
    }

    func testAccountSummariesUseCurrentAccountIDAsSingleCurrentSource() {
        let account = StoredAccount(
            id: "acct-1",
            label: "Remote Selected",
            email: "remote@example.com",
            accountID: "remote-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let otherAccount = StoredAccount(
            id: "acct-2",
            label: "Local Auth",
            email: "local@example.com",
            accountID: "local-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [account, otherAccount],
            currentAccountID: account.id,
            currentSelection: CurrentAccountSelection(
                cardID: "remote-account",
                selectedAt: 123,
                sourceDeviceID: "device-a"
            )
        )

        let summaries = store.accountSummaries()

        XCTAssertEqual(
            summaries.first(where: { $0.accountID == "remote-account" })?.isCurrent,
            true
        )
        XCTAssertEqual(
            summaries.first(where: { $0.accountID == "local-account" })?.isCurrent,
            false
        )
    }
}
