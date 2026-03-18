import Foundation
import CloudKit
import CryptoKit
#if os(macOS)
import Security
#endif

struct CloudSyncAvailabilityService: CloudSyncAvailabilityServiceProtocol {
    private let containerIdentifier = "iCloud.com.alick.copool"

    func isICloudAvailable() async -> Bool {
        guard Self.hasCloudKitEntitlement() else {
            return false
        }

        let container = CKContainer(identifier: containerIdentifier)
        return await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                continuation.resume(returning: status == .available)
            }
        }
    }

    private static func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) else {
            return false
        }

        if let services = value as? [String] {
            return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        }
        if let services = value as? NSArray {
            return services.contains { element in
                guard let service = element as? String else { return false }
                return service == "CloudKit" || service == "CloudKit-Anonymous"
            }
        }
        return false
        #else
        return true
        #endif
    }
}

actor CloudKitAccountsSyncService: AccountsCloudSyncServiceProtocol {
    private enum Constants {
        static let containerIdentifier = "iCloud.com.alick.copool"
        static let recordType = "AccountsSnapshot"
        static let recordName = "primary"
        static let payloadKey = "payload"
        static let syncedAtKey = "syncedAt"
        static let schemaVersion = 1
    }

    private struct SnapshotPayload: Codable {
        let schemaVersion: Int
        let syncedAt: Int64
        let accounts: [StoredAccount]
    }

    private let storeRepository: AccountsStoreRepository
    private let database: CKDatabase?
    private let dateProvider: DateProviding
    private var lastUploadedDigest: String?
    private var lastAppliedDigest: String?

    init(
        storeRepository: AccountsStoreRepository,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.storeRepository = storeRepository
        self.database = Self.makeDatabase()
        self.dateProvider = dateProvider
    }

    func pushLocalAccountsIfNeeded() async throws {
        guard database != nil else { return }
        let store = try storeRepository.loadStore()
        let accountsDigest = try digest(for: store.accounts)
        guard accountsDigest != lastUploadedDigest else { return }

        let payload = SnapshotPayload(
            schemaVersion: Constants.schemaVersion,
            syncedAt: dateProvider.unixSecondsNow(),
            accounts: store.accounts
        )
        let savedPayload = try await saveSnapshotRecord(payload)
        lastUploadedDigest = try digest(for: savedPayload.accounts)
    }

    func pullRemoteAccountsIfNeeded() async throws -> Bool {
        guard database != nil else { return false }
        guard let record = try await fetchRecordIfExists() else {
            return false
        }

        let localStore = try storeRepository.loadStore()

        guard let payloadData = record[Constants.payloadKey] as? Data,
              let payload = decodeSnapshotIfValid(from: payloadData) else {
            lastAppliedDigest = nil
            lastUploadedDigest = nil
            try await recoverInvalidRemoteSnapshotIfPossible(using: localStore)
            return false
        }
        let remoteDigest = try digest(for: payload.accounts)
        if remoteDigest == lastAppliedDigest {
            return false
        }

        let localDigest = try digest(for: localStore.accounts)
        if remoteDigest == localDigest {
            lastAppliedDigest = remoteDigest
            return false
        }

        var latestStore = try storeRepository.loadStore()
        let latestDigest = try digest(for: latestStore.accounts)
        if latestDigest == remoteDigest {
            lastAppliedDigest = remoteDigest
            return false
        }

        let mergedStore = CloudKitAccountsStoreMerge.applyingRemoteSnapshot(
            payload.accounts,
            remoteSyncedAt: payload.syncedAt,
            to: latestStore
        )
        guard mergedStore != latestStore else {
            lastAppliedDigest = remoteDigest
            return false
        }

        latestStore = mergedStore
        try storeRepository.saveStore(latestStore)
        lastAppliedDigest = remoteDigest
        return true
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Constants.recordName)
    }

    private func fetchRecordIfExists() async throws -> CKRecord? {
        guard let database else { return nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord?, any Error>) in
            database.fetch(withRecordID: recordID) { record, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: record)
            }
        }
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        guard let database else {
            throw AppError.io("CloudKit is unavailable for the current process.")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, any Error>) in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let savedRecord else {
                    continuation.resume(throwing: AppError.io("CloudKit did not return a saved accounts snapshot."))
                    return
                }
                continuation.resume(returning: savedRecord)
            }
        }
    }

    private func decodeSnapshot(from data: Data) throws -> SnapshotPayload {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SnapshotPayload.self, from: data)
        } catch {
            throw AppError.invalidData("CloudKit accounts snapshot is invalid: \(error.localizedDescription)")
        }
    }

    private func decodeSnapshotIfValid(from data: Data) -> SnapshotPayload? {
        do {
            return try decodeSnapshot(from: data)
        } catch {
            return nil
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw AppError.invalidData("Failed to serialize accounts snapshot: \(error.localizedDescription)")
        }
    }

    private func digest(for accounts: [StoredAccount]) throws -> String {
        let data = try encode(accounts)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func recoverInvalidRemoteSnapshotIfPossible(using localStore: AccountsStore) async throws {
        guard !localStore.accounts.isEmpty else { return }

        let payload = SnapshotPayload(
            schemaVersion: Constants.schemaVersion,
            syncedAt: dateProvider.unixSecondsNow(),
            accounts: localStore.accounts
        )
        let savedPayload = try await saveSnapshotRecord(payload)
        let savedDigest = try digest(for: savedPayload.accounts)
        lastUploadedDigest = savedDigest
        lastAppliedDigest = savedDigest
    }

    private func saveSnapshotRecord(_ payload: SnapshotPayload) async throws -> SnapshotPayload {
        let payloadData = try encode(payload)
        var record = try await fetchRecordIfExists() ?? CKRecord(
            recordType: Constants.recordType,
            recordID: recordID
        )

        for attempt in 0..<3 {
            record[Constants.payloadKey] = payloadData as CKRecordValue
            record[Constants.syncedAtKey] = payload.syncedAt as CKRecordValue

            do {
                _ = try await save(record)
                return payload
            } catch {
                guard attempt < 2, isSnapshotConflict(error) else {
                    throw error
                }

                record = try await snapshotConflictBaseRecord(from: error) ?? CKRecord(
                    recordType: Constants.recordType,
                    recordID: recordID
                )
            }
        }

        return payload
    }

    private func snapshotConflictBaseRecord(from error: Error) async throws -> CKRecord? {
        if let ckError = error as? CKError {
            if let serverRecord = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                return serverRecord
            }
            if ckError.code == .serverRecordChanged {
                return try await fetchRecordIfExists()
            }
        }
        return try await fetchRecordIfExists()
    }

    private func isSnapshotConflict(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .serverRecordChanged {
            return true
        }
        return ckError.localizedDescription.localizedCaseInsensitiveContains("oplock")
    }

    private static func makeDatabase() -> CKDatabase? {
        guard hasCloudKitEntitlement() else {
            return nil
        }
        let container = CKContainer(identifier: Constants.containerIdentifier)
        return container.privateCloudDatabase
    }

    private static func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) else {
            return false
        }

        if let services = value as? [String] {
            return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        }
        if let services = value as? NSArray {
            return services.contains { element in
                guard let service = element as? String else { return false }
                return service == "CloudKit" || service == "CloudKit-Anonymous"
            }
        }

        return false
        #else
        return true
        #endif
    }
}

