import Foundation

struct FileSystemPaths {
    var applicationSupportDirectory: URL
    var accountStorePath: URL
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
        #if os(iOS)
        let codexDirectory = appSupportDirectory.appendingPathComponent("codex", isDirectory: true)
        let proxyDaemonDataDirectory = appSupportDirectory.appendingPathComponent("proxyd", isDirectory: true)
        #else
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let proxyDaemonDataDirectory = homeDirectory.appendingPathComponent(".codex-tools-proxyd", isDirectory: true)
        #endif
        let cloudflaredLogDirectory = appSupportDirectory.appendingPathComponent("cloudflared-logs", isDirectory: true)

        return FileSystemPaths(
            applicationSupportDirectory: appSupportDirectory,
            accountStorePath: appSupportDirectory.appendingPathComponent("accounts.json", isDirectory: false),
            codexAuthPath: codexDirectory.appendingPathComponent("auth.json", isDirectory: false),
            codexConfigPath: codexDirectory.appendingPathComponent("config.toml", isDirectory: false),
            proxyDaemonDataDirectory: proxyDaemonDataDirectory,
            proxyDaemonKeyPath: proxyDaemonDataDirectory.appendingPathComponent("api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: cloudflaredLogDirectory
        )
    }
}
