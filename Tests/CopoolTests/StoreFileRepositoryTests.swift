import XCTest
@testable import Copool

final class StoreFileRepositoryTests: XCTestCase {
    func testExtractFirstJSONObjectDataCanRecoverTrailingGarbage() throws {
        let malformed = "{\"version\":1,\"accounts\":[],\"settings\":{\"launchAtStartup\":false,\"trayUsageDisplayMode\":\"remaining\",\"launchCodexAfterSwitch\":true,\"syncOpencodeOpenaiAuth\":false,\"restartEditorsOnSwitch\":false,\"restartEditorTargets\":[],\"autoStartApiProxy\":false,\"remoteServers\":[],\"locale\":\"zh-CN\"}} trailing text".data(using: .utf8)!

        let recovered = StoreFileRepository.extractFirstJSONObjectData(from: malformed)

        XCTAssertNotNil(recovered)
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(AccountsStore.self, from: recovered!))
    }

    func testLoadStoreRecoversWhenTrailingGarbageExists() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let raw = "{\"version\":1,\"accounts\":[],\"settings\":{\"launchAtStartup\":false,\"trayUsageDisplayMode\":\"remaining\",\"launchCodexAfterSwitch\":true,\"syncOpencodeOpenaiAuth\":false,\"restartEditorsOnSwitch\":false,\"restartEditorTargets\":[],\"autoStartApiProxy\":false,\"remoteServers\":[],\"locale\":\"zh-CN\"}}\nINVALID".data(using: .utf8)!
        try raw.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()

        XCTAssertEqual(store.version, 1)
        XCTAssertEqual(store.accounts.count, 0)
    }

    func testCloudKitAccountsStoreMergePreservesSelectionAndSettings() {
        let latestStore = AccountsStore(
            version: 1,
            accounts: [],
            currentSelection: CurrentAccountSelection(
                accountID: "current-account",
                selectedAt: 123,
                sourceDeviceID: "device-a"
            ),
            settings: AppSettings(
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
        XCTAssertEqual(merged.settings, latestStore.settings)
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
            email: "remote@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 200,
            usage: remoteUsage,
            usageError: nil
        )

        let merged = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            [remoteAccount],
            remoteSyncedAt: 200,
            to: AccountsStore(
                version: 1,
                accounts: [localAccount],
                currentSelection: nil,
                settings: .defaultValue
            )
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].id, localAccount.id)
        XCTAssertEqual(merged.accounts[0].teamAlias, localAccount.teamAlias)
        XCTAssertEqual(merged.accounts[0].usage, remoteUsage)
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
                currentSelection: nil,
                settings: .defaultValue
            )
        )

        XCTAssertEqual(merged.accounts.map(\.accountID), ["remote-account", "local-account"])
    }

    func testCloudKitSelectionMergeUsesDeterministicTieBreak() {
        let local = CurrentAccountSelection(
            accountID: "account-a",
            selectedAt: 100,
            sourceDeviceID: "device-a"
        )
        let remoteSameSecondHigherDevice = CurrentAccountSelection(
            accountID: "account-b",
            selectedAt: 100,
            sourceDeviceID: "device-z"
        )

        XCTAssertTrue(
            CloudKitSelectionMerge.shouldApplyRemoteSelection(
                remoteSameSecondHigherDevice,
                over: local
            )
        )
        XCTAssertTrue(
            CloudKitSelectionMerge.shouldKeepServerSelection(
                remoteSameSecondHigherDevice,
                over: local
            )
        )
    }

    func testAccountSummariesPreferStoredCurrentSelectionOverAuthFallback() {
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
            currentSelection: CurrentAccountSelection(
                accountID: "remote-account",
                selectedAt: 123,
                sourceDeviceID: "device-a"
            ),
            settings: .defaultValue
        )

        let summaries = store.accountSummaries(currentAccountID: "local-account")

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