actor CloudKitCurrentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol {
    private enum Constants {
        static let containerIdentifier = "iCloud.com.alick.copool"
        static let recordType = "CurrentAccountSelection"
        static let recordName = "primary"
        static let subscriptionID = "current-account-selection.primary.push"
        static let payloadKey = "payload"
        static let selectedAtKey = "selectedAt"
        static let schemaVersion = 1
        static let deviceIDDefaultsKey = "copool.current-selection.device-id"
    }

    private struct SelectionPayload: Codable {
        let schemaVersion: Int
        let selection: CurrentAccountSelection
    }

    private let storeRepository: AccountsStoreRepository
    private let authRepository: AuthRepository
    private let database: CKDatabase?
    private let dateProvider: DateProviding
    private let runtimePlatform: RuntimePlatform
    private let deviceID: String
    private var lastUploadedDigest: String?
    private var lastAppliedDigest: String?
    private var pushSubscriptionEnsured = false

    init(
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform
    ) {
        self.storeRepository = storeRepository
        self.authRepository = authRepository
        self.database = Self.makeDatabase()
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
        self.deviceID = Self.resolveDeviceID()
    }

    func recordLocalSelection(accountID: String) async throws {
        let store = try storeRepository.loadStore()
        guard store.accounts.contains(where: { $0.accountID == accountID }) else {
            throw AppError.invalidData("Cannot record a current account selection for an unknown account.")
        }

        let selection = CurrentAccountSelection(
            accountID: accountID,
            selectedAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: deviceID
        )
        try saveCurrentSelection(selection)
    }

    func pushLocalSelectionIfNeeded() async throws {
        guard database != nil else { return }
        guard let selection = try synchronizeLocalSelectionMetadata() else { return }

        let selectionDigest = try digest(for: selection)
        guard selectionDigest != lastUploadedDigest else { return }

        let pushedSelection = try await saveSelectionRecord(selection)
        let pushedDigest = try digest(for: pushedSelection)
        lastUploadedDigest = pushedDigest
        if pushedSelection == selection {
            lastAppliedDigest = pushedDigest
        }
    }

    func ensurePushSubscriptionIfNeeded() async throws {
        #if os(macOS)
        guard let database else { return }
        guard !pushSubscriptionEnsured else { return }

        let subscription = CKDatabaseSubscription(subscriptionID: Self.pushSubscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        let results = try await database.modifySubscriptions(
            saving: [subscription],
            deleting: []
        )
        guard let saveResult = results.saveResults[Self.pushSubscriptionID] else {
            throw AppError.io("CloudKit did not report a result for the current account selection push subscription.")
        }
        switch saveResult {
        case .success:
            pushSubscriptionEnsured = true
        case .failure(let error):
            throw error
        }
        #else
        pushSubscriptionEnsured = true
        #endif
    }

    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult {
        guard database != nil else { return .noChange }
        guard let record = try await fetchRecordIfExists() else {
            return .noChange
        }

        guard let payloadData = record[Constants.payloadKey] as? Data else {
            lastAppliedDigest = nil
            lastUploadedDigest = nil
            return .noChange
        }

        guard let remoteSelection = decodeSelectionIfValid(from: payloadData)?.selection else {
            lastAppliedDigest = nil
            lastUploadedDigest = nil
            return .noChange
        }
        let remoteDigest = try digest(for: remoteSelection)
        if remoteDigest == lastAppliedDigest {
            return .noChange
        }

        let store = try storeRepository.loadStore()
        let previousSelection = store.currentSelection
        if !CloudKitSelectionMerge.shouldApplyRemoteSelection(
            remoteSelection,
            over: store.currentSelection
        ) {
            if store.currentSelection == remoteSelection {
                lastAppliedDigest = remoteDigest
                lastUploadedDigest = remoteDigest
            }
            return .noChange
        }

        guard let matchingAccount = store.accounts.first(where: { $0.accountID == remoteSelection.accountID }) else {
            return .noChange
        }

        let appliedCurrentAccountID = localAppliedCurrentAccountID(fallingBackTo: previousSelection?.accountID)
        let changedCurrentAccount = appliedCurrentAccountID != remoteSelection.accountID
        if runtimePlatform == .macOS, appliedCurrentAccountID != remoteSelection.accountID {
            try authRepository.writeCurrentAuth(matchingAccount.authJSON)
        }

        try saveCurrentSelection(remoteSelection)
        lastAppliedDigest = remoteDigest
        lastUploadedDigest = remoteDigest
        return CurrentAccountSelectionPullResult(
            didUpdateSelection: changedCurrentAccount || previousSelection != remoteSelection,
            changedCurrentAccount: changedCurrentAccount,
            accountID: remoteSelection.accountID
        )
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Constants.recordName)
    }

    nonisolated static var pushSubscriptionID: String {
        Constants.subscriptionID
    }

    private func synchronizeLocalSelectionMetadata() throws -> CurrentAccountSelection? {
        let store = try storeRepository.loadStore()
        if let existing = store.currentSelection,
           store.accounts.contains(where: { $0.accountID == existing.accountID }) {
            return existing
        }

        guard runtimePlatform == .macOS,
              let currentAccountID = authRepository.currentAuthAccountID(),
              store.accounts.contains(where: { $0.accountID == currentAccountID }) else {
            return nil
        }

        let inferred = CurrentAccountSelection(
            accountID: currentAccountID,
            selectedAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: deviceID
        )
        try saveCurrentSelection(inferred)
        return inferred
    }

    private func localAppliedCurrentAccountID(fallingBackTo selectionAccountID: String?) -> String? {
        if runtimePlatform == .macOS,
           let currentAccountID = authRepository.currentAuthAccountID(),
           !currentAccountID.isEmpty {
            return currentAccountID
        }
        return selectionAccountID
    }

    private func fetchRecordIfExists() async throws -> CKRecord? {
        guard let database else { return nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord?, any Error>) in
            database.fetch(withRecordID: recordID) { record, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: record)
            }
        }
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        guard let database else {
            throw AppError.io("CloudKit is unavailable for the current process.")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, any Error>) in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let savedRecord else {
                    continuation.resume(throwing: AppError.io("CloudKit did not return a saved current account selection."))
                    return
                }
                continuation.resume(returning: savedRecord)
            }
        }
    }

    private func decodeSelection(from data: Data) throws -> SelectionPayload {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SelectionPayload.self, from: data)
        } catch {
            throw AppError.invalidData("CloudKit current account selection is invalid: \(error.localizedDescription)")
        }
    }

    private func decodeSelectionIfValid(from data: Data) -> SelectionPayload? {
        do {
            return try decodeSelection(from: data)
        } catch {
            return nil
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw AppError.invalidData("Failed to serialize current account selection: \(error.localizedDescription)")
        }
    }

    private func digest(for selection: CurrentAccountSelection) throws -> String {
        let data = try encode(selection)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func saveCurrentSelection(_ selection: CurrentAccountSelection) throws {
        var latestStore = try storeRepository.loadStore()
        latestStore.currentSelection = selection
        try storeRepository.saveStore(latestStore)
    }

    private func saveSelectionRecord(_ selection: CurrentAccountSelection) async throws -> CurrentAccountSelection {
        let payload = SelectionPayload(
            schemaVersion: Constants.schemaVersion,
            selection: selection
        )
        let payloadData = try encode(payload)
        var record = try await fetchRecordIfExists() ?? CKRecord(
            recordType: Constants.recordType,
            recordID: recordID
        )

        for attempt in 0..<3 {
            record[Constants.payloadKey] = payloadData as CKRecordValue
            record[Constants.selectedAtKey] = selection.selectedAt as CKRecordValue

            do {
                _ = try await save(record)
                return selection
            } catch {
                guard attempt < 2, isSelectionConflict(error) else {
                    throw error
                }

                let latestRecord = try await selectionConflictBaseRecord(from: error)
                if let latestRecord,
                   let serverSelection = selectionFromRecord(latestRecord),
                   CloudKitSelectionMerge.shouldKeepServerSelection(
                    serverSelection,
                    over: selection
                   ) {
                    return serverSelection
                }

                record = latestRecord ?? CKRecord(
                    recordType: Constants.recordType,
                    recordID: recordID
                )
            }
        }

        return selection
    }

    private func selectionFromRecord(_ record: CKRecord) -> CurrentAccountSelection? {
        guard let payloadData = record[Constants.payloadKey] as? Data else { return nil }
        return decodeSelectionIfValid(from: payloadData)?.selection
    }

    private func selectionConflictBaseRecord(from error: Error) async throws -> CKRecord? {
        if let ckError = error as? CKError {
            if let serverRecord = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                return serverRecord
            }
            if ckError.code == .serverRecordChanged {
                return try await fetchRecordIfExists()
            }
        }
        return try await fetchRecordIfExists()
    }

    private func isSelectionConflict(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .serverRecordChanged {
            return true
        }
        return ckError.localizedDescription.localizedCaseInsensitiveContains("oplock")
    }

    private static func resolveDeviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Constants.deviceIDDefaultsKey), !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: Constants.deviceIDDefaultsKey)
        return generated
    }

    private static func makeDatabase() -> CKDatabase? {
        guard hasCloudKitEntitlement() else {
            return nil
        }
        let container = CKContainer(identifier: Constants.containerIdentifier)
        return container.privateCloudDatabase
    }

    private static func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) else {
            return false
        }

        if let services = value as? [String] {
            return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        }
        if let services = value as? NSArray {
            return services.contains { element in
                guard let service = element as? String else { return false }
                return service == "CloudKit" || service == "CloudKit-Anonymous"
            }
        }

        return false
        #else
        return true
        #endif
    }
}

