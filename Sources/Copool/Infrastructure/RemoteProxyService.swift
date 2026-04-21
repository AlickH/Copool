import Foundation
import OSLog

#if os(macOS)
final class RemoteProxyService: RemoteProxyServiceProtocol, @unchecked Sendable {
    private enum Constants {
        static let defaultCommandTimeout: TimeInterval = 60
        static let defaultConnectTimeoutSeconds = 12
        static let statusCommandTimeout: TimeInterval = 10
        static let statusConnectTimeoutSeconds = 6
        static let logCommandTimeout: TimeInterval = 20
        static let fileTransferTimeout: TimeInterval = 90
    }

    // private let logger = Logger(subsystem: "Copool", category: "RemoteProxyService")
    private let repoRoot: URL?
    private let sourceAccountStorePath: URL
    private let fileManager: FileManager

    init(repoRoot: URL?, sourceAccountStorePath: URL, fileManager: FileManager = .default) {
        self.repoRoot = repoRoot
        self.sourceAccountStorePath = sourceAccountStorePath
        self.fileManager = fileManager
    }

    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        do {
            let normalized = try validate(server)
            let serviceName = RemoteProxyDeploymentPlan.serviceName(for: normalized.id)
            let commandRunner = makeCommandRunner()
            let command = RemoteProxyDeploymentPlan.renderStatusCommand(
                serviceName: serviceName,
                remoteDir: normalized.remoteDir,
                shellQuote: commandRunner.shellQuote
            )

            let output = try commandRunner.runSSH(
                server: normalized,
                command: command,
                timeout: Constants.statusCommandTimeout,
                connectTimeout: Constants.statusConnectTimeoutSeconds
            )
            return RemoteProxyOutputParser.parseStatusOutput(
                output,
                serviceName: serviceName,
                host: normalized.host,
                listenPort: normalized.listenPort
            )
        } catch {
            return RemoteProxyStatus(
                installed: false,
                serviceInstalled: false,
                running: false,
                enabled: false,
                serviceName: RemoteProxyDeploymentPlan.serviceName(for: server.id),
                pid: nil,
                baseURL: "http://\(server.host):\(server.listenPort)/v1",
                apiKey: nil,
                lastError: error.localizedDescription
            )
        }
    }

    func discover(server: RemoteServerConfig) async throws -> [DiscoveredRemoteProxyInstance] {
        let normalized = try validate(server)
        try ensureSSHToolsAvailable(for: normalized)
        let commandRunner = makeCommandRunner()

        let output = try commandRunner.runSSH(
            server: normalized,
            command: commandRunner.withRootPrivileges(
                RemoteProxyDeploymentPlan.renderDiscoverCommand(shellQuote: commandRunner.shellQuote)
            ),
            timeout: Constants.statusCommandTimeout,
            connectTimeout: Constants.statusConnectTimeoutSeconds
        )
        return RemoteProxyOutputParser.parseDiscoveryOutput(output, host: normalized.host)
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        let server = try validate(server)
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.begin",
            "serverID=\(server.id) label=\(server.label) host=\(server.host) remoteDir=\(server.remoteDir) listenPort=\(server.listenPort)"
        )
        try ensureSSHToolsAvailable(for: server)
        let commandRunner = makeCommandRunner()

        let binaryPath = try ensureDaemonBinary(for: server)
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.binaryReady",
            "serverID=\(server.id) binaryPath=\(binaryPath.path)"
        )
        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: server.id)
        let serviceContent = RemoteProxyDeploymentPlan.renderSystemdUnit(
            server: server,
            serviceName: serviceName
        )

        let temp = fileManager.temporaryDirectory.appendingPathComponent("codex-tools-remote-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        let localBinary = temp.appendingPathComponent("codex-tools-proxyd", isDirectory: false)
        let localAccounts = temp.appendingPathComponent("accounts.json", isDirectory: false)
        let localService = temp.appendingPathComponent(serviceName, isDirectory: false)

        try fileManager.copyItem(at: binaryPath, to: localBinary)
        let accountsData = try makeAccountsPayloadBuilder().build()
        try accountsData.write(to: localAccounts, options: .atomic)
        try serviceContent.write(to: localService, atomically: true, encoding: .utf8)
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.stagePrepared",
            "serverID=\(server.id) stageTemp=\(temp.path) accountsBytes=\(accountsData.count)"
        )

        let stageDir = RemoteProxyDeploymentPlan.stageDirectory(
            serverID: server.id,
            unixTime: Int(Date().timeIntervalSince1970)
        )
        _ = try commandRunner.runSSH(server: server, command: "mkdir -p \(commandRunner.shellQuote(stageDir))")
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.remoteStageCreated",
            "serverID=\(server.id) stageDir=\(stageDir)"
        )

        try commandRunner.runSCP(
            server: server,
            localPath: localBinary.path,
            remotePath: "\(stageDir)/codex-tools-proxyd",
            timeout: Constants.fileTransferTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.binaryUploaded",
            "serverID=\(server.id) remotePath=\(stageDir)/codex-tools-proxyd"
        )
        try commandRunner.runSCP(
            server: server,
            localPath: localAccounts.path,
            remotePath: "\(stageDir)/accounts.json",
            timeout: Constants.fileTransferTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.accountsUploaded",
            "serverID=\(server.id) remotePath=\(stageDir)/accounts.json"
        )
        try commandRunner.runSCP(
            server: server,
            localPath: localService.path,
            remotePath: "\(stageDir)/\(serviceName)",
            timeout: Constants.fileTransferTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.unitUploaded",
            "serverID=\(server.id) remotePath=\(stageDir)/\(serviceName)"
        )

        let installCommand = RemoteProxyDeploymentPlan.renderInstallCommand(
            server: server,
            serviceName: serviceName,
            stageDir: stageDir,
            shellQuote: commandRunner.shellQuote
        )

        _ = try commandRunner.runSSH(
            server: server,
            command: commandRunner.withRootPrivileges(installCommand),
            timeout: Constants.defaultCommandTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.installFinished",
            "serverID=\(server.id) serviceName=\(serviceName)"
        )

        let status = await status(server: server)
        AuthFlowDebugLog.write(
            "RemoteDeploy.service.status",
            "serverID=\(server.id) installed=\(status.installed) running=\(status.running) lastError=\(status.lastError ?? "nil")"
        )
        return status
    }

    func syncAccounts(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        let server = try validate(server)
        try ensureSSHToolsAvailable(for: server)
        let commandRunner = makeCommandRunner()

        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: server.id)
        let currentStatus = await status(server: server)
        guard currentStatus.installed || currentStatus.serviceInstalled else {
            return currentStatus
        }

        let temp = fileManager.temporaryDirectory.appendingPathComponent(
            "codex-tools-remote-accounts-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        let localAccounts = temp.appendingPathComponent("accounts.json", isDirectory: false)
        let accountsData = try makeAccountsPayloadBuilder().build()
        try accountsData.write(to: localAccounts, options: .atomic)

        let stageDir = RemoteProxyDeploymentPlan.stageDirectory(
            serverID: server.id,
            unixTime: Int(Date().timeIntervalSince1970)
        )
        _ = try commandRunner.runSSH(server: server, command: "mkdir -p \(commandRunner.shellQuote(stageDir))")
        try commandRunner.runSCP(
            server: server,
            localPath: localAccounts.path,
            remotePath: "\(stageDir)/accounts.json",
            timeout: Constants.fileTransferTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )

        let installCommand = RemoteProxyDeploymentPlan.renderSyncAccountsCommand(
            remoteDir: server.remoteDir,
            serviceName: serviceName,
            stageDir: stageDir,
            shouldRestartService: currentStatus.running,
            shellQuote: commandRunner.shellQuote
        )
        _ = try commandRunner.runSSH(
            server: server,
            command: commandRunner.withRootPrivileges(installCommand),
            timeout: Constants.defaultCommandTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        return await status(server: server)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        let normalized = try validate(server)
        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: normalized.id)
        let commandRunner = makeCommandRunner()
        _ = try commandRunner.runSSH(
            server: normalized,
            command: commandRunner.withRootPrivileges("systemctl start \(commandRunner.shellQuote(serviceName))"),
            timeout: Constants.defaultCommandTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        return await status(server: normalized)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        let normalized = try validate(server)
        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: normalized.id)
        let commandRunner = makeCommandRunner()
        _ = try commandRunner.runSSH(
            server: normalized,
            command: commandRunner.withRootPrivileges("systemctl stop \(commandRunner.shellQuote(serviceName))"),
            timeout: Constants.defaultCommandTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        return await status(server: normalized)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        let normalized = try validate(server)
        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: normalized.id)
        let count = min(max(lines, 20), 400)
        let commandRunner = makeCommandRunner()

        return try commandRunner.runSSH(
            server: normalized,
            command: commandRunner.withRootPrivileges("journalctl -u \(commandRunner.shellQuote(serviceName)) -n \(count) --no-pager"),
            timeout: Constants.logCommandTimeout
        )
    }

    func uninstall(server: RemoteServerConfig, removeRemoteDirectory: Bool) async throws -> RemoteProxyStatus {
        let normalized = try validate(server)
        try ensureSSHToolsAvailable(for: normalized)
        let commandRunner = makeCommandRunner()

        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: normalized.id)
        let command = RemoteProxyDeploymentPlan.renderUninstallCommand(
            remoteDir: normalized.remoteDir,
            serviceName: serviceName,
            removeRemoteDirectory: removeRemoteDirectory,
            shellQuote: commandRunner.shellQuote
        )
        _ = try commandRunner.runSSH(
            server: normalized,
            command: commandRunner.withRootPrivileges(command),
            timeout: Constants.defaultCommandTimeout,
            connectTimeout: Constants.defaultConnectTimeoutSeconds
        )
        return await status(server: normalized)
    }

    private func validate(_ server: RemoteServerConfig) throws -> RemoteServerConfig {
        var normalized = server
        normalized.label = normalized.label.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.host = normalized.host.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.sshUser = normalized.sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.remoteDir = normalized.remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.identityFile = normalized.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.privateKey = normalized.privateKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.password = normalized.password?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.label.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.label_empty")) }
        guard !normalized.host.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.host_empty")) }
        guard !normalized.sshUser.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.ssh_user_empty")) }
        guard !normalized.remoteDir.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.remote_dir_empty")) }
        guard normalized.sshPort > 0 else { throw AppError.invalidData(L10n.tr("error.remote.ssh_port_invalid")) }
        guard normalized.listenPort > 0 else { throw AppError.invalidData(L10n.tr("error.remote.listen_port_invalid")) }

        switch normalized.authMode {
        case "keyContent":
            guard normalized.privateKey?.isEmpty == false else {
                throw AppError.invalidData(L10n.tr("error.remote.private_key_content_empty"))
            }
        case "password":
            guard normalized.password?.isEmpty == false else {
                throw AppError.invalidData(L10n.tr("error.remote.password_empty"))
            }
        default:
            guard normalized.identityFile?.isEmpty == false else {
                throw AppError.invalidData(L10n.tr("error.remote.identity_file_empty"))
            }
        }

        return normalized
    }

    private func ensureSSHToolsAvailable(for server: RemoteServerConfig) throws {
        guard CommandRunner.resolveExecutable("ssh") != nil else {
            throw AppError.io(L10n.tr("error.remote.ssh_not_found"))
        }
        guard CommandRunner.resolveExecutable("scp") != nil else {
            throw AppError.io(L10n.tr("error.remote.scp_not_found"))
        }
        if server.authMode == "password", CommandRunner.resolveExecutable("sshpass") == nil {
            throw AppError.io(L10n.tr("error.remote.sshpass_required"))
        }
    }

    private func makeCommandRunner() -> RemoteShellCommandRunner {
        RemoteShellCommandRunner(fileManager: fileManager)
    }

    private func makeAccountsPayloadBuilder() -> RemoteProxyAccountsPayloadBuilder {
        RemoteProxyAccountsPayloadBuilder(
            sourceAccountStorePath: sourceAccountStorePath,
            fileManager: fileManager
        )
    }

    private func makeBinaryBuilder() -> RemoteProxydBinaryBuilder {
        RemoteProxydBinaryBuilder(
            repoRoot: repoRoot,
            fileManager: fileManager,
            commandRunner: makeCommandRunner()
        )
    }

    private func ensureDaemonBinary(for server: RemoteServerConfig) throws -> URL {
        try makeBinaryBuilder().buildBinary(for: server)
    }
}
#else
final class RemoteProxyService: RemoteProxyServiceProtocol, @unchecked Sendable {
    init(repoRoot: URL?, sourceAccountStorePath: URL, fileManager: FileManager = .default) {
        _ = repoRoot
        _ = sourceAccountStorePath
        _ = fileManager
    }

    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        RemoteProxyStatus(
            installed: false,
            serviceInstalled: false,
            running: false,
            enabled: false,
            serviceName: "codex-tools-proxyd-\(server.id).service",
            pid: nil,
            baseURL: "http://\(server.host):\(server.listenPort)/v1",
            apiKey: nil,
            lastError: PlatformCapabilities.unsupportedOperationMessage
        )
    }

    func discover(server: RemoteServerConfig) async throws -> [DiscoveredRemoteProxyInstance] {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func syncAccounts(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        _ = server
        _ = lines
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func uninstall(server: RemoteServerConfig, removeRemoteDirectory: Bool) async throws -> RemoteProxyStatus {
        _ = server
        _ = removeRemoteDirectory
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }
}
#endif
