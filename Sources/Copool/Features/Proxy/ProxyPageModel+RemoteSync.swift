import Foundation
import Combine

extension ProxyPageModel {
    func startRemoteSnapshotSyncIfNeeded() {
        guard usesRemoteMacControl else { return }
        guard remoteSnapshotTask == nil else { return }

        remoteSnapshotTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: ProxySyncPolicy.RemoteControl.snapshotSyncInterval)
                await self.refreshRemoteSnapshot(showErrors: false)
            }
        }
    }

    func stopRemoteSnapshotSync() {
        remoteSnapshotTask?.cancel()
        remoteSnapshotTask = nil
    }

    func configureLocalSnapshotHandlingIfNeeded() {
        guard runtimePlatform == .macOS else { return }
        guard localSnapshotCancellable == nil else { return }

        localSnapshotCancellable = NotificationCenter.default
            .publisher(for: .copoolLocalProxySnapshotDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let snapshot = notification.userInfo?[ProxyControlNotificationPayloadKey.snapshot] as? ProxyControlSnapshot else { return }
                self.applyRemoteSnapshot(snapshot)
            }
    }

    @discardableResult
    func refreshRemoteSnapshot(showErrors: Bool) async -> Bool {
        guard let proxyControlRemoteCommandService else { return false }

        do {
            if let snapshot = try await proxyControlRemoteCommandService.pullRemoteSnapshot() {
                return applyRemoteSnapshot(snapshot)
            }
        } catch {
            if showErrors {
                notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
        }

        return false
    }

    @discardableResult
    func applyRemoteSnapshot(_ snapshot: ProxyControlSnapshot) -> Bool {
        let normalizedSnapshot = ProxySyncPolicy.RemoteLogs.normalize(snapshot)
        let nextState = ProxyRemoteSnapshotPresentationState(snapshot: normalizedSnapshot)
        lastAppliedRemoteSnapshot = normalizedSnapshot
        lastHandledRemoteCommandID = normalizedSnapshot.lastHandledCommandID
        lastRemoteCommandError = normalizedSnapshot.lastCommandError
        lastAppliedRemoteSnapshotSyncedAt = normalizedSnapshot.syncedAt
        lastAppliedRemoteStatusesSyncedAt = normalizedSnapshot.remoteStatusesSyncedAt
        lastSyncedProxyConfiguration = ProxyConfiguration(
            preferredPortText: nextState.preferredPortText,
            cloudflared: CloudflaredConfiguration(
                enabled: nextState.publicAccessEnabled,
                tunnelMode: nextState.cloudflaredTunnelMode,
                useHTTP2: nextState.cloudflaredUseHTTP2,
                namedHostname: nextState.cloudflaredNamedHostname
            )
        )
        guard nextState != currentRemoteSnapshotPresentationState else {
            return false
        }

        setIfChanged(\.proxyStatus, nextState.proxyStatus)
        setIfChanged(\.preferredPortText, nextState.preferredPortText)
        setIfChanged(\.autoStartProxy, nextState.autoStartProxy)
        setIfChanged(\.cloudflaredStatus, nextState.cloudflaredStatus)
        setIfChanged(\.cloudflaredTunnelMode, nextState.cloudflaredTunnelMode)
        setIfChanged(\.cloudflaredUseHTTP2, nextState.cloudflaredUseHTTP2)
        setIfChanged(\.publicAccessEnabled, nextState.publicAccessEnabled)
        setIfChanged(\.remoteServers, nextState.remoteServers)
        setIfChanged(\.remoteStatuses, nextState.remoteStatuses)
        setIfChanged(\.remoteDiscoveries, nextState.remoteDiscoveries)
        setIfChanged(\.remoteLogs, nextState.remoteLogs)
        if cloudflaredNamedInput.hostname != nextState.cloudflaredNamedHostname {
            cloudflaredNamedInput.hostname = nextState.cloudflaredNamedHostname
        }
        return true
    }

    func acceptedAppliedRemoteSnapshot(
        for commandID: String,
        acceptance: ((ProxyControlSnapshot) -> Bool)? = nil
    ) -> ProxyControlSnapshot? {
        guard let snapshot = lastAppliedRemoteSnapshot else { return nil }
        let isAccepted = acceptance?(snapshot) ?? (snapshot.lastHandledCommandID == commandID)
        return isAccepted ? snapshot : nil
    }

    func shouldRequestRemoteSnapshotRefresh() -> Bool {
        guard let lastAppliedRemoteSnapshotSyncedAt else {
            return true
        }

        let now = dateProvider.unixMillisecondsNow()
        if now - lastAppliedRemoteSnapshotSyncedAt >= ProxySyncPolicy.RemoteControl.snapshotFreshnessWindowMilliseconds {
            return true
        }

        guard !remoteServers.isEmpty else {
            return false
        }

        guard let lastAppliedRemoteStatusesSyncedAt else {
            return true
        }
        return now - lastAppliedRemoteStatusesSyncedAt >= ProxySyncPolicy.RemoteControl.remoteStatusesFreshnessWindowMilliseconds
    }

    func requestRemoteSnapshotRefresh(
        showErrors: Bool,
        showLoading: Bool = false
    ) async {
        guard let proxyControlRemoteCommandService else { return }

        if showLoading {
            loading = true
        }
        defer {
            if showLoading {
                loading = false
            }
        }

        let command = makeProxyControlCommand(
            sourceDeviceID: "ios-proxy-control",
            kind: .refreshStatus
        )

        do {
            try await proxyControlRemoteCommandService.enqueueCommand(command)
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

    private func refreshRemoteSnapshotAfterPush() async {
        if await refreshRemoteSnapshot(showErrors: false) {
            return
        }

        for attempt in 0..<28 {
            let delay: Duration = attempt < 8 ? .milliseconds(250) : .seconds(1)
            try? await Task.sleep(for: delay)
            if await refreshRemoteSnapshot(showErrors: false) {
                return
            }
        }
    }

    private var currentRemoteSnapshotPresentationState: ProxyRemoteSnapshotPresentationState {
        ProxyRemoteSnapshotPresentationState(
            proxyStatus: proxyStatus,
            preferredPortText: preferredPortText,
            autoStartProxy: autoStartProxy,
            cloudflaredStatus: cloudflaredStatus,
            cloudflaredTunnelMode: cloudflaredTunnelMode,
            cloudflaredNamedHostname: cloudflaredNamedInput.hostname,
            cloudflaredUseHTTP2: cloudflaredUseHTTP2,
            publicAccessEnabled: publicAccessEnabled,
            remoteServers: remoteServers,
            remoteStatuses: remoteStatuses,
            remoteDiscoveries: remoteDiscoveries,
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
}
