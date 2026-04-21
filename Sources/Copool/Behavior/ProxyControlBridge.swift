import Foundation
import Combine

actor ProxyControlBridge: ProxyLocalCommandServiceProtocol {
    private enum Constants {
        static let syncInterval: Duration = .seconds(1)
        static let activeCommandPollIntervalMilliseconds: Int64 = 1_000
        static let remoteStatusRefreshIntervalMilliseconds: Int64 = 8_000
    }

    private struct RemoteStatusRefreshSnapshot: Sendable {
        let remoteStatusesSyncedAt: Int64
        let remoteStatuses: [String: RemoteProxyStatus]
    }

    private struct CommandExecutionResult {
        let forceRemoteStatusRefresh: Bool

        static let noRemoteStatusRefresh = CommandExecutionResult(forceRemoteStatusRefresh: false)
        static let forceRemoteStatusRefresh = CommandExecutionResult(forceRemoteStatusRefresh: true)
    }

    private let proxyCoordinator: ProxyCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let cloudSyncService: ProxyControlCloudSyncServiceProtocol?
    private let performAccountsRefresh: (@MainActor @Sendable () async throws -> Void)?
    private let dateProvider: DateProviding
    private let runtimePlatform: RuntimePlatform
    private let sourceDeviceID: String

    private var loopTask: Task<Void, Never>?
    private var remoteStatusRefreshTask: Task<Void, Never>?
    private var hasPendingForcedRemoteStatusRefresh = false
    private var lastHandledCommandID: String?
    private var lastCommandError: String?
    private var remoteLogs: [String: String] = [:]
    private var remoteDiscoveries: [String: [DiscoveredRemoteProxyInstance]] = [:]
    private var cachedRemoteStatuses: [String: RemoteProxyStatus] = [:]
    private var isAppActive = true
    private var lastCommandPollAt: Int64?
    private var lastRemoteStatusRefreshAt: Int64?
    private var pushCancellable: AnyCancellable?

    init(
        proxyCoordinator: ProxyCoordinator,
        settingsCoordinator: SettingsCoordinator,
        cloudSyncService: ProxyControlCloudSyncServiceProtocol?,
        performAccountsRefresh: (@MainActor @Sendable () async throws -> Void)? = nil,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform,
        sourceDeviceID: String = "macos-proxy-bridge"
    ) {
        self.proxyCoordinator = proxyCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.cloudSyncService = cloudSyncService
        self.performAccountsRefresh = performAccountsRefresh
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
        self.sourceDeviceID = sourceDeviceID
    }

    func start() {
        guard runtimePlatform == .macOS else { return }
        guard loopTask == nil else { return }
        configurePushHandlingIfNeeded()
        Task {
            do {
                try await cloudSyncService?.ensurePushSubscriptionIfNeeded()
                await seedStateFromLatestSnapshotIfAvailable()
                scheduleRemoteStatusRefreshIfNeeded(force: cachedRemoteStatuses.isEmpty)
            } catch {}
        }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        remoteStatusRefreshTask?.cancel()
        remoteStatusRefreshTask = nil
        pushCancellable = nil
    }

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        guard runtimePlatform == .macOS else {
            throw AppError.invalidData("Local proxy commands are only available on macOS.")
        }

        let executionResult = try await execute(command)
        lastCommandError = nil
        return try await publishSnapshot(
            forceRemoteStatusRefresh: executionResult.forceRemoteStatusRefresh,
            broadcastLocally: true
        )
    }

    func handlePushNotification() async {
        guard runtimePlatform == .macOS else { return }
        do {
            let didHandleCommand = try await processPendingCommandIfNeeded(forcePoll: true)
            if !didHandleCommand {
                try await publishSnapshot()
            }
        } catch {}
    }

    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                scheduleRemoteStatusRefreshIfNeeded(force: false)
                let didHandleCommand = try await processPendingCommandIfNeeded()
                if !didHandleCommand {
                    try await publishSnapshot()
                }
            } catch {}

            try? await Task.sleep(for: Constants.syncInterval)
        }
    }

    private func configurePushHandlingIfNeeded() {
        guard pushCancellable == nil else { return }

        pushCancellable = NotificationCenter.default
            .publisher(for: .copoolProxyControlPushDidArrive)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.handlePushNotification()
                }
            }
    }

    @discardableResult
    private func publishSnapshot() async throws -> ProxyControlSnapshot {
        try await publishSnapshot(forceRemoteStatusRefresh: false, broadcastLocally: false)
    }

    @discardableResult
    private func publishSnapshot(
        forceRemoteStatusRefresh: Bool,
        broadcastLocally: Bool
    ) async throws -> ProxyControlSnapshot {
        let snapshot = try await buildSnapshot(forceRemoteStatusRefresh: forceRemoteStatusRefresh)
        do {
            try await cloudSyncService?.pushLocalSnapshot(snapshot)
        } catch {
            guard !broadcastLocally else {
                if broadcastLocally {
                    broadcastLocalSnapshot(snapshot)
                }
                return snapshot
            }
            throw error
        }
        if broadcastLocally {
            broadcastLocalSnapshot(snapshot)
        }
        return snapshot
    }

    @discardableResult
    private func processPendingCommandIfNeeded(forcePoll: Bool = false) async throws -> Bool {
        guard let cloudSyncService else { return false }
        guard forcePoll || isCommandPollDue() else { return false }
        lastCommandPollAt = dateProvider.unixMillisecondsNow()
        guard let command = try await cloudSyncService.pullPendingCommand() else { return false }
        guard command.id != lastHandledCommandID else { return false }

        var executionResult = CommandExecutionResult.noRemoteStatusRefresh

        do {
            executionResult = try await execute(command)
            lastHandledCommandID = command.id
            lastCommandError = nil
        } catch {
            lastHandledCommandID = command.id
            lastCommandError = error.localizedDescription
            if command.kind == .deployRemote {
                AuthFlowDebugLog.write(
                    "RemoteDeploy.bridge.error",
                    "commandID=\(command.id) serverID=\(command.remoteServerID ?? command.remoteServer?.id ?? "nil") error=\(error.localizedDescription)"
                )
            }
        }

        _ = try await publishSnapshot(
            forceRemoteStatusRefresh: executionResult.forceRemoteStatusRefresh,
            broadcastLocally: true
        )
        return true
    }

    private func isCommandPollDue() -> Bool {
        guard let lastCommandPollAt else { return true }
        return dateProvider.unixMillisecondsNow() - lastCommandPollAt
            >= Constants.activeCommandPollIntervalMilliseconds
    }

    private func buildSnapshot(forceRemoteStatusRefresh: Bool) async throws -> ProxyControlSnapshot {
        let settings = try await settingsCoordinator.currentSettings()
        let remoteStatuses = resolveRemoteStatuses(for: settings.remoteServers)
        if forceRemoteStatusRefresh {
            scheduleRemoteStatusRefreshIfNeeded(force: true)
        }
        let pair = await proxyCoordinator.loadStatus()
        let proxyStatus = pair.0
        let cloudflaredStatus = pair.1
        let proxyConfiguration = resolveSnapshotProxyConfiguration(
            from: settings.proxyConfiguration,
            cloudflaredStatus: cloudflaredStatus
        )

        return ProxySyncPolicy.RemoteLogs.normalize(
            ProxyControlSnapshot(
            syncedAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: sourceDeviceID,
            proxyStatus: proxyStatus,
            preferredProxyPort: proxyConfiguration.preferredPort
                ?? proxyStatus.port
                ?? RemoteServerConfiguration.defaultProxyPort,
            preferredProxyPortText: proxyConfiguration.preferredPortText,
            autoStartProxy: settings.autoStartApiProxy,
            cloudflaredStatus: cloudflaredStatus,
            cloudflaredTunnelMode: proxyConfiguration.cloudflared.tunnelMode,
            cloudflaredNamedInput: NamedCloudflaredTunnelInput(
                apiToken: "",
                accountID: "",
                zoneID: "",
                hostname: proxyConfiguration.cloudflared.namedHostname
            ),
            cloudflaredUseHTTP2: proxyConfiguration.cloudflared.useHTTP2,
            publicAccessEnabled: proxyConfiguration.cloudflared.enabled,
            remoteServers: settings.remoteServers,
            remoteStatusesSyncedAt: lastRemoteStatusRefreshAt,
            remoteStatuses: remoteStatuses,
            remoteDiscoveries: remoteDiscoveries,
            remoteLogs: remoteLogs,
            lastHandledCommandID: lastHandledCommandID,
            lastCommandError: lastCommandError
        )
        )
    }

    private func resolveRemoteStatuses(
        for remoteServers: [RemoteServerConfig]
    ) -> [String: RemoteProxyStatus] {
        let serverIDs = Set(remoteServers.map(\.id))
        cachedRemoteStatuses = cachedRemoteStatuses.filter { serverIDs.contains($0.key) }
        remoteDiscoveries = remoteDiscoveries.filter { serverIDs.contains($0.key) }
        return cachedRemoteStatuses
    }

    private func seedStateFromLatestSnapshotIfAvailable() async {
        guard let cloudSyncService else { return }
        do {
            guard let snapshot = try await cloudSyncService.pullRemoteSnapshot() else { return }
            cachedRemoteStatuses = snapshot.remoteStatuses
            remoteDiscoveries = snapshot.remoteDiscoveries
            remoteLogs = ProxySyncPolicy.RemoteLogs.normalize(snapshot.remoteLogs)
            lastHandledCommandID = snapshot.lastHandledCommandID
            lastCommandError = snapshot.lastCommandError
            lastRemoteStatusRefreshAt = snapshot.remoteStatusesSyncedAt
        } catch {}
    }

    private func scheduleRemoteStatusRefreshIfNeeded(force: Bool) {
        guard runtimePlatform == .macOS else { return }
        guard remoteStatusRefreshTask == nil else {
            if force {
                hasPendingForcedRemoteStatusRefresh = true
            }
            return
        }
        if !force, !isRemoteStatusRefreshDue() {
            return
        }

        remoteStatusRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshRemoteStatusesInBackground()
        }
    }

    private func isRemoteStatusRefreshDue() -> Bool {
        guard let lastRemoteStatusRefreshAt else { return true }
        return dateProvider.unixMillisecondsNow() - lastRemoteStatusRefreshAt >= Constants.remoteStatusRefreshIntervalMilliseconds
    }

    private func refreshRemoteStatusesInBackground() async {
        defer {
            remoteStatusRefreshTask = nil
            if hasPendingForcedRemoteStatusRefresh {
                hasPendingForcedRemoteStatusRefresh = false
                scheduleRemoteStatusRefreshIfNeeded(force: true)
            }
        }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            let previousStatuses = resolveRemoteStatuses(for: settings.remoteServers)
            let refreshSnapshot = await refreshRemoteStatuses(
                for: settings.remoteServers,
                startingWith: previousStatuses
            )
            cachedRemoteStatuses = refreshSnapshot.remoteStatuses
            lastRemoteStatusRefreshAt = refreshSnapshot.remoteStatusesSyncedAt
            guard refreshSnapshot.remoteStatuses != previousStatuses else { return }
            _ = try await publishSnapshot(
                forceRemoteStatusRefresh: false,
                broadcastLocally: true
            )
        } catch {}
    }

    private func refreshRemoteStatuses(
        for remoteServers: [RemoteServerConfig],
        startingWith cachedStatuses: [String: RemoteProxyStatus]
    ) async -> RemoteStatusRefreshSnapshot {
        guard !remoteServers.isEmpty else {
            return RemoteStatusRefreshSnapshot(
                remoteStatusesSyncedAt: dateProvider.unixMillisecondsNow(),
                remoteStatuses: cachedStatuses
            )
        }

        let refreshedStatuses = await proxyCoordinator.remoteStatuses(for: remoteServers)
        var mergedStatuses = cachedStatuses
        for server in remoteServers {
            if let status = refreshedStatuses[server.id] {
                mergedStatuses[server.id] = status
            }
        }

        return RemoteStatusRefreshSnapshot(
            remoteStatusesSyncedAt: dateProvider.unixMillisecondsNow(),
            remoteStatuses: mergedStatuses
        )
    }

    private func execute(_ command: ProxyControlCommand) async throws -> CommandExecutionResult {
        switch command.kind {
        case .refreshStatus:
            scheduleRemoteStatusRefreshIfNeeded(force: true)
            return .noRemoteStatusRefresh
        case .refreshAccounts:
            guard let performAccountsRefresh else {
                throw AppError.invalidData("Accounts refresh service is unavailable.")
            }
            try await performAccountsRefresh()
            return .noRemoteStatusRefresh
        case .updateProxyConfiguration:
            guard let proxyConfiguration = command.proxyConfiguration else {
                throw AppError.invalidData("Missing proxy configuration payload.")
            }
            try await persistProxyConfiguration(proxyConfiguration)
            return .noRemoteStatusRefresh
        case .startProxy:
            if let proxyConfiguration = command.proxyConfiguration {
                try await persistProxyConfiguration(proxyConfiguration)
            }
            _ = try await proxyCoordinator.startProxy(preferredPort: command.preferredProxyPort)
            return .noRemoteStatusRefresh
        case .stopProxy:
            _ = await proxyCoordinator.stopProxy()
            return .noRemoteStatusRefresh
        case .refreshAPIKey:
            _ = try await proxyCoordinator.refreshAPIKey()
            return .noRemoteStatusRefresh
        case .setAutoStartProxy:
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(autoStartApiProxy: command.autoStartProxy ?? false)
            )
            return .noRemoteStatusRefresh
        case .installCloudflared:
            _ = try await proxyCoordinator.installCloudflared()
            return .noRemoteStatusRefresh
        case .startCloudflared:
            guard let input = command.cloudflaredInput else {
                throw AppError.invalidData("Missing cloudflared input.")
            }
            if let proxyConfiguration = command.proxyConfiguration {
                try await persistProxyConfiguration(proxyConfiguration)
            }
            _ = try await proxyCoordinator.startCloudflared(input: input)
            return .noRemoteStatusRefresh
        case .stopCloudflared:
            _ = await proxyCoordinator.stopCloudflared()
            return .noRemoteStatusRefresh
        case .refreshCloudflared:
            _ = await proxyCoordinator.refreshCloudflared()
            return .noRemoteStatusRefresh
        case .addRemoteServer:
            let draft = command.remoteServer ?? RemoteServerConfiguration.makeDraft()
            let settings = try await settingsCoordinator.currentSettings()
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(
                    remoteServers: settings.remoteServers + [RemoteServerConfiguration.normalize(draft)]
                )
            )
            scheduleRemoteStatusRefreshIfNeeded(force: true)
            return .noRemoteStatusRefresh
        case .saveRemoteServer:
            guard let remoteServer = command.remoteServer else {
                throw AppError.invalidData("Missing remote server payload.")
            }
            let settings = try await settingsCoordinator.currentSettings()
            let previousServerID = command.previousRemoteServerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baselineServers: [RemoteServerConfig]
            if let previousServerID, !previousServerID.isEmpty, previousServerID != remoteServer.id {
                baselineServers = settings.remoteServers.filter { $0.id != previousServerID }
                remoteLogs.removeValue(forKey: previousServerID)
                remoteDiscoveries.removeValue(forKey: previousServerID)
                cachedRemoteStatuses.removeValue(forKey: previousServerID)
            } else {
                baselineServers = settings.remoteServers
            }
            let merged = RemoteServerConfiguration.upsert(remoteServer, into: baselineServers)
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(remoteServers: merged)
            )
            remoteDiscoveries.removeValue(forKey: remoteServer.id)
            scheduleRemoteStatusRefreshIfNeeded(force: true)
            return .noRemoteStatusRefresh
        case .removeRemoteServer:
            guard let id = command.remoteServerID else {
                throw AppError.invalidData("Missing remote server id.")
            }
            let settings = try await settingsCoordinator.currentSettings()
            let merged = settings.remoteServers.filter { $0.id != id }
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(remoteServers: merged)
            )
            remoteLogs.removeValue(forKey: id)
            remoteDiscoveries.removeValue(forKey: id)
            cachedRemoteStatuses.removeValue(forKey: id)
            return .noRemoteStatusRefresh
        case .discoverRemote:
            guard let remoteServer = command.remoteServer else {
                throw AppError.invalidData("Missing remote server payload.")
            }
            remoteDiscoveries[remoteServer.id] = try await proxyCoordinator.discoverRemote(server: remoteServer)
            return .noRemoteStatusRefresh
        case .refreshRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = await proxyCoordinator.remoteStatus(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .deployRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            AuthFlowDebugLog.write(
                "RemoteDeploy.bridge.begin",
                "commandID=\(command.id) serverID=\(server.id) label=\(server.label) host=\(server.host)"
            )
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.deployRemote(server: server)
            AuthFlowDebugLog.write(
                "RemoteDeploy.bridge.success",
                "commandID=\(command.id) serverID=\(server.id) running=\(cachedRemoteStatuses[server.id]?.running == true)"
            )
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .syncRemoteAccounts:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.syncRemoteAccounts(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .startRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.startRemote(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .stopRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.stopRemote(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .readRemoteLogs:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            let logs = try await proxyCoordinator.readRemoteLogs(
                server: server,
                lines: command.logLines ?? 120
            )
            remoteLogs[server.id] = ProxySyncPolicy.RemoteLogs.normalize(logs)
            return .noRemoteStatusRefresh
        case .uninstallRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.uninstallRemote(
                server: server,
                removeRemoteDirectory: command.removeRemoteDirectory ?? false
            )
            remoteLogs.removeValue(forKey: server.id)
            remoteDiscoveries.removeValue(forKey: server.id)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        }
    }

    private func persistProxyConfiguration(_ configuration: ProxyConfiguration) async throws {
        _ = try await settingsCoordinator.updateSettings(
            AppSettingsPatch(proxyConfiguration: configuration.normalized())
        )
    }

    private func resolveSnapshotProxyConfiguration(
        from baseConfiguration: ProxyConfiguration,
        cloudflaredStatus: CloudflaredStatus
    ) -> ProxyConfiguration {
        var resolved = baseConfiguration.normalized()

        if cloudflaredStatus.running {
            if let mode = cloudflaredStatus.tunnelMode {
                resolved.cloudflared.tunnelMode = mode
            }
            resolved.cloudflared.useHTTP2 = cloudflaredStatus.useHTTP2
        }

        if let hostname = cloudflaredStatus.customHostname,
           !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.cloudflared.namedHostname = CloudflaredConfiguration.normalizeHostnameDraft(hostname)
        }

        return resolved.normalized()
    }

    private func serverForCommand(_ command: ProxyControlCommand) async throws -> RemoteServerConfig? {
        guard let id = command.remoteServerID else {
            throw AppError.invalidData("Missing remote server id.")
        }
        let settings = try await settingsCoordinator.currentSettings()
        return settings.remoteServers.first(where: { $0.id == id })
    }

    private func broadcastLocalSnapshot(_ snapshot: ProxyControlSnapshot) {
        NotificationCenter.default.post(
            name: .copoolLocalProxySnapshotDidUpdate,
            object: nil,
            userInfo: [ProxyControlNotificationPayloadKey.snapshot: snapshot]
        )
    }
}
