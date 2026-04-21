import Foundation
import CloudKit

actor CloudKitCurrentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol {
    private enum Constants {
        static let containerIdentifier = "iCloud.com.alick.copool"
        static let recordType = "CurrentAccountSelection"
        static let recordName = "current-account-selection.primary"
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
    private let deviceID: String
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
        _ = dateProvider
        _ = runtimePlatform
        self.deviceID = Self.resolveDeviceID()
    }

    func recordLocalSelection(cardID: String) async throws {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == cardID }) else {
            throw AppError.invalidData("Cannot record a current account selection for an unknown account.")
        }

        AccountSwitchDebugLog.write(
            "cloudSelection.recordLocal.begin",
            "cardID=\(cardID) target=\(AccountSwitchDebugLog.describe(account: account)) before=\(AccountSwitchDebugLog.describe(store: store, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
        AccountSwitchDebugLog.write(
            "cloudSelection.recordLocal.end",
            "cardID=\(cardID) unchanged=\(AccountSwitchDebugLog.describe(store: store, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
    }

    func pushLocalSelectionIfNeeded() async throws {
        guard database != nil else { return }
        let store = try storeRepository.loadStore()
        guard let currentCardID = store.currentAccountID,
              store.accounts.contains(where: { $0.id == currentCardID }) else { return }

        let selection = CurrentAccountSelection(
            cardID: currentCardID,
            selectedAt: store.currentSelection?.selectedAt ?? currentUnixMilliseconds(),
            sourceDeviceID: deviceID
        )
        try await saveSelectionRecord(selection)
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
        guard let record = try await fetchRecordIfExists() else { return .noChange }

        guard let payloadData = record[Constants.payloadKey] as? Data else {
            return .noChange
        }

        guard let remoteSelection = try? decodeSelection(from: payloadData).selection else {
            return .noChange
        }

        let store = try storeRepository.loadStore()
        let previousSelection = store.currentSelection
        guard CloudKitSelectionMerge.shouldApplyRemoteSelection(
            remoteSelection,
            over: previousSelection
        ) else {
            AccountSwitchDebugLog.write(
                "cloudSelection.pullRemote.skipOlder",
                "remote=\(AccountSwitchDebugLog.describe(selection: remoteSelection)) local=\(AccountSwitchDebugLog.describe(selection: previousSelection))"
            )
            return .noChange
        }

        guard store.accounts.contains(where: { $0.id == remoteSelection.cardID }) else {
            AccountSwitchDebugLog.write(
                "cloudSelection.pullRemote.skipMissingAccount",
                "remote=\(AccountSwitchDebugLog.describe(selection: remoteSelection))"
            )
            return .noChange
        }

        let changedCurrentAccount = store.currentAccountID != remoteSelection.cardID
        AccountSwitchDebugLog.write(
            "cloudSelection.pullRemote.resolved",
            "remote=\(AccountSwitchDebugLog.describe(selection: remoteSelection)) changedCurrentAccount=\(changedCurrentAccount)"
        )
        return CurrentAccountSelectionPullResult(
            didUpdateSelection: changedCurrentAccount || previousSelection != remoteSelection,
            changedCurrentAccount: changedCurrentAccount,
            cardID: remoteSelection.cardID
        )
    }

    private func currentUnixMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Constants.recordName)
    }

    nonisolated static var pushSubscriptionID: String {
        Constants.subscriptionID
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

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw AppError.invalidData("Failed to serialize current account selection: \(error.localizedDescription)")
        }
    }

    private func saveSelectionRecord(_ selection: CurrentAccountSelection) async throws {
        let payload = SelectionPayload(
            schemaVersion: Constants.schemaVersion,
            selection: selection
        )
        let payloadData = try encode(payload)
        let record = try await fetchRecordIfExists() ?? CKRecord(
            recordType: Constants.recordType,
            recordID: recordID
        )

        record[Constants.payloadKey] = payloadData as CKRecordValue
        record[Constants.selectedAtKey] = selection.selectedAt as CKRecordValue
        _ = try await save(record)
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
        CloudKitSupport.makePrivateDatabase(containerIdentifier: Constants.containerIdentifier)
    }
}
