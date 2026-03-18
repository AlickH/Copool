import Foundation
import Combine

actor ProxyCoordinator {
    private let proxyService: ProxyRuntimeService
    private let cloudflaredService: CloudflaredServiceProtocol
    private let remoteService: RemoteProxyServiceProtocol

    init(
        proxyService: ProxyRuntimeService,
        cloudflaredService: CloudflaredServiceProtocol,
        remoteService: RemoteProxyServiceProtocol
    ) {
        self.proxyService = proxyService
        self.cloudflaredService = cloudflaredService
        self.remoteService = remoteService
    }

    func loadStatus() async -> (ApiProxyStatus, CloudflaredStatus) {
        async let proxy = proxyService.status()
        async let cloudflared = cloudflaredService.status()
        return await (proxy, cloudflared)
    }

    func startProxy(preferredPort: Int?) async throws -> ApiProxyStatus {
        try await proxyService.syncAccountsStore()
        return try await proxyService.start(preferredPort: preferredPort)
    }

    func stopProxy() async -> ApiProxyStatus {
        await proxyService.stop()
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        try await proxyService.refreshAPIKey()
    }

    func installCloudflared() async throws -> CloudflaredStatus {
        try await cloudflaredService.install()
    }

    func startCloudflared(input: StartCloudflaredTunnelInput) async throws -> CloudflaredStatus {
        try await cloudflaredService.start(input)
    }

    func stopCloudflared() async -> CloudflaredStatus {
        await cloudflaredService.stop()
    }

    func refreshCloudflared() async -> CloudflaredStatus {
        await cloudflaredService.status()
    }

    func remoteStatus(server: RemoteServerConfig) async -> RemoteProxyStatus {
        await remoteService.status(server: server)
    }

    func deployRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.deploy(server: server)
    }

    func startRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.start(server: server)
    }

    func stopRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.stop(server: server)
    }

    func readRemoteLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        try await remoteService.readLogs(server: server, lines: lines)
    }
}
