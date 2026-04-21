import SwiftUI

struct RemoteServerCardActions {
    let onSave: (String, RemoteServerConfig) -> Void
    let onRemove: (String) -> Void
    let onDiscover: (RemoteServerConfig) -> Void
    let onUseDiscoveredInstance: (String, RemoteServerConfig) -> Void
    let onRefresh: () -> Void
    let onDeploy: () -> Void
    let onSyncAccounts: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onLogs: () -> Void
    let onUninstall: () -> Void
    let onDismissDeployFeedback: () -> Void
    let onChooseIdentityFile: () -> String?
}

extension ProxyPageModel {
    var preferredPortBinding: Binding<String> {
        Binding(
            get: { self.preferredPortText },
            set: { self.updatePreferredPortText($0) }
        )
    }

    var autoStartProxyBinding: Binding<Bool> {
        Binding(
            get: { self.autoStartProxy },
            set: { value in
                self.dispatchAutoStartProxyUpdate(value)
            }
        )
    }

    var publicAccessEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.publicAccessEnabled },
            set: { value in
                self.dispatchPublicAccessEnabledUpdate(value)
            }
        )
    }

    var cloudflaredAPITokenBinding: Binding<String> {
        namedTunnelBinding(
            get: { $0.apiToken },
            set: { $0.apiToken = $1 }
        )
    }

    var cloudflaredAccountIDBinding: Binding<String> {
        namedTunnelBinding(
            get: { $0.accountID },
            set: { $0.accountID = $1 }
        )
    }

    var cloudflaredZoneIDBinding: Binding<String> {
        namedTunnelBinding(
            get: { $0.zoneID },
            set: { $0.zoneID = $1 }
        )
    }

    var cloudflaredHostnameBinding: Binding<String> {
        Binding(
            get: { self.cloudflaredNamedInput.hostname },
            set: { self.updateCloudflaredNamedHostname($0) }
        )
    }

    func dispatchRefreshAPIKey() {
        Task { await refreshAPIKey() }
    }

    func dispatchAddRemoteServer() {
        Task { await addRemoteServer() }
    }

    func remoteServerCardActions(for server: RemoteServerConfig) -> RemoteServerCardActions {
        RemoteServerCardActions(
            onSave: { originalID, updated in
                Task { await self.saveRemoteServer(updated, previousServerID: originalID) }
            },
            onRemove: { id in
                Task { await self.removeRemoteServer(id: id) }
            },
            onDiscover: { candidate in
                Task { await self.discoverRemote(server: candidate) }
            },
            onUseDiscoveredInstance: { originalID, updated in
                Task { await self.adoptDiscoveredRemoteServer(updated, previousServerID: originalID) }
            },
            onRefresh: {
                Task { await self.refreshRemote(server: server) }
            },
            onDeploy: {
                Task { await self.deployRemote(server: server) }
            },
            onSyncAccounts: {
                Task { await self.syncRemoteAccounts(server: server) }
            },
            onStart: {
                Task { await self.startRemote(server: server) }
            },
            onStop: {
                Task { await self.stopRemote(server: server) }
            },
            onLogs: {
                Task { await self.readRemoteLogs(server: server) }
            },
            onUninstall: {
                Task { await self.uninstallRemote(server: server) }
            },
            onDismissDeployFeedback: {
                self.dismissRemoteDeployFeedback(for: server.id)
            },
            onChooseIdentityFile: chooseIdentityFilePath
        )
    }

    func dispatchAutoStartProxyUpdate(_ value: Bool) {
        Task { await setAutoStartProxy(value) }
    }

    func dispatchPublicAccessEnabledUpdate(_ value: Bool) {
        Task { await setPublicAccessEnabled(value) }
    }

    private func namedTunnelBinding(
        get: @escaping (NamedCloudflaredTunnelInput) -> String,
        set: @escaping (inout NamedCloudflaredTunnelInput, String) -> Void
    ) -> Binding<String> {
        Binding(
            get: { get(self.cloudflaredNamedInput) },
            set: { value in
                var next = self.cloudflaredNamedInput
                set(&next, value)
                self.cloudflaredNamedInput = next
            }
        )
    }
}
