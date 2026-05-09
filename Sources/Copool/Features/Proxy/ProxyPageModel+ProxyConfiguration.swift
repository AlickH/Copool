import Foundation

extension ProxyPageModel {
    func setPublicAccessEnabled(_ enabled: Bool) async {
        guard canManagePublicTunnel else {
            publicAccessEnabled = false
            return
        }
        guard publicAccessEnabled != enabled else { return }
        publicAccessEnabled = enabled
        if enabled {
            cloudflaredSectionExpanded = true
        }
        await syncCurrentProxyConfiguration()
    }

    func updatePreferredPortText(_ value: String) {
        guard preferredPortText != value else { return }
        preferredPortText = value
        scheduleProxyConfigurationSync()
    }

    func updateCloudflaredTunnelMode(_ mode: CloudflaredTunnelMode) {
        guard cloudflaredTunnelMode != mode else { return }
        cloudflaredTunnelMode = mode
        syncProxyConfigurationImmediately()
    }

    func updateCloudflaredUseHTTP2(_ value: Bool) {
        guard cloudflaredUseHTTP2 != value else { return }
        cloudflaredUseHTTP2 = value
        syncProxyConfigurationImmediately()
    }

    func updateCloudflaredNamedHostname(_ value: String) {
        guard cloudflaredNamedInput.hostname != value else { return }
        cloudflaredNamedInput.hostname = value
        scheduleProxyConfigurationSync()
    }

    var currentProxyConfiguration: ProxyConfiguration {
        ProxyConfiguration(
            preferredPortText: preferredPortText,
            cloudflared: CloudflaredConfiguration(
                enabled: publicAccessEnabled,
                tunnelMode: cloudflaredTunnelMode,
                useHTTP2: cloudflaredUseHTTP2,
                namedHostname: cloudflaredNamedInput.hostname
            )
        )
    }

    func applySettings(_ settings: AppSettings) {
        remoteServers = settings.remoteServers
        autoStartProxy = settings.autoStartApiProxy
        applyProxyConfiguration(settings.proxyConfiguration)
    }

    private func applyProxyConfiguration(_ configuration: ProxyConfiguration) {
        let normalized = configuration.normalized()
        preferredPortText = normalized.preferredPortText
        publicAccessEnabled = normalized.cloudflared.enabled
        cloudflaredTunnelMode = normalized.cloudflared.tunnelMode
        cloudflaredUseHTTP2 = normalized.cloudflared.useHTTP2
        cloudflaredNamedInput.hostname = normalized.cloudflared.namedHostname
        lastSyncedProxyConfiguration = normalized
    }

    private func scheduleProxyConfigurationSync() {
        pendingConfigurationSyncTask?.cancel()
        pendingConfigurationSyncTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: ProxySyncPolicy.Configuration.debounceInterval)
            guard !Task.isCancelled else { return }
            await self.syncCurrentProxyConfiguration()
        }
    }

    private func syncProxyConfigurationImmediately() {
        pendingConfigurationSyncTask?.cancel()
        pendingConfigurationSyncTask = Task { [weak self] in
            guard let self else { return }
            await self.syncCurrentProxyConfiguration()
        }
    }

    private func syncCurrentProxyConfiguration() async {
        let configuration = currentProxyConfiguration
        guard configuration != lastSyncedProxyConfiguration else { return }

        if usesRemoteMacControl {
            await syncRemoteProxyConfiguration(configuration)
        } else {
            await syncLocalProxyConfiguration(configuration)
        }
    }

    private func syncRemoteProxyConfiguration(_ configuration: ProxyConfiguration) async {
        guard let proxyControlRemoteCommandService else { return }

        let command = makeProxyControlCommand(
            sourceDeviceID: "ios-proxy-control",
            kind: .updateProxyConfiguration,
            proxyConfiguration: configuration
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
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func syncLocalProxyConfiguration(_ configuration: ProxyConfiguration) async {
        do {
            let snapshot = try await performLocalCommand(
                kind: .updateProxyConfiguration,
                proxyConfiguration: configuration
            )
            applyRemoteSnapshot(snapshot)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }
}
