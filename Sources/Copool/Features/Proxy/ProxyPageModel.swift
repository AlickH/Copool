import Foundation
import Combine

enum RemoteServerAction: Equatable {
    case save
    case remove
    case refresh
    case deploy
    case start
    case stop
    case logs
}

private struct RemoteSnapshotPresentationState: Equatable {
    var proxyStatus: ApiProxyStatus
    var preferredPortText: String
    var autoStartProxy: Bool
    var cloudflaredStatus: CloudflaredStatus
    var cloudflaredTunnelMode: CloudflaredTunnelMode
    var cloudflaredNamedInput: NamedCloudflaredTunnelInput
    var cloudflaredUseHTTP2: Bool
    var publicAccessEnabled: Bool
    var remoteServers: [RemoteServerConfig]
    var remoteStatuses: [String: RemoteProxyStatus]
    var remoteLogs: [String: String]

    init(
        proxyStatus: ApiProxyStatus,
        preferredPortText: String,
        autoStartProxy: Bool,
        cloudflaredStatus: CloudflaredStatus,
        cloudflaredTunnelMode: CloudflaredTunnelMode,
        cloudflaredNamedInput: NamedCloudflaredTunnelInput,
        cloudflaredUseHTTP2: Bool,
        publicAccessEnabled: Bool,
        remoteServers: [RemoteServerConfig],
        remoteStatuses: [String: RemoteProxyStatus],
        remoteLogs: [String: String]
    ) {
        self.proxyStatus = proxyStatus
        self.preferredPortText = preferredPortText
        self.autoStartProxy = autoStartProxy
        self.cloudflaredStatus = cloudflaredStatus
        self.cloudflaredTunnelMode = cloudflaredTunnelMode
        self.cloudflaredNamedInput = cloudflaredNamedInput
        self.cloudflaredUseHTTP2 = cloudflaredUseHTTP2
        self.publicAccessEnabled = publicAccessEnabled
        self.remoteServers = remoteServers
        self.remoteStatuses = remoteStatuses
        self.remoteLogs = remoteLogs
    }

    init(snapshot: ProxyControlSnapshot) {
        proxyStatus = snapshot.proxyStatus
        preferredPortText = String(snapshot.preferredProxyPort ?? snapshot.proxyStatus.port ?? 8787)
        autoStartProxy = snapshot.autoStartProxy
        cloudflaredStatus = snapshot.cloudflaredStatus
        cloudflaredTunnelMode = snapshot.cloudflaredTunnelMode
        cloudflaredNamedInput = snapshot.cloudflaredNamedInput
        cloudflaredUseHTTP2 = snapshot.cloudflaredUseHTTP2
        publicAccessEnabled = snapshot.publicAccessEnabled
        remoteServers = snapshot.remoteServers
        remoteStatuses = snapshot.remoteStatuses
        remoteLogs = snapshot.remoteLogs
    }
}

@MainActor
final class ProxyPageModel: ObservableObject {
    private let coordinator: ProxyCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let proxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol?
    private let dateProvider: DateProviding
    private let noticeScheduler = NoticeAutoDismissScheduler()
    private var didRunLaunchBootstrap = false
    private var remoteSnapshotTask: Task<Void, Never>?
    private var lastRemoteCommandID: String?
    private var proxyPushCancellable: AnyCancellable?

    @Published var proxyStatus: ApiProxyStatus = .idle
    @Published var cloudflaredStatus: CloudflaredStatus = .idle
    @Published var remoteServers: [RemoteServerConfig] = []
    @Published var remoteStatuses: [String: RemoteProxyStatus] = [:]
    @Published var remoteLogs: [String: String] = [:]
    @Published var remoteActions: [String: RemoteServerAction] = [:]

