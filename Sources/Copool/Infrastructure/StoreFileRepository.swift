import Foundation

final class StoreFileRepository: AccountsStoreRepository, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let dateProvider: DateProviding
    private let lock = NSLock()

    init(paths: FileSystemPaths, fileManager: FileManager = .default, dateProvider: DateProviding = SystemDateProvider()) {
        self.paths = paths
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    func loadStore() throws -> AccountsStore {
        lock.lock()
        defer { lock.unlock() }
        return try loadStoreUnlocked()
    }

    func saveStore(_ store: AccountsStore) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveStoreUnlocked(store)
    }

    func mutateStore(_ transform: (inout AccountsStore) throws -> Void) throws -> AccountsStore {
        lock.lock()
        defer { lock.unlock() }
        var store = try loadStoreUnlocked()
        try transform(&store)
        try saveStoreUnlocked(store)
        return store
    }

    private func loadStoreUnlocked() throws -> AccountsStore {
        let path = paths.accountStorePath
        guard fileManager.fileExists(atPath: path.path) else {
            return AccountsStore()
        }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw AppError.io(L10n.tr("error.store.read_failed_format", error.localizedDescription))
        }

        do {
            return try decodeStore(from: data)
        } catch {
            try backupCorruptedStore(raw: data)
            let emptyStore = AccountsStore()
            try saveStoreUnlocked(emptyStore)
            return emptyStore
        }
    }

    private func saveStoreUnlocked(_ store: AccountsStore) throws {
        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(store)
        } catch {
            throw AppError.invalidData(L10n.tr("error.store.serialize_failed_format", error.localizedDescription))
        }

        try writeAtomically(data: data, to: paths.accountStorePath)
    }

    private func decodeStore(from data: Data) throws -> AccountsStore {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AccountsStore.self, from: data)
        } catch {
            throw AppError.invalidData(L10n.tr("error.store.invalid_format_format", error.localizedDescription))
        }
    }

    private func backupCorruptedStore(raw: Data) throws {
        let filename = "accounts.corrupt-\(dateProvider.unixSecondsNow()).json"
        let backupPath = paths.applicationSupportDirectory.appendingPathComponent(filename, isDirectory: false)

        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        try raw.write(to: backupPath, options: .atomic)
        Self.setPrivatePermissions(at: backupPath)
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            Self.setPrivatePermissions(at: tempURL)
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
            Self.setPrivatePermissions(at: destination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try data.write(to: destination, options: .atomic)
                    Self.setPrivatePermissions(at: destination)
                    return
                } catch {
                    throw AppError.io(L10n.tr("error.store.write_failed_format", error.localizedDescription))
                }
            }
            throw AppError.io(L10n.tr("error.store.atomic_write_failed_format", error.localizedDescription))
        }
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}

final class SettingsFileRepository: SettingsRepository, @unchecked Sendable {
    private struct LegacyAccountsStore: Codable {
        var version: Int = 1
        var accounts: [StoredAccount] = []
        var currentSelection: CurrentAccountSelection?
        var settings: AppSettings = .defaultValue
    }

    private let paths: FileSystemPaths
    private let fileManager: FileManager

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadSettings() throws -> AppSettings {
        if fileManager.fileExists(atPath: paths.settingsStorePath.path) {
            return try decodeSettings(from: paths.settingsStorePath)
        }

        if fileManager.fileExists(atPath: paths.accountStorePath.path),
           let legacyStore = try decodeLegacyStore(from: paths.accountStorePath) {
            let migratedSettings = legacyStore.settings
            try saveSettings(migratedSettings)
            try saveAccountsStore(
                AccountsStore(
                    version: legacyStore.version,
                    accounts: legacyStore.accounts,
                    currentSelection: legacyStore.currentSelection
                )
            )
            return migratedSettings
        }

        return .defaultValue
    }

    func saveSettings(_ settings: AppSettings) throws {
        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(settings)
        } catch {
            throw AppError.invalidData(L10n.tr("error.store.serialize_failed_format", error.localizedDescription))
        }

        try writeAtomically(data: data, to: paths.settingsStorePath)
    }

    private func decodeSettings(from path: URL) throws -> AppSettings {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw AppError.io(L10n.tr("error.store.read_failed_format", error.localizedDescription))
        }

        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            throw AppError.invalidData(L10n.tr("error.store.invalid_format_format", error.localizedDescription))
        }
    }

    private func decodeLegacyStore(from path: URL) throws -> LegacyAccountsStore? {
        let data = try Data(contentsOf: path)
        return try? JSONDecoder().decode(LegacyAccountsStore.self, from: data)
    }

    private func saveAccountsStore(_ store: AccountsStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(store)
        } catch {
            throw AppError.invalidData(L10n.tr("error.store.serialize_failed_format", error.localizedDescription))
        }

        try writeAtomically(data: data, to: paths.accountStorePath)
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            Self.setPrivatePermissions(at: tempURL)
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
            Self.setPrivatePermissions(at: destination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try data.write(to: destination, options: .atomic)
                    Self.setPrivatePermissions(at: destination)
                    return
                } catch {
                    throw AppError.io(L10n.tr("error.store.write_failed_format", error.localizedDescription))
                }
            }
            throw AppError.io(L10n.tr("error.store.atomic_write_failed_format", error.localizedDescription))
        }
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}
