import XCTest
import Combine
@testable import Copool

@MainActor
final class ProxyPageModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testMacOSModelAppliesLocalSnapshotBroadcastWithoutPageReload() async throws {
        let model = makeModel(runtimePlatform: .macOS)
        let runningSnapshot = makeSnapshot()
        XCTAssertTrue(model.applyRemoteSnapshot(runningSnapshot))
        XCTAssertTrue(model.publicAccessEnabled)
        XCTAssertTrue(model.cloudflaredStatus.running)

        var stoppedSnapshot = runningSnapshot
        stoppedSnapshot.syncedAt += 1_000
        stoppedSnapshot.cloudflaredStatus.running = false
        stoppedSnapshot.cloudflaredStatus.publicURL = nil
        stoppedSnapshot.publicAccessEnabled = false

        NotificationCenter.default.post(
            name: .copoolLocalProxySnapshotDidUpdate,
            object: nil,
            userInfo: [ProxyControlNotificationPayloadKey.snapshot: stoppedSnapshot]
        )
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(model.publicAccessEnabled)
        XCTAssertFalse(model.cloudflaredStatus.running)
    }

    func testRefreshForTabEntryPreservesPublicAccessConfiguration() async {
        let model = makeModel(
            cloudflaredService: StubCloudflaredService(statusValue: .idle),
            runtimePlatform: .macOS,
            settings: AppSettings(
                launchAtStartup: false,
                launchCodexAfterSwitch: true,
                autoSmartSwitch: false,
                syncOpencodeOpenaiAuth: false,
                restartEditorsOnSwitch: false,
                restartEditorTargets: [],
                autoStartApiProxy: false,
                proxyConfiguration: ProxyConfiguration(
                    cloudflared: CloudflaredConfiguration(enabled: true)
                ),
                remoteServers: [],
                locale: AppLocale.systemDefault.identifier
            )
        )

        await model.refreshForTabEntry()

        XCTAssertTrue(model.publicAccessEnabled)
    }

    func testApplyRemoteSnapshotPreservesLocalNamedTunnelSecrets() {
        let model = makeModel()
        model.cloudflaredNamedInput = NamedCloudflaredTunnelInput(
            apiToken: "secret-token",
            accountID: "account-secret",
            zoneID: "zone-secret",
            hostname: "local.example.com"
        )

        var snapshot = makeSnapshot()
        snapshot.cloudflaredTunnelMode = .named
        snapshot.cloudflaredNamedInput = NamedCloudflaredTunnelInput(
            apiToken: "",
            accountID: "",
            zoneID: "",
            hostname: "synced.example.com"
        )

        XCTAssertTrue(model.applyRemoteSnapshot(snapshot))
        XCTAssertEqual(model.cloudflaredNamedInput.apiToken, "secret-token")
        XCTAssertEqual(model.cloudflaredNamedInput.accountID, "account-secret")
        XCTAssertEqual(model.cloudflaredNamedInput.zoneID, "zone-secret")
        XCTAssertEqual(model.cloudflaredNamedInput.hostname, "synced.example.com")
    }

    func testApplyRemoteSnapshotTrimsOversizedRemoteLogsToPolicyCap() {
        let model = makeModel()
        var snapshot = makeSnapshot()
        let oversizedLogs = String(repeating: "0123456789", count: 1_400)
        snapshot.remoteLogs["server-1"] = oversizedLogs

        XCTAssertTrue(model.applyRemoteSnapshot(snapshot))

        let expectedLogs = ProxySyncPolicy.RemoteLogs.normalize(oversizedLogs)
        XCTAssertEqual(model.remoteLogs["server-1"], expectedLogs)
        XCTAssertEqual(model.lastAppliedRemoteSnapshot?.remoteLogs["server-1"], expectedLogs)
        XCTAssertLessThanOrEqual(expectedLogs.count, ProxySyncPolicy.RemoteLogs.maxCharactersPerServer)
    }

    func testApplyRemoteSnapshotUpdatesSyncedConfigurationForMetadataOnlyAck() {
        let model = makeModel()
        model.lastSyncedProxyConfiguration = ProxyConfiguration(
            preferredPortText: "8787",
            cloudflared: CloudflaredConfiguration(enabled: false)
        )

        var appliedSnapshot = makeSnapshot()
        appliedSnapshot.preferredProxyPort = 9000
        appliedSnapshot.preferredProxyPortText = "9000"
        appliedSnapshot.publicAccessEnabled = true
        appliedSnapshot.cloudflaredTunnelMode = .named
        appliedSnapshot.cloudflaredUseHTTP2 = true
        appliedSnapshot.cloudflaredNamedInput.hostname = "edge.example.com"

        XCTAssertTrue(model.applyRemoteSnapshot(appliedSnapshot))

        var metadataOnlyAck = appliedSnapshot
        metadataOnlyAck.syncedAt += 1_000
        metadataOnlyAck.lastHandledCommandID = "command-1"

        XCTAssertFalse(model.applyRemoteSnapshot(metadataOnlyAck))
        XCTAssertEqual(
            model.lastSyncedProxyConfiguration,
            ProxyConfiguration(
                preferredPortText: "9000",
                cloudflared: CloudflaredConfiguration(
                    enabled: true,
                    tunnelMode: .named,
                    useHTTP2: true,
                    namedHostname: "edge.example.com"
                )
            )
        )
    }

    func testUpdateCloudflaredUseHTTP2SyncsProxyConfigurationLocally() async {
        let snapshot = makeSnapshot()
        let localCommandService = SpyProxyLocalCommandService(snapshot: snapshot)
        let model = makeModel(localProxyCommandService: localCommandService)

        model.updateCloudflaredUseHTTP2(true)
        try? await Task.sleep(for: .milliseconds(450))

        XCTAssertEqual(localCommandService.commands.map(\.kind), [.updateProxyConfiguration])
        XCTAssertEqual(localCommandService.commands.first?.proxyConfiguration?.cloudflared.useHTTP2, true)
    }

    func testSetPublicAccessEnabledSyncsProxyConfigurationWithoutStartingCloudflared() async {
        var snapshot = makeSnapshot()
        snapshot.proxyStatus.running = true
        snapshot.proxyStatus.port = 8787
        snapshot.cloudflaredStatus.installed = true
        snapshot.cloudflaredStatus.running = false
        snapshot.publicAccessEnabled = false

        let localCommandService = SpyProxyLocalCommandService(snapshot: snapshot)
        let model = makeModel(localProxyCommandService: localCommandService)
        _ = model.applyRemoteSnapshot(snapshot)

        await model.setPublicAccessEnabled(true)

        XCTAssertEqual(localCommandService.commands.last?.kind, .updateProxyConfiguration)
        XCTAssertEqual(localCommandService.commands.last?.proxyConfiguration?.cloudflared.enabled, true)
    }

    func testPublicAccessEnabledBindingDispatchesConfigurationSync() async {
        var snapshot = makeSnapshot()
        snapshot.proxyStatus.running = true
        snapshot.proxyStatus.port = 8787
        snapshot.cloudflaredStatus.installed = true
        snapshot.cloudflaredStatus.running = false
        snapshot.publicAccessEnabled = false

        let localCommandService = SpyProxyLocalCommandService(snapshot: snapshot)
        let model = makeModel(localProxyCommandService: localCommandService)
        _ = model.applyRemoteSnapshot(snapshot)

        model.publicAccessEnabledBinding.wrappedValue = true
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(localCommandService.commands.last?.kind, .updateProxyConfiguration)
        XCTAssertEqual(localCommandService.commands.last?.proxyConfiguration?.cloudflared.enabled, true)
    }

    func testRemoteServerCardActionsUseInjectedIdentityPicker() {
        let model = makeModel(chooseIdentityFilePath: { "/tmp/id_ed25519" })
        let server = makeSnapshot().remoteServers[0]

        let actions = model.remoteServerCardActions(for: server)

        XCTAssertEqual(actions.onChooseIdentityFile(), "/tmp/id_ed25519")
    }

    func testCannotStartCloudflaredWhenPublicAccessDisabled() async {
        var snapshot = makeSnapshot()
        snapshot.cloudflaredStatus.running = false
        snapshot.publicAccessEnabled = false

        let model = makeModel()
        _ = model.applyRemoteSnapshot(snapshot)

        XCTAssertFalse(model.canStartCloudflared)
    }

    func testAPIProxyActionButtonsSwitchPrimaryIntentWithRuntimeState() {
        let stoppedButtons = ProxyActionPresentation.apiProxyButtons(
            isRunning: false,
            isLoading: false
        )
        XCTAssertEqual(stoppedButtons.map(\.intent), [.refreshStatus, .start])
        XCTAssertEqual(stoppedButtons.last?.surfaceStyle, .prominent)

        let runningButtons = ProxyActionPresentation.apiProxyButtons(
            isRunning: true,
            isLoading: false
        )
        XCTAssertEqual(runningButtons.map(\.intent), [.refreshStatus, .stop])
        XCTAssertEqual(runningButtons.last?.role, .destructive)
    }

    func testPublicAccessActionButtonsDisableStartWhenStartPreconditionsFail() {
        let buttons = ProxyActionPresentation.publicAccessButtons(
            isRunning: false,
            isLoading: false,
            canStart: false
        )

        XCTAssertEqual(buttons.map(\.intent), [.refreshStatus, .start])
        XCTAssertEqual(buttons.last?.isEnabled, false)
    }

    func testRemoteServerButtonsExposeProgressThroughDescriptorState() {
        let buttons = ProxyActionPresentation.remoteServerButtons(
            isRunning: false,
            activeAction: .deploy
        )

        XCTAssertEqual(
            buttons.map(\.intent),
            [.save, .removeLocal, .discover, .deploy, .syncAccounts, .refresh, .start, .logs, .uninstall]
        )
        XCTAssertEqual(buttons.first(where: { $0.intent == .deploy })?.showsProgress, true)
        XCTAssertEqual(buttons.first(where: { $0.intent == .deploy })?.isEnabled, false)
    }

    func testRemoteServerActionHelpPresentationMatchesButtonOrder() {
        let buttons = ProxyActionPresentation.remoteServerButtons(
            isRunning: true,
            activeAction: nil
        )

        let helpDescriptors = RemoteServerActionHelpPresentation.descriptors(from: buttons)

        XCTAssertEqual(
            helpDescriptors.map(\.action),
            [.save, .removeLocal, .discover, .deploy, .syncAccounts, .refresh, .stop, .logs, .uninstall]
        )
    }

    func testLocalStartProxyUsesLocalCommandServiceForImmediateSync() async {
        let snapshot = makeSnapshot()
        let localCommandService = SpyProxyLocalCommandService(snapshot: snapshot)
        let model = makeModel(localProxyCommandService: localCommandService)
        model.preferredPortText = "8787"

        await model.startProxy()

        XCTAssertEqual(model.proxyStatus, snapshot.proxyStatus)
        XCTAssertEqual(localCommandService.commands.map(\.kind), [.startProxy])
        XCTAssertEqual(localCommandService.commands.first?.preferredProxyPort, 8787)
    }

    func testAdoptDiscoveredRemoteServerSavesWithPreviousIDAndRefreshesNewIdentity() async {
        let snapshot = makeSnapshot()
        let localCommandService = SpyProxyLocalCommandService(snapshot: snapshot)
        let model = makeModel(localProxyCommandService: localCommandService)

        let adopted = RemoteServerConfig(
            id: "discovered-server",
            label: "Tokyo Recovered",
            host: "1.2.3.4",
            sshPort: 22,
            sshUser: "root",
            authMode: "keyPath",
            identityFile: "~/.ssh/id_ed25519",
            privateKey: nil,
            password: nil,
            remoteDir: "/srv/copool",
            listenPort: 9898
        )

        await model.adoptDiscoveredRemoteServer(adopted, previousServerID: "server-1")

        XCTAssertEqual(localCommandService.commands.map(\.kind), [.saveRemoteServer, .refreshRemote])
        XCTAssertEqual(localCommandService.commands.first?.remoteServer?.id, "discovered-server")
        XCTAssertEqual(localCommandService.commands.first?.previousRemoteServerID, "server-1")
        XCTAssertEqual(localCommandService.commands.last?.remoteServerID, "discovered-server")
    }

    func testDeployRemoteUsesLocalCommandServiceAndSetsSuccessNotice() async {
        let snapshot = makeSnapshot()
        let localCommandService = SpyProxyLocalCommandService(snapshot: snapshot)
        let model = makeModel(localProxyCommandService: localCommandService)
        let server = snapshot.remoteServers[0]

        await model.deployRemote(server: server)

        XCTAssertEqual(localCommandService.commands.map(\.kind), [.deployRemote])
        XCTAssertEqual(localCommandService.commands.first?.remoteServerID, server.id)
        XCTAssertEqual(
            model.notice,
            NoticeMessage(
                style: .success,
                text: L10n.tr("proxy.notice.remote_deploy_done_format", server.label)
            )
        )
        XCTAssertEqual(model.remoteStatuses, snapshot.remoteStatuses)
    }

    func testDeployRemoteShowsDeployingThenAutoDismissesSuccessFeedback() async {
        let snapshot = makeSnapshot()
        let localCommandService = SlowProxyLocalCommandService(
            snapshot: snapshot,
            delay: .milliseconds(80)
        )
        let model = makeModel(
            localProxyCommandService: localCommandService
        )
        model.remoteDeploySuccessAutoDismissDelay = .milliseconds(80)
        let server = snapshot.remoteServers[0]

        let task = Task { await model.deployRemote(server: server) }
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(
            model.remoteDeployFeedbacks[server.id],
            RemoteDeployFeedback(state: .deploying, message: L10n.tr("proxy.notice.remote_deploying_format", server.label))
        )

        await task.value

        XCTAssertEqual(
            model.remoteDeployFeedbacks[server.id],
            RemoteDeployFeedback(state: .success, message: L10n.tr("proxy.notice.remote_deploy_done_format", server.label))
        )

        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(model.remoteDeployFeedbacks[server.id])
    }

    func testDeployRemoteKeepsFailureFeedbackUntilDismissed() async {
        let model = makeModel(
            localProxyCommandService: FailingProxyLocalCommandService(
                error: AppError.io("sudo failed")
            )
        )
        model.remoteDeploySuccessAutoDismissDelay = .milliseconds(20)
        let server = makeSnapshot().remoteServers[0]

        await model.deployRemote(server: server)

        XCTAssertEqual(
            model.remoteDeployFeedbacks[server.id],
            RemoteDeployFeedback(state: .failure, message: "sudo failed")
        )

        model.dismissRemoteDeployFeedback(for: server.id)

        XCTAssertNil(model.remoteDeployFeedbacks[server.id])
    }

    private func makeModel(
        localProxyCommandService: ProxyLocalCommandServiceProtocol? = nil,
        cloudflaredService: CloudflaredServiceProtocol = StubCloudflaredService(),
        runtimePlatform: RuntimePlatform = .macOS,
        settings: AppSettings = .defaultValue,
        chooseIdentityFilePath: @escaping @MainActor () -> String? = { nil }
    ) -> ProxyPageModel {
        let proxyCoordinator = ProxyCoordinator(
            proxyService: StubProxyRuntimeService(),
            cloudflaredService: cloudflaredService,
            remoteService: StubRemoteProxyService()
        )
        let settingsCoordinator = SettingsCoordinator(
            settingsRepository: TestSettingsRepository(settings: settings),
            launchAtStartupService: StubLaunchAtStartupService()
        )

        let model = ProxyPageModel(
            coordinator: proxyCoordinator,
            settingsCoordinator: settingsCoordinator,
            localProxyCommandService: localProxyCommandService,
            runtimePlatform: runtimePlatform,
            chooseIdentityFilePath: chooseIdentityFilePath
        )
        return model
    }

    private func makeSnapshot() -> ProxyControlSnapshot {
        let server = RemoteServerConfig(
            id: "server-1",
            label: "Tokyo",
            host: "1.2.3.4",
            sshPort: 22,
            sshUser: "root",
            authMode: "keyPath",
            identityFile: "~/.ssh/id_ed25519",
            privateKey: nil,
            password: nil,
            remoteDir: "/opt/codex-tools",
            listenPort: 8787
        )
        let proxyStatus = ApiProxyStatus(
            running: true,
            port: 8787,
            apiKey: "api-key",
            baseURL: "http://127.0.0.1:8787",
            availableAccounts: 3,
            activeAccountID: "acct-1",
            activeAccountLabel: "Primary",
            lastError: nil
        )
        let cloudflaredStatus = CloudflaredStatus(
            installed: true,
            binaryPath: "/usr/local/bin/cloudflared",
            running: true,
            tunnelMode: .quick,
            publicURL: "https://example.trycloudflare.com",
            customHostname: nil,
            useHTTP2: true,
            lastError: nil
        )
        let remoteStatus = RemoteProxyStatus(
            installed: true,
            serviceInstalled: true,
            running: true,
            enabled: true,
            serviceName: "copool-proxy",
            pid: 42,
            baseURL: "http://1.2.3.4:8787",
            apiKey: "remote-api-key",
            lastError: nil
        )

        return ProxyControlSnapshot(
            syncedAt: 1_763_216_000_000,
            sourceDeviceID: "ios-device-1",
            proxyStatus: proxyStatus,
            preferredProxyPort: 8787,
            preferredProxyPortText: "8787",
            autoStartProxy: true,
            cloudflaredStatus: cloudflaredStatus,
            cloudflaredTunnelMode: .quick,
            cloudflaredNamedInput: NamedCloudflaredTunnelInput(
                apiToken: "",
                accountID: "",
                zoneID: "",
                hostname: ""
            ),
            cloudflaredUseHTTP2: true,
            publicAccessEnabled: true,
            remoteServers: [server],
            remoteStatusesSyncedAt: 1_763_216_000_000,
            remoteStatuses: [server.id: remoteStatus],
            remoteLogs: [server.id: "hello"],
            lastHandledCommandID: nil,
            lastCommandError: nil
        )
    }
}


