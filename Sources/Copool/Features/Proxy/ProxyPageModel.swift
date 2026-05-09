import Foundation
import Combine

enum RemoteDeployFeedbackState: Equatable {
    case deploying
    case success
    case failure
}

struct RemoteDeployFeedback: Equatable {
    let state: RemoteDeployFeedbackState
    let message: String

    var isDismissible: Bool {
        state == .failure
    }
}

@MainActor
final class ProxyPageModel: ObservableObject {
    let coordinator: ProxyCoordinator
    let settingsCoordinator: SettingsCoordinator
    let proxyControlRemoteCommandService: ProxyControlRemoteCommandServiceProtocol?
    let localProxyCommandService: ProxyLocalCommandServiceProtocol?
    let dateProvider: DateProviding
    let runtimePlatform: RuntimePlatform
    let chooseIdentityFilePath: @MainActor () -> String?

    private let noticeScheduler = NoticeAutoDismissScheduler()

    var hasLoaded = false
    var didRunLaunchBootstrap = false
    var remoteSnapshotTask: Task<Void, Never>?
    var lastRemoteCommandID: String?
    var lastHandledRemoteCommandID: String?
    var lastRemoteCommandError: String?
    var lastAppliedRemoteSnapshot: ProxyControlSnapshot?
    var lastAppliedRemoteSnapshotSyncedAt: Int64?
    var lastAppliedRemoteStatusesSyncedAt: Int64?
    var localSnapshotCancellable: AnyCancellable?
    var pendingConfigurationSyncTask: Task<Void, Never>?
    var remoteDeployFeedbackDismissTasks: [String: Task<Void, Never>] = [:]
    var remoteDeploySuccessAutoDismissDelay: Duration = .seconds(3)
    var lastSyncedProxyConfiguration: ProxyConfiguration?

    @Published var proxyStatus: ApiProxyStatus = .idle
    @Published var cloudflaredStatus: CloudflaredStatus = .idle
    @Published var remoteServers: [RemoteServerConfig] = []
    @Published var remoteStatuses: [String: RemoteProxyStatus] = [:]
    @Published var remoteDiscoveries: [String: [DiscoveredRemoteProxyInstance]] = [:]
    @Published var remoteLogs: [String: String] = [:]
    @Published var remoteActions: [String: RemoteServerAction] = [:]
    @Published var remoteDeployFeedbacks: [String: RemoteDeployFeedback] = [:]

    @Published var preferredPortText = String(RemoteServerConfiguration.defaultProxyPort)
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
        proxyControlRemoteCommandService: ProxyControlRemoteCommandServiceProtocol? = nil,
        localProxyCommandService: ProxyLocalCommandServiceProtocol? = nil,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform,
        chooseIdentityFilePath: @escaping @MainActor () -> String? = { nil }
    ) {
        self.coordinator = coordinator
        self.settingsCoordinator = settingsCoordinator
        self.proxyControlRemoteCommandService = proxyControlRemoteCommandService
        self.localProxyCommandService = localProxyCommandService
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
        self.chooseIdentityFilePath = chooseIdentityFilePath
        configureLocalSnapshotHandlingIfNeeded()
    }

    deinit {
        remoteSnapshotTask?.cancel()
        pendingConfigurationSyncTask?.cancel()
        remoteDeployFeedbackDismissTasks.values.forEach { $0.cancel() }
    }

    var canStartCloudflared: Bool {
        guard !loading else { return false }
        guard publicAccessEnabled else { return false }
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
        usesRemoteMacControl || runtimePlatform == .macOS
    }

    var canManagePublicTunnel: Bool {
        usesRemoteMacControl || runtimePlatform == .macOS
    }

    var usesRemoteMacControl: Bool {
        false
    }

    var apiProxyActionButtons: [ProxyActionButtonDescriptor<ApiProxyActionIntent>] {
        ProxyActionPresentation.apiProxyButtons(
            isRunning: proxyStatus.running,
            isLoading: loading
        )
    }

    var publicAccessInstallButton: ProxyActionButtonDescriptor<PublicAccessActionIntent> {
        ProxyActionPresentation.publicAccessInstallButton(
            isLoading: loading
        )
    }

    var publicAccessActionButtons: [ProxyActionButtonDescriptor<PublicAccessActionIntent>] {
        ProxyActionPresentation.publicAccessButtons(
            isRunning: cloudflaredStatus.running,
            isLoading: loading,
            canStart: canStartCloudflared
        )
    }

    func handleAPIProxyAction(_ intent: ApiProxyActionIntent) async {
        switch intent {
        case .refreshStatus:
            await refreshStatus()
        case .start:
            await startProxy()
        case .stop:
            await stopProxy()
        }
    }

    func handlePublicAccessAction(_ intent: PublicAccessActionIntent) async {
        switch intent {
        case .install:
            await installCloudflared()
        case .refreshStatus:
            await refreshCloudflared()
        case .start:
            await startCloudflared()
        case .stop:
            await stopCloudflared()
        }
    }
}