enum CloudKitAccountsStoreMerge {
    static func applyingRemoteAccounts(_ remoteAccounts: [StoredAccount], to latestStore: AccountsStore) -> AccountsStore {
        applyingRemoteSnapshot(
            remoteAccounts,
            remoteSyncedAt: remoteAccounts.map(\.updatedAt).max() ?? 0,
            to: latestStore
        )
    }

    static func applyingRemoteSnapshot(
        _ remoteAccounts: [StoredAccount],
        remoteSyncedAt: Int64,
        to latestStore: AccountsStore
    ) -> AccountsStore {
        var mergedStore = latestStore
        let localAccountsByAccountID = Dictionary(
            uniqueKeysWithValues: latestStore.accounts.map { ($0.accountID, $0) }
        )
        var consumedAccountIDs = Set<String>()
        var mergedAccounts: [StoredAccount] = []
        mergedAccounts.reserveCapacity(max(latestStore.accounts.count, remoteAccounts.count))

        for remoteAccount in remoteAccounts {
            if let localAccount = localAccountsByAccountID[remoteAccount.accountID] {
                mergedAccounts.append(
                    mergeMatchedAccount(local: localAccount, remote: remoteAccount)
                )
                consumedAccountIDs.insert(remoteAccount.accountID)
            } else {
                mergedAccounts.append(remoteAccount)
            }
        }

        for localAccount in latestStore.accounts where !consumedAccountIDs.contains(localAccount.accountID) {
            if shouldKeepLocalOnlyAccount(localAccount, remoteSyncedAt: remoteSyncedAt) {
                mergedAccounts.append(localAccount)
            }
        }

        mergedStore.accounts = mergedAccounts
        return mergedStore
    }