private final class SpyProxyLocalCommandService: ProxyLocalCommandServiceProtocol, @unchecked Sendable {
    private(set) var commands: [ProxyControlCommand] = []
    private let snapshot: ProxyControlSnapshot

    init(snapshot: ProxyControlSnapshot) {
        self.snapshot = snapshot
    }

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        commands.append(command)
        return snapshot
    }
}

private final class SlowProxyLocalCommandService: ProxyLocalCommandServiceProtocol, @unchecked Sendable {
    private let snapshot: ProxyControlSnapshot
    private let delay: Duration

    init(snapshot: ProxyControlSnapshot, delay: Duration) {
        self.snapshot = snapshot
        self.delay = delay
    }

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        _ = command
        try? await Task.sleep(for: delay)
        return snapshot
    }
}

private struct FailingProxyLocalCommandService: ProxyLocalCommandServiceProtocol {
    let error: Error

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        _ = command
        throw error
    }
}

private struct StubLaunchAtStartupService: LaunchAtStartupServiceProtocol {
    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        _ = enabled
    }
}

private struct StubProxyRuntimeService: ProxyRuntimeService {
    func status() async -> ApiProxyStatus { .idle }
    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        _ = preferredPort
        return .idle
    }
    func stop() async -> ApiProxyStatus { .idle }
    func refreshAPIKey() async throws -> ApiProxyStatus { .idle }
    func syncAccountsStore() async throws {}
}

private struct StubCloudflaredService: CloudflaredServiceProtocol {
    var statusValue: CloudflaredStatus = .idle

    func status() async -> CloudflaredStatus { statusValue }
    func install() async throws -> CloudflaredStatus { statusValue }
    func start(_ input: StartCloudflaredTunnelInput) async throws -> CloudflaredStatus {
        _ = input
        return statusValue
    }
    func stop() async -> CloudflaredStatus { statusValue }
}

private struct StubRemoteProxyService: RemoteProxyServiceProtocol {
    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        _ = server
        return RemoteProxyStatus(
            installed: false,
            serviceInstalled: false,
            running: false,
            enabled: false,
            serviceName: "",
            pid: nil,
            baseURL: "",
            apiKey: nil,
            lastError: nil
        )
    }

    func discover(server: RemoteServerConfig) async throws -> [DiscoveredRemoteProxyInstance] {
        _ = server
        return []
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func syncAccounts(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        _ = server
        _ = lines
        return ""
    }

    func uninstall(server: RemoteServerConfig, removeRemoteDirectory: Bool) async throws -> RemoteProxyStatus {
        _ = removeRemoteDirectory
        return await status(server: server)
    }
}