    @Published var preferredPortText = "8787"
    @Published var cloudflaredTunnelMode: CloudflaredTunnelMode = .quick
    @Published var cloudflaredNamedInput = NamedCloudflaredTunnelInput(
        apiToken: "",
        accountID: "",
        zoneID: "",
        hostname: ""
    )
    @Published var cloudflaredUseHTTP2 = false
    @Published var autoStartProxy = false
    @Published var publicAccessEnabled = false
    @Published var showsRemoteControlCallout = true
    @Published var apiProxySectionExpanded = false
    @Published var cloudflaredSectionExpanded = false

    @Published var loading = false
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }

    init(
        coordinator: ProxyCoordinator,
        settingsCoordinator: SettingsCoordinator,
        proxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol? = nil,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.coordinator = coordinator
        self.settingsCoordinator = settingsCoordinator
        self.proxyControlCloudSyncService = proxyControlCloudSyncService
        self.dateProvider = dateProvider
    }

    deinit {
        remoteSnapshotTask?.cancel()
    }

    var cloudflaredExpanded: Bool {
        cloudflaredSectionExpanded
    }

    var canStartCloudflared: Bool {
        guard !loading else { return false }
        guard proxyStatus.running, proxyStatus.port != nil else { return false }
        guard cloudflaredStatus.installed, !cloudflaredStatus.running else { return false }
        if cloudflaredTunnelMode == .quick {
            return true
        }
        return cloudflaredNamedInputReady
    }

    var canEditCloudflaredInput: Bool {
        !loading && !cloudflaredStatus.running
    }

    var cloudflaredNamedInputReady: Bool {
        !cloudflaredNamedInput.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !cloudflaredNamedInput.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !cloudflaredNamedInput.zoneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !cloudflaredNamedInput.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canManageRemoteServers: Bool {
        usesRemoteMacControl || PlatformCapabilities.supportsRemoteShellManagement
    }

    var canManagePublicTunnel: Bool {
        usesRemoteMacControl || PlatformCapabilities.supportsCloudflared
    }

    var usesRemoteMacControl: Bool {
        PlatformCapabilities.currentPlatform == .iOS && proxyControlCloudSyncService != nil
    }

    func dismissRemoteControlCallout() {
        showsRemoteControlCallout = false
    }

    func bootstrapOnAppLaunch(using settings: AppSettings) async {
        guard !didRunLaunchBootstrap else { return }
        didRunLaunchBootstrap = true

        autoStartProxy = settings.autoStartApiProxy
        if usesRemoteMacControl {
            configureProxyPushHandlingIfNeeded()
            await ensureProxyPushSubscriptionIfNeeded()
            await refreshRemoteSnapshot(showErrors: false)
            await requestRemoteSnapshotRefresh(showErrors: false)
            startRemoteSnapshotSyncIfNeeded()
            return
        }

        stopRemoteSnapshotSync()
        await refreshStatusOnly()

        guard settings.autoStartApiProxy, !proxyStatus.running else { return }

        do {
            proxyStatus = try await coordinator.startProxy(preferredPort: nil)
            await refreshStatusOnly()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshForTabEntry() async {
        if usesRemoteMacControl {
            await refreshRemoteSnapshot(showErrors: false)
            await requestRemoteSnapshotRefresh(showErrors: false)
            return
        }

        await refreshStatusOnly()
    }

    func load() async {
        loading = true
        defer { loading = false }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            remoteServers = settings.remoteServers
            autoStartProxy = settings.autoStartApiProxy
            if usesRemoteMacControl {
                configureProxyPushHandlingIfNeeded()
                await ensureProxyPushSubscriptionIfNeeded()
                await refreshRemoteSnapshot(showErrors: true)
                await requestRemoteSnapshotRefresh(showErrors: false)
                startRemoteSnapshotSyncIfNeeded()
            } else {
                stopRemoteSnapshotSync()
                await refreshStatusOnly()
                await refreshAllRemoteStatuses()
            }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshStatus() async {
        if usesRemoteMacControl {
            await requestRemoteSnapshotRefresh(showErrors: true, showLoading: true)
            return
        }
        loading = true
        defer { loading = false }
        await refreshStatusOnly()
    }

    func startProxy() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .startProxy,
                preferredProxyPort: Int(preferredPortText),
                successNotice: L10n.tr("proxy.notice.api_proxy_started")
            )
            return
        }
        loading = true
        defer { loading = false }

        let preferredPort = Int(preferredPortText)

        do {
            proxyStatus = try await coordinator.startProxy(preferredPort: preferredPort)
            await refreshStatusOnly()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_proxy_started"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func stopProxy() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .stopProxy,
                successNotice: L10n.tr("proxy.notice.api_proxy_stopped")
            )
            return
        }
        loading = true
        defer { loading = false }

        proxyStatus = await coordinator.stopProxy()
        await refreshStatusOnly()
        notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.api_proxy_stopped"))
    }

    func refreshAPIKey() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .refreshAPIKey,
                successNotice: L10n.tr("proxy.notice.api_key_refreshed")
            )
            return
        }
        loading = true
        defer { loading = false }

        do {
            proxyStatus = try await coordinator.refreshAPIKey()
            await refreshStatusOnly()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_key_refreshed"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func installCloudflared() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .installCloudflared,
                successNotice: L10n.tr("proxy.notice.cloudflared_installed")
            )
            return
        }
        loading = true
        defer { loading = false }

        do {
            let status = try await coordinator.installCloudflared()
            applyCloudflaredStatus(status)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.cloudflared_installed"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func startCloudflared() async {
        if usesRemoteMacControl {
            do {
                let input = try buildCloudflaredStartInput()
                await performRemoteCommand(
                    kind: .startCloudflared,
                    cloudflaredInput: input,
                    successNotice: L10n.tr("proxy.notice.cloudflared_started")
                )
            } catch {
                notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
            return
        }
        loading = true
        defer { loading = false }

        do {
            let input = try buildCloudflaredStartInput()
            let status = try await coordinator.startCloudflared(input: input)
            applyCloudflaredStatus(status)
            publicAccessEnabled = true
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.cloudflared_started"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func stopCloudflared() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .stopCloudflared,
                successNotice: L10n.tr("proxy.notice.cloudflared_stopped")
            )
            return
        }
        loading = true
        defer { loading = false }

        let status = await coordinator.stopCloudflared()
        applyCloudflaredStatus(status)
        notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.cloudflared_stopped"))
    }

    func refreshCloudflared() async {
        if usesRemoteMacControl {
            await requestRemoteSnapshotRefresh(showErrors: true, showLoading: true)
            return
        }
        let status = await coordinator.refreshCloudflared()
        applyCloudflaredStatus(status)
    }

    func setPublicAccessEnabled(_ enabled: Bool) async {
        guard canManagePublicTunnel else {
            publicAccessEnabled = false
            return
        }
        if usesRemoteMacControl {
            publicAccessEnabled = enabled
            if enabled {
                cloudflaredSectionExpanded = true
            } else {
                await performRemoteCommand(
                    kind: .stopCloudflared,
                    successNotice: L10n.tr("proxy.notice.cloudflared_stopped")
                )
            }
            return
        }
        if enabled {
            publicAccessEnabled = true
            cloudflaredSectionExpanded = true
            return
        }
        publicAccessEnabled = false
        guard cloudflaredStatus.running else { return }
        await stopCloudflared()
    }

    func setAutoStartProxy(_ value: Bool) async {
        if usesRemoteMacControl {
            autoStartProxy = value
            await performRemoteCommand(
                kind: .setAutoStartProxy,
                autoStartProxy: value,
                successNotice: L10n.tr("proxy.notice.auto_start_updated")
            )
            return
        }
        do {
            let updated = try await settingsCoordinator.updateSettings(AppSettingsPatch(autoStartApiProxy: value))
            autoStartProxy = updated.autoStartApiProxy
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.auto_start_updated"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func addRemoteServer() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .addRemoteServer,
                remoteServer: RemoteServerConfig(
                    id: UUID().uuidString,
                    label: "new-server",
                    host: "",
                    sshPort: 22,
                    sshUser: "root",
                    authMode: "keyPath",
                    identityFile: nil,
                    privateKey: nil,
                    password: nil,
                    remoteDir: "/opt/codex-tools",
                    listenPort: 8787
                ),
                successNotice: L10n.tr("settings.notice.remote_servers_saved")
            )
            return
        }
        do {
            let draft = RemoteServerConfig(
                id: UUID().uuidString,
                label: "new-server",
                host: "",
                sshPort: 22,
                sshUser: "root",
                authMode: "keyPath",
                identityFile: nil,
                privateKey: nil,
                password: nil,
                remoteDir: "/opt/codex-tools",
                listenPort: 8787
            )
            let merged = remoteServers + [draft]
            let updated = try await settingsCoordinator.updateSettings(AppSettingsPatch(remoteServers: merged))
            remoteServers = updated.remoteServers
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.notice.remote_servers_saved"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func saveRemoteServer(_ server: RemoteServerConfig) async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .saveRemoteServer,
                remoteServer: normalizeRemoteServer(server),
                successNotice: L10n.tr("settings.notice.remote_servers_saved")
            )
            return
        }
        remoteActions[server.id] = .save
        defer { remoteActions.removeValue(forKey: server.id) }
        do {
            let normalized = normalizeRemoteServer(server)
            var merged = remoteServers
            if let index = merged.firstIndex(where: { $0.id == normalized.id }) {
                merged[index] = normalized
            } else {
                merged.append(normalized)
            }
            let updated = try await settingsCoordinator.updateSettings(AppSettingsPatch(remoteServers: merged))
            remoteServers = updated.remoteServers
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.notice.remote_servers_saved"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func removeRemoteServer(id: String) async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .removeRemoteServer,
                remoteServerID: id,
                successNotice: L10n.tr("proxy.notice.remote_server_removed")
            )
            return
        }
        remoteActions[id] = .remove
        defer { remoteActions.removeValue(forKey: id) }
        do {
            let merged = remoteServers.filter { $0.id != id }
            let updated = try await settingsCoordinator.updateSettings(AppSettingsPatch(remoteServers: merged))
            remoteServers = updated.remoteServers
            remoteStatuses.removeValue(forKey: id)
            remoteLogs.removeValue(forKey: id)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_server_removed"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshAllRemoteStatuses() async {
        guard canManageRemoteServers else {
            remoteStatuses = [:]
            return
        }
        if usesRemoteMacControl {
            await refreshRemoteSnapshot(showErrors: false)
            return
        }
        for server in remoteServers {
            let status = await coordinator.remoteStatus(server: server)
            remoteStatuses[server.id] = status
        }
    }

    func refreshRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(kind: .refreshRemote, remoteServerID: server.id)
            return
        }
        remoteActions[server.id] = .refresh
        defer { remoteActions.removeValue(forKey: server.id) }
        let status = await coordinator.remoteStatus(server: server)
        remoteStatuses[server.id] = status
    }

    func deployRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .deployRemote,
                remoteServerID: server.id,
                successNotice: L10n.tr("proxy.notice.remote_deploy_done_format", server.label),
                pendingNotice: L10n.tr("proxy.notice.remote_deploying_format", server.label)
            )
            return
        }
        remoteActions[server.id] = .deploy
        defer { remoteActions.removeValue(forKey: server.id) }
        notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.remote_deploying_format", server.label))

        do {
            let status = try await coordinator.deployRemote(server: server)
            remoteStatuses[server.id] = status
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_deploy_done_format", server.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func startRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .startRemote,
                remoteServerID: server.id,
                successNotice: L10n.tr("proxy.notice.remote_started_format", server.label)
            )
            return
        }
        remoteActions[server.id] = .start
        defer { remoteActions.removeValue(forKey: server.id) }

        do {
            let status = try await coordinator.startRemote(server: server)
            remoteStatuses[server.id] = status
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_started_format", server.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func stopRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .stopRemote,
                remoteServerID: server.id,
                successNotice: L10n.tr("proxy.notice.remote_stopped_format", server.label)
            )
            return
        }
        remoteActions[server.id] = .stop
        defer { remoteActions.removeValue(forKey: server.id) }

        do {
            let status = try await coordinator.stopRemote(server: server)
            remoteStatuses[server.id] = status
            notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.remote_stopped_format", server.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func readRemoteLogs(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            remoteActions[server.id] = .logs
            defer { remoteActions.removeValue(forKey: server.id) }

            await performRemoteLogCommand(
                serverID: server.id,
                logLines: 120
            )
            return
        }
        remoteActions[server.id] = .logs
        defer { remoteActions.removeValue(forKey: server.id) }

        do {
            let logs = try await coordinator.readRemoteLogs(server: server, lines: 120)
            remoteLogs[server.id] = logs
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func refreshStatusOnly() async {
        let pair = await coordinator.loadStatus()
        proxyStatus = pair.0
        applyCloudflaredStatus(pair.1)
    }

    private func applyCloudflaredStatus(_ status: CloudflaredStatus) {
        cloudflaredStatus = status
        cloudflaredUseHTTP2 = status.useHTTP2
        if let mode = status.tunnelMode {
            cloudflaredTunnelMode = mode
        }
        if let hostname = status.customHostname?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostname.isEmpty {
            cloudflaredNamedInput.hostname = hostname
        }
        if status.running {
            publicAccessEnabled = true
            cloudflaredSectionExpanded = true
        }
    }

    private func buildCloudflaredStartInput() throws -> StartCloudflaredTunnelInput {
        guard let port = proxyStatus.port else {
            throw AppError.invalidData(L10n.tr("proxy.notice.start_api_proxy_first"))
        }

        let named: NamedCloudflaredTunnelInput?
        if cloudflaredTunnelMode == .named {
            named = try normalizedNamedInput()
        } else {
            named = nil
        }

        return StartCloudflaredTunnelInput(
            apiProxyPort: port,
            useHTTP2: cloudflaredUseHTTP2,
            mode: cloudflaredTunnelMode,
            named: named
        )
    }

    private func normalizedNamedInput() throws -> NamedCloudflaredTunnelInput {
        let apiToken = cloudflaredNamedInput.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = cloudflaredNamedInput.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let zoneID = cloudflaredNamedInput.zoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = cloudflaredNamedInput.hostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        guard !apiToken.isEmpty, !accountID.isEmpty, !zoneID.isEmpty, !hostname.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.cloudflared.named_required_fields"))
        }
        guard hostname.contains(".") else {
            throw AppError.invalidData(L10n.tr("error.cloudflared.named_invalid_hostname"))
        }

        return NamedCloudflaredTunnelInput(
            apiToken: apiToken,
            accountID: accountID,
            zoneID: zoneID,
            hostname: hostname
        )
    }

    private func normalizeRemoteServer(_ server: RemoteServerConfig) -> RemoteServerConfig {
        var value = server
        value.id = value.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.id.isEmpty {
            value.id = UUID().uuidString
        }
        value.label = value.label.trimmingCharacters(in: .whitespacesAndNewlines)
        value.host = value.host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.sshUser = value.sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        value.remoteDir = value.remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        value.identityFile = value.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        value.privateKey = value.privateKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        value.password = value.password?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private func startRemoteSnapshotSyncIfNeeded() {
        guard usesRemoteMacControl else { return }
        guard remoteSnapshotTask == nil else { return }

        remoteSnapshotTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self.refreshRemoteSnapshot(showErrors: false)
            }
        }
    }

    private func stopRemoteSnapshotSync() {
        remoteSnapshotTask?.cancel()
        remoteSnapshotTask = nil
    }

    private func configureProxyPushHandlingIfNeeded() {
        guard proxyPushCancellable == nil else { return }

        proxyPushCancellable = NotificationCenter.default
            .publisher(for: .copoolProxyControlPushDidArrive)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshRemoteSnapshot(showErrors: false)
                }
            }
    }

    private func ensureProxyPushSubscriptionIfNeeded() async {
        guard let proxyControlCloudSyncService else { return }
        do {
            try await proxyControlCloudSyncService.ensurePushSubscriptionIfNeeded()
        } catch {
            #if DEBUG
            print("CloudKit proxy push subscription skipped:", error.localizedDescription)
            #endif
        }
    }

    private func refreshRemoteSnapshot(showErrors: Bool) async {
        guard let proxyControlCloudSyncService else { return }

        do {
            if let snapshot = try await proxyControlCloudSyncService.pullRemoteSnapshot() {
                applyRemoteSnapshot(snapshot)
            }
        } catch {
            if showErrors {
                notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
        }
    }

    @discardableResult
    func applyRemoteSnapshot(_ snapshot: ProxyControlSnapshot) -> Bool {
        let nextState = RemoteSnapshotPresentationState(snapshot: snapshot)
        guard nextState != currentRemoteSnapshotPresentationState else {
            return false
        }

        setIfChanged(\.proxyStatus, nextState.proxyStatus)
        setIfChanged(\.preferredPortText, nextState.preferredPortText)
        setIfChanged(\.autoStartProxy, nextState.autoStartProxy)
        setIfChanged(\.cloudflaredStatus, nextState.cloudflaredStatus)
        setIfChanged(\.cloudflaredTunnelMode, nextState.cloudflaredTunnelMode)
        setIfChanged(\.cloudflaredNamedInput, nextState.cloudflaredNamedInput)
        setIfChanged(\.cloudflaredUseHTTP2, nextState.cloudflaredUseHTTP2)
        setIfChanged(\.publicAccessEnabled, nextState.publicAccessEnabled)
        setIfChanged(\.remoteServers, nextState.remoteServers)
        setIfChanged(\.remoteStatuses, nextState.remoteStatuses)
        setIfChanged(\.remoteLogs, nextState.remoteLogs)
        return true
    }

    private var currentRemoteSnapshotPresentationState: RemoteSnapshotPresentationState {
        RemoteSnapshotPresentationState(
            proxyStatus: proxyStatus,
            preferredPortText: preferredPortText,
            autoStartProxy: autoStartProxy,
            cloudflaredStatus: cloudflaredStatus,
            cloudflaredTunnelMode: cloudflaredTunnelMode,
            cloudflaredNamedInput: cloudflaredNamedInput,
            cloudflaredUseHTTP2: cloudflaredUseHTTP2,
            publicAccessEnabled: publicAccessEnabled,
            remoteServers: remoteServers,
            remoteStatuses: remoteStatuses,
            remoteLogs: remoteLogs
        )
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<ProxyPageModel, Value>,
        _ newValue: Value
    ) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }

    private func requestRemoteSnapshotRefresh(
        showErrors: Bool,
        showLoading: Bool = false
    ) async {
        guard let proxyControlCloudSyncService else { return }

        if showLoading {
            loading = true
        }
        defer {
            if showLoading {
                loading = false
            }
        }

        let command = ProxyControlCommand(
            id: UUID().uuidString,
            createdAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: "ios-proxy-control",
            kind: .refreshStatus,
            preferredProxyPort: nil,
            autoStartProxy: nil,
            cloudflaredInput: nil,
            remoteServer: nil,
            remoteServerID: nil,
            logLines: nil
        )

        do {
            try await proxyControlCloudSyncService.enqueueCommand(command)
            lastRemoteCommandID = command.id

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(command.id) {
                applyRemoteSnapshot(acknowledgedSnapshot)
            } else {
                await refreshRemoteSnapshot(showErrors: false)
            }
        } catch {
            if showErrors {
                notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
        }
    }

    private func performRemoteCommand(
        kind: ProxyControlCommandKind,
        preferredProxyPort: Int? = nil,
        autoStartProxy: Bool? = nil,
        cloudflaredInput: StartCloudflaredTunnelInput? = nil,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        logLines: Int? = nil,
        successNotice: String? = nil,
        pendingNotice: String? = nil
    ) async {
        guard let proxyControlCloudSyncService else { return }

        loading = true
        defer { loading = false }

        let command = ProxyControlCommand(
            id: UUID().uuidString,
            createdAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: "ios-proxy-control",
            kind: kind,
            preferredProxyPort: preferredProxyPort,
            autoStartProxy: autoStartProxy,
            cloudflaredInput: cloudflaredInput,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            logLines: logLines
        )

        do {
            try await proxyControlCloudSyncService.enqueueCommand(command)
            lastRemoteCommandID = command.id

            if let pendingNotice {
                notice = NoticeMessage(style: .info, text: pendingNotice)
            }

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(command.id) {
                applyRemoteSnapshot(acknowledgedSnapshot)
                if let error = acknowledgedSnapshot.lastCommandError,
                   acknowledgedSnapshot.lastHandledCommandID == command.id,
                   !error.isEmpty {
                    notice = NoticeMessage(style: .error, text: error)
                } else if let successNotice {
                    notice = NoticeMessage(style: .success, text: successNotice)
                }
            } else if let successNotice {
                notice = NoticeMessage(style: .info, text: successNotice)
            }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func performRemoteLogCommand(serverID: String, logLines: Int) async {
        guard let proxyControlCloudSyncService else { return }

        let previousLogs = remoteLogs[serverID]
        let command = ProxyControlCommand(
            id: UUID().uuidString,
            createdAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: "ios-proxy-control",
            kind: .readRemoteLogs,
            preferredProxyPort: nil,
            autoStartProxy: nil,
            cloudflaredInput: nil,
            remoteServer: nil,
            remoteServerID: serverID,
            logLines: logLines
        )

        do {
            try await proxyControlCloudSyncService.enqueueCommand(command)
            lastRemoteCommandID = command.id

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(
                command.id,
                pollLimit: 60,
                pollInterval: .milliseconds(500),
                acceptance: { snapshot in
                    if snapshot.lastHandledCommandID == command.id {
                        return true
                    }
                    return snapshot.remoteLogs[serverID] != previousLogs && snapshot.remoteLogs[serverID] != nil
                }
            ) {
                applyRemoteSnapshot(acknowledgedSnapshot)
                if let error = acknowledgedSnapshot.lastCommandError,
                   acknowledgedSnapshot.lastHandledCommandID == command.id,
                   !error.isEmpty {
                    notice = NoticeMessage(style: .error, text: error)
                }
            } else {
                await refreshRemoteSnapshot(showErrors: false)
                if remoteLogs[serverID] == previousLogs {
                    notice = NoticeMessage(style: .error, text: L10n.tr("error.remote.logs_unavailable"))
                }
            }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func waitForRemoteCommandAck(
        _ commandID: String,
        pollLimit: Int = 16,
        pollInterval: Duration = .milliseconds(500),
        acceptance: ((ProxyControlSnapshot) -> Bool)? = nil
    ) async throws -> ProxyControlSnapshot? {
        guard let proxyControlCloudSyncService else { return nil }

        for _ in 0..<pollLimit {
            if let snapshot = try await proxyControlCloudSyncService.pullRemoteSnapshot() {
                let isAccepted = acceptance?(snapshot) ?? (snapshot.lastHandledCommandID == commandID)
                if isAccepted {
                    return snapshot
                }
                applyRemoteSnapshot(snapshot)
            }
            try? await Task.sleep(for: pollInterval)
        }

        return nil
    }
}
