import Foundation
import CloudKit
import CryptoKit
#if os(macOS)
import Security
#endif

actor CloudKitProxyControlSyncService: ProxyControlCloudSyncServiceProtocol {
    private enum Constants {
        static let containerIdentifier = "iCloud.com.alick.copool"
        static let pushSubscriptionID = "proxy-control.primary.push"
        static let snapshotRecordType = "ProxyControlSnapshot"
        static let snapshotRecordName = "primary"
        static let commandRecordType = "ProxyControlCommand"
        static let commandRecordName = "primary"
        static let payloadKey = "payload"
        static let timestampKey = "timestamp"
        static let schemaVersion = 1
    }

    private struct SnapshotPayload: Codable {
        var schemaVersion: Int
        var snapshot: ProxyControlSnapshot
    }

    private struct CommandPayload: Codable {
        var schemaVersion: Int
        var command: ProxyControlCommand
    }

    private let database: CKDatabase?
    private var lastUploadedSnapshotDigest: String?
    private var lastAppliedSnapshotDigest: String?
    private var lastUploadedCommandDigest: String?
    private var lastAppliedCommandDigest: String?
    private var pushSubscriptionEnsured = false

    init() {
        self.database = Self.makeDatabase()
    }

    func pushLocalSnapshot(_ snapshot: ProxyControlSnapshot) async throws {
        guard database != nil else { return }

        let digest = try snapshotDigest(for: snapshot)
        guard digest != lastUploadedSnapshotDigest else { return }

        let payload = SnapshotPayload(
            schemaVersion: Constants.schemaVersion,
            snapshot: snapshot
        )
        _ = try await saveRecord(
            payload: payload,
            recordID: snapshotRecordID,
            recordType: Constants.snapshotRecordType,
            timestamp: snapshot.syncedAt
        )
        lastUploadedSnapshotDigest = digest
        lastAppliedSnapshotDigest = digest
    }

    func pullRemoteSnapshot() async throws -> ProxyControlSnapshot? {
        guard database != nil else { return nil }
        guard let record = try await fetchRecordIfExists(recordID: snapshotRecordID) else {
            return nil
        }
        guard let payloadData = record[Constants.payloadKey] as? Data else {
            lastUploadedSnapshotDigest = nil
            lastAppliedSnapshotDigest = nil
            return nil
        }

        guard let payload = decodeSnapshotPayloadIfValid(from: payloadData) else {
            lastUploadedSnapshotDigest = nil
            lastAppliedSnapshotDigest = nil
            return nil
        }
        let digest = try snapshotDigest(for: payload.snapshot)
        if digest == lastAppliedSnapshotDigest {
            return nil
        }

        lastAppliedSnapshotDigest = digest
        return payload.snapshot
    }

    func enqueueCommand(_ command: ProxyControlCommand) async throws {
        guard database != nil else { return }

        let digest = try commandDigest(for: command)
        guard digest != lastUploadedCommandDigest else { return }

        let payload = CommandPayload(
            schemaVersion: Constants.schemaVersion,
            command: command
        )
        _ = try await saveRecord(
            payload: payload,
            recordID: commandRecordID,
            recordType: Constants.commandRecordType,
            timestamp: command.createdAt
        )
        lastUploadedCommandDigest = digest
        lastAppliedCommandDigest = digest
    }

    func pullPendingCommand() async throws -> ProxyControlCommand? {
        guard database != nil else { return nil }
        guard let record = try await fetchRecordIfExists(recordID: commandRecordID) else {
            return nil
        }
        guard let payloadData = record[Constants.payloadKey] as? Data else {
            lastUploadedCommandDigest = nil
            lastAppliedCommandDigest = nil
            return nil
        }

        guard let payload = decodeCommandPayloadIfValid(from: payloadData) else {
            lastUploadedCommandDigest = nil
            lastAppliedCommandDigest = nil
            return nil
        }
        let digest = try commandDigest(for: payload.command)
        if digest == lastAppliedCommandDigest {
            return nil
        }

        lastAppliedCommandDigest = digest
        return payload.command
    }

    func ensurePushSubscriptionIfNeeded() async throws {
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
            throw AppError.io("CloudKit did not report a result for the proxy control push subscription.")
        }

        switch saveResult {
        case .success:
            pushSubscriptionEnsured = true
        case .failure(let error):
            throw error
        }
    }

    nonisolated static var pushSubscriptionID: String {
        Constants.pushSubscriptionID
    }

    private var snapshotRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Constants.snapshotRecordName)
    }

    private var commandRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Constants.commandRecordName)
    }

    private func fetchRecordIfExists(recordID: CKRecord.ID) async throws -> CKRecord? {
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
                    continuation.resume(throwing: AppError.io("CloudKit did not return a saved proxy control record."))
                    return
                }
                continuation.resume(returning: savedRecord)
            }
        }
    }

    private func saveRecord<Payload: Encodable>(
        payload: Payload,
        recordID: CKRecord.ID,
        recordType: String,
        timestamp: Int64
    ) async throws -> CKRecord {
        let payloadData = try encode(payload)
        var record = try await fetchRecordIfExists(recordID: recordID) ?? CKRecord(
            recordType: recordType,
            recordID: recordID
        )

        for attempt in 0..<3 {
            record[Constants.payloadKey] = payloadData as CKRecordValue
            record[Constants.timestampKey] = timestamp as CKRecordValue

            do {
                return try await save(record)
            } catch {
                guard attempt < 2, isConflict(error) else {
                    throw error
                }
                record = try await conflictBaseRecord(from: error, recordID: recordID) ?? CKRecord(
                    recordType: recordType,
                    recordID: recordID
                )
            }
        }

        return record
    }

    private func decodeSnapshotPayload(from data: Data) throws -> SnapshotPayload {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SnapshotPayload.self, from: data)
        } catch {
            throw AppError.invalidData("CloudKit proxy snapshot is invalid: \(error.localizedDescription)")
        }
    }

    private func decodeSnapshotPayloadIfValid(from data: Data) -> SnapshotPayload? {
        do {
            return try decodeSnapshotPayload(from: data)
        } catch {
            return nil
        }
    }

    private func decodeCommandPayload(from data: Data) throws -> CommandPayload {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(CommandPayload.self, from: data)
        } catch {
            throw AppError.invalidData("CloudKit proxy command is invalid: \(error.localizedDescription)")
        }
    }

    private func decodeCommandPayloadIfValid(from data: Data) -> CommandPayload? {
        do {
            return try decodeCommandPayload(from: data)
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
            throw AppError.invalidData("Failed to serialize proxy control payload: \(error.localizedDescription)")
        }
    }

    private func snapshotDigest(for snapshot: ProxyControlSnapshot) throws -> String {
        try digest(for: snapshot)
    }

    private func commandDigest(for command: ProxyControlCommand) throws -> String {
        try digest(for: command)
    }

    private func digest<T: Encodable>(for value: T) throws -> String {
        let data = try encode(value)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func conflictBaseRecord(from error: Error, recordID: CKRecord.ID) async throws -> CKRecord? {
        if let ckError = error as? CKError {
            if let serverRecord = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                return serverRecord
            }
            if ckError.code == .serverRecordChanged {
                return try await fetchRecordIfExists(recordID: recordID)
            }
        }
        return try await fetchRecordIfExists(recordID: recordID)
    }

    private func isConflict(_ error: Error) -> Bool {
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
