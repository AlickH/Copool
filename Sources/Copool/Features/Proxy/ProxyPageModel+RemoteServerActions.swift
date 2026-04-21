import Foundation

extension ProxyPageModel {
    func addRemoteServer() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .addRemoteServer,
                remoteServer: RemoteServerConfiguration.makeDraft(),
                successNotice: L10n.tr("settings.notice.remote_servers_saved")
            )
            return
        }
        do {
            try await applyLocalRemoteServerCommand(
                kind: .addRemoteServer,
                remoteServer: RemoteServerConfiguration.makeDraft()
            )
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.notice.remote_servers_saved"))
        } catch {
            showError(error)
        }
    }

    func saveRemoteServer(
        _ server: RemoteServerConfig,
        previousServerID: String? = nil
    ) async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .saveRemoteServer,
                remoteServer: RemoteServerConfiguration.normalize(server),
                previousRemoteServerID: previousServerID,
                successNotice: L10n.tr("settings.notice.remote_servers_saved")
            )
            return
        }
        let actionKey = previousServerID ?? server.id
        await withSaveRemoteAction(actionKey: actionKey, serverID: server.id) {
            do {
                try await applyLocalRemoteServerCommand(
                    kind: .saveRemoteServer,
                    remoteServer: RemoteServerConfiguration.normalize(server),
                    previousRemoteServerID: previousServerID
                )
                notice = NoticeMessage(style: .success, text: L10n.tr("settings.notice.remote_servers_saved"))
            } catch {
                showError(error)
            }
        }
    }

    func adoptDiscoveredRemoteServer(
        _ server: RemoteServerConfig,
        previousServerID: String
    ) async {
        let normalized = RemoteServerConfiguration.normalize(server)
        await saveRemoteServer(normalized, previousServerID: previousServerID)
        guard !hasErrorNotice else { return }
        await refreshRemote(server: normalized)
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
        await withRemoteAction(id, action: .removeLocal) {
            do {
                try await applyLocalRemoteServerCommand(
                    kind: .removeRemoteServer,
                    remoteServerID: id
                )
                notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_server_removed"))
            } catch {
                showError(error)
            }
        }
    }

    func discoverRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        let normalized = RemoteServerConfiguration.normalize(server)

        await withRemoteAction(normalized.id, action: .discover) {
            if usesRemoteMacControl {
                await performRemoteCommand(
                    kind: .discoverRemote,
                    remoteServer: normalized
                )
            } else {
                do {
                    try await applyLocalRemoteServerCommand(
                        kind: .discoverRemote,
                        remoteServer: normalized
                    )
                } catch {
                    showError(error)
                }
            }

            guard !hasErrorNotice else { return }
            notice = remoteDiscoveryNotice(for: normalized.id)
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
        remoteStatuses = await coordinator.remoteStatuses(for: remoteServers)
    }

    func refreshRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(kind: .refreshRemote, remoteServerID: server.id)
            return
        }
        await withRemoteAction(server.id, action: .refresh) {
            do {
                try await applyLocalRemoteServerCommand(
                    kind: .refreshRemote,
                    remoteServerID: server.id
                )
            } catch {
                showError(error)
            }
        }
    }

    func deployRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        setRemoteDeployFeedback(
            RemoteDeployFeedback(
                state: .deploying,
                message: L10n.tr("proxy.notice.remote_deploying_format", server.label)
            ),
            for: server.id
        )
        AuthFlowDebugLog.write(
            "RemoteDeploy.page.begin",
            "serverID=\(server.id) label=\(server.label) host=\(server.host) mode=\(usesRemoteMacControl ? "remote-control" : "local")"
        )
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .deployRemote,
                remoteServerID: server.id,
                successNotice: L10n.tr("proxy.notice.remote_deploy_done_format", server.label),
                pendingNotice: L10n.tr("proxy.notice.remote_deploying_format", server.label)
            )
            return
        }
        await withRemoteAction(server.id, action: .deploy) {
            notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.remote_deploying_format", server.label))
            do {
                try await applyLocalRemoteServerCommand(
                    kind: .deployRemote,
                    remoteServerID: server.id
                )
                setRemoteDeployFeedback(
                    RemoteDeployFeedback(
                        state: .success,
                        message: L10n.tr("proxy.notice.remote_deploy_done_format", server.label)
                    ),
                    for: server.id
                )
                AuthFlowDebugLog.write(
                    "RemoteDeploy.page.success",
                    "serverID=\(server.id) label=\(server.label)"
                )
                notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_deploy_done_format", server.label))
            } catch {
                setRemoteDeployFeedback(
                    RemoteDeployFeedback(
                        state: .failure,
                        message: error.localizedDescription
                    ),
                    for: server.id
                )
                AuthFlowDebugLog.write(
                    "RemoteDeploy.page.error",
                    "serverID=\(server.id) label=\(server.label) error=\(error.localizedDescription)"
                )
                showError(error)
            }
        }
    }

    func syncRemoteAccounts(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        await withRemoteAction(server.id, action: .syncAccounts) {
            if usesRemoteMacControl {
                await performRemoteCommand(
                    kind: .syncRemoteAccounts,
                    remoteServerID: server.id,
                    successNotice: L10n.tr("proxy.notice.remote_accounts_synced_format", server.label)
                )
                return
            }

            do {
                try await applyLocalRemoteServerCommand(
                    kind: .syncRemoteAccounts,
                    remoteServerID: server.id
                )
                notice = NoticeMessage(
                    style: .success,
                    text: L10n.tr("proxy.notice.remote_accounts_synced_format", server.label)
                )
            } catch {
                showError(error)
            }
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
        await withRemoteAction(server.id, action: .start) {
            do {
                try await applyLocalRemoteServerCommand(
                    kind: .startRemote,
                    remoteServerID: server.id
                )
                notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_started_format", server.label))
            } catch {
                showError(error)
            }
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
        await withRemoteAction(server.id, action: .stop) {
            do {
                try await applyLocalRemoteServerCommand(
                    kind: .stopRemote,
                    remoteServerID: server.id
                )
                notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.remote_stopped_format", server.label))
            } catch {
                showError(error)
            }
        }
    }

    func readRemoteLogs(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        await withRemoteAction(server.id, action: .logs) {
            if usesRemoteMacControl {
                await performRemoteLogCommand(serverID: server.id, logLines: 120)
                return
            }

            do {
                try await applyLocalRemoteServerCommand(
                    kind: .readRemoteLogs,
                    remoteServerID: server.id,
                    logLines: 120
                )
            } catch {
                showError(error)
            }
        }
    }

    func uninstallRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        await withRemoteAction(server.id, action: .uninstall) {
            if usesRemoteMacControl {
                await performRemoteCommand(
                    kind: .uninstallRemote,
                    remoteServerID: server.id,
                    removeRemoteDirectory: false,
                    successNotice: L10n.tr("proxy.notice.remote_uninstalled_format", server.label)
                )
                return
            }

            do {
                try await applyLocalRemoteServerCommand(
                    kind: .uninstallRemote,
                    remoteServerID: server.id,
                    removeRemoteDirectory: false
                )
                notice = NoticeMessage(
                    style: .success,
                    text: L10n.tr("proxy.notice.remote_uninstalled_format", server.label)
                )
            } catch {
                showError(error)
            }
        }
    }

    private func applyLocalRemoteServerCommand(
        kind: ProxyControlCommandKind,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        previousRemoteServerID: String? = nil,
        logLines: Int? = nil,
        removeRemoteDirectory: Bool? = nil
    ) async throws {
        let snapshot = try await performLocalCommand(
            kind: kind,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            previousRemoteServerID: previousRemoteServerID,
            logLines: logLines,
            removeRemoteDirectory: removeRemoteDirectory
        )
        applyRemoteSnapshot(snapshot)
    }

    private func withRemoteAction(
        _ key: String,
        action: RemoteServerAction,
        operation: () async -> Void
    ) async {
        remoteActions[key] = action
        defer { remoteActions.removeValue(forKey: key) }
        await operation()
    }

    private func withSaveRemoteAction(
        actionKey: String,
        serverID: String,
        operation: () async -> Void
    ) async {
        remoteActions[actionKey] = .save
        defer {
            remoteActions.removeValue(forKey: actionKey)
            if actionKey != serverID {
                remoteActions.removeValue(forKey: serverID)
            }
        }
        await operation()
    }

    private func showError(_ error: Error) {
        notice = NoticeMessage(style: .error, text: error.localizedDescription)
    }

    func dismissRemoteDeployFeedback(for serverID: String) {
        setRemoteDeployFeedback(nil, for: serverID)
    }

    func setRemoteDeployFeedback(_ feedback: RemoteDeployFeedback?, for serverID: String) {
        remoteDeployFeedbackDismissTasks[serverID]?.cancel()
        remoteDeployFeedbackDismissTasks.removeValue(forKey: serverID)

        guard let feedback else {
            remoteDeployFeedbacks.removeValue(forKey: serverID)
            return
        }

        remoteDeployFeedbacks[serverID] = feedback

        guard feedback.state == .success else { return }
        let dismissDelay = remoteDeploySuccessAutoDismissDelay

        remoteDeployFeedbackDismissTasks[serverID] = Task { [weak self] in
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.remoteDeployFeedbacks[serverID]?.state == .success {
                    self.remoteDeployFeedbacks.removeValue(forKey: serverID)
                }
                self.remoteDeployFeedbackDismissTasks.removeValue(forKey: serverID)
            }
        }
    }

    private func remoteDiscoveryNotice(for serverID: String) -> NoticeMessage {
        let count = remoteDiscoveries[serverID]?.count ?? 0
        if count == 0 {
            return NoticeMessage(style: .info, text: L10n.tr("proxy.notice.remote_discovery_empty"))
        }

        return NoticeMessage(
            style: .success,
            text: L10n.tr("proxy.notice.remote_discovery_found_format", String(count))
        )
    }

    private var hasErrorNotice: Bool {
        guard let notice else { return false }
        if case .error = notice.style {
            return true
        }
        return false
    }
}