    private static func mergeMatchedAccount(local: StoredAccount, remote: StoredAccount) -> StoredAccount {
        let metadataWinner = remote.updatedAt >= local.updatedAt ? remote : local
        let usageWinner = preferredUsageSource(local: local, remote: remote)

        var merged = metadataWinner
        merged.id = local.id
        merged.usage = usageWinner.usage
        merged.usageError = usageWinner.usageError
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        return merged
    }

    private static func preferredUsageSource(local: StoredAccount, remote: StoredAccount) -> StoredAccount {
        let localUsageStamp = usageTimestamp(for: local)
        let remoteUsageStamp = usageTimestamp(for: remote)

        if remoteUsageStamp != localUsageStamp {
            return remoteUsageStamp > localUsageStamp ? remote : local
        }

        if remote.usage != local.usage {
            return remote.updatedAt >= local.updatedAt ? remote : local
        }

        if remote.usageError != local.usageError {
            return remote.updatedAt >= local.updatedAt ? remote : local
        }

        return local
    }

    private static func usageTimestamp(for account: StoredAccount) -> Int64 {
        if let fetchedAt = account.usage?.fetchedAt {
            return fetchedAt
        }
        if account.usageError != nil {
            return account.updatedAt
        }
        return 0
    }

    private static func shouldKeepLocalOnlyAccount(
        _ localAccount: StoredAccount,
        remoteSyncedAt: Int64
    ) -> Bool {
        localAccount.updatedAt > remoteSyncedAt
    }
}

enum CloudKitSelectionMerge {
    static func shouldApplyRemoteSelection(
        _ remoteSelection: CurrentAccountSelection,
        over localSelection: CurrentAccountSelection?
    ) -> Bool {
        guard let localSelection else { return true }
        return comparesNewer(remoteSelection, than: localSelection)
    }

    static func shouldKeepServerSelection(
        _ serverSelection: CurrentAccountSelection,
        over localSelection: CurrentAccountSelection
    ) -> Bool {
        serverSelection == localSelection || comparesNewer(serverSelection, than: localSelection)
    }

    private static func comparesNewer(
        _ lhs: CurrentAccountSelection,
        than rhs: CurrentAccountSelection
    ) -> Bool {
        if lhs.selectedAt != rhs.selectedAt {
            return lhs.selectedAt > rhs.selectedAt
        }
        if lhs.sourceDeviceID != rhs.sourceDeviceID {
            return lhs.sourceDeviceID > rhs.sourceDeviceID
        }
        return lhs.accountID > rhs.accountID
    }
}
