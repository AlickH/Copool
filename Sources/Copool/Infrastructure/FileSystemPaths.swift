import Foundation

struct FileSystemPaths {
    var applicationSupportDirectory: URL
    var accountStorePath: URL
    var settingsStorePath: URL
    var codexAuthPath: URL
    var codexConfigPath: URL
    var proxyDaemonDataDirectory: URL
    var proxyDaemonKeyPath: URL
    var cloudflaredLogDirectory: URL

    static func live(fileManager: FileManager = .default) throws -> FileSystemPaths {
        let appSupportBase = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appSupportDirectory = appSupportBase.appendingPathComponent("CodexToolsSwift", isDirectory: true)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let proxyDaemonDataDirectory = homeDirectory.appendingPathComponent(".codex-tools-proxyd", isDirectory: true)
        let cloudflaredLogDirectory = appSupportDirectory.appendingPathComponent("cloudflared-logs", isDirectory: true)

        return FileSystemPaths(
            applicationSupportDirectory: appSupportDirectory,
            accountStorePath: appSupportDirectory.appendingPathComponent("accounts.json", isDirectory: false),
            settingsStorePath: appSupportDirectory.appendingPathComponent("settings.json", isDirectory: false),
            codexAuthPath: codexDirectory.appendingPathComponent("auth.json", isDirectory: false),
            codexConfigPath: codexDirectory.appendingPathComponent("config.toml", isDirectory: false),
            proxyDaemonDataDirectory: proxyDaemonDataDirectory,
            proxyDaemonKeyPath: proxyDaemonDataDirectory.appendingPathComponent("api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: cloudflaredLogDirectory
        )
    }
}
