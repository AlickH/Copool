import Foundation

extension ProxyPageModel {
    func performRemoteCommand(
        kind: ProxyControlCommandKind,
        preferredProxyPort: Int? = nil,
        autoStartProxy: Bool? = nil,
        cloudflaredInput: StartCloudflaredTunnelInput? = nil,
        proxyConfiguration: ProxyConfiguration? = nil,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        previousRemoteServerID: String? = nil,
        logLines: Int? = nil,
        removeRemoteDirectory: Bool? = nil,
        successNotice: String? = nil,
        pendingNotice: String? = nil
    ) async {
        guard let proxyControlRemoteCommandService else { return }

        loading = true
        defer { loading = false }

        let command = makeProxyControlCommand(
            sourceDeviceID: "ios-proxy-control",
            kind: kind,
            preferredProxyPort: preferredProxyPort,
            autoStartProxy: autoStartProxy,
            cloudflaredInput: cloudflaredInput,
            proxyConfiguration: proxyConfiguration,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            previousRemoteServerID: previousRemoteServerID,
            logLines: logLines,
            removeRemoteDirectory: removeRemoteDirectory
        )

        do {
            try await proxyControlRemoteCommandService.enqueueCommand(command)
            lastRemoteCommandID = command.id
            if kind == .deployRemote {
                AuthFlowDebugLog.write(
                    "RemoteDeploy.command.enqueued",
                    "commandID=\(command.id) serverID=\(remoteServerID ?? remoteServer?.id ?? "nil") source=\(command.sourceDeviceID)"
                )
            }

            if let pendingNotice {
                notice = NoticeMessage(style: .info, text: pendingNotice)
            }

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(command.id) {
                applyRemoteSnapshot(acknowledgedSnapshot)
                if let error = acknowledgedSnapshot.lastCommandError,
                   acknowledgedSnapshot.lastHandledCommandID == command.id,
                   !error.isEmpty {
                    if kind == .deployRemote, let serverID = remoteServerID ?? remoteServer?.id {
                        setRemoteDeployFeedback(
                            RemoteDeployFeedback(state: .failure, message: error),
                            for: serverID
                        )
                    }
                    if kind == .deployRemote {
                        AuthFlowDebugLog.write(
                            "RemoteDeploy.command.ackError",
                            "commandID=\(command.id) serverID=\(remoteServerID ?? remoteServer?.id ?? "nil") error=\(error)"
                        )
                    }
                    notice = NoticeMessage(style: .error, text: error)
                } else if let successNotice {
                    if kind == .deployRemote, let serverID = remoteServerID ?? remoteServer?.id {
                        setRemoteDeployFeedback(
                            RemoteDeployFeedback(state: .success, message: successNotice),
                            for: serverID
                        )
                    }
                    if kind == .deployRemote {
                        AuthFlowDebugLog.write(
                            "RemoteDeploy.command.ackSuccess",
                            "commandID=\(command.id) serverID=\(remoteServerID ?? remoteServer?.id ?? "nil")"
                        )
                    }
                    notice = NoticeMessage(style: .success, text: successNotice)
                }
            } else if let successNotice {
                if kind == .deployRemote {
                    AuthFlowDebugLog.write(
                        "RemoteDeploy.command.noAck",
                        "commandID=\(command.id) serverID=\(remoteServerID ?? remoteServer?.id ?? "nil")"
                    )
                }
                if kind == .deployRemote, let serverID = remoteServerID ?? remoteServer?.id {
                    setRemoteDeployFeedback(
                        RemoteDeployFeedback(state: .success, message: successNotice),
                        for: serverID
                    )
                }
                notice = NoticeMessage(style: .info, text: successNotice)
            }
        } catch {
            if kind == .deployRemote, let serverID = remoteServerID ?? remoteServer?.id {
                setRemoteDeployFeedback(
                    RemoteDeployFeedback(state: .failure, message: error.localizedDescription),
                    for: serverID
                )
            }
            if kind == .deployRemote {
                AuthFlowDebugLog.write(
                    "RemoteDeploy.command.enqueueError",
                    "serverID=\(remoteServerID ?? remoteServer?.id ?? "nil") error=\(error.localizedDescription)"
                )
            }
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func performRemoteLogCommand(serverID: String, logLines: Int) async {
        guard let proxyControlRemoteCommandService else { return }

        let previousLogs = remoteLogs[serverID]
        let command = makeProxyControlCommand(
            sourceDeviceID: "ios-proxy-control",
            kind: .readRemoteLogs,
            remoteServerID: serverID,
            logLines: logLines
        )

        do {
            try await proxyControlRemoteCommandService.enqueueCommand(command)
            lastRemoteCommandID = command.id

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(
                command.id,
                pollLimit: ProxySyncPolicy.RemoteControl.logAckPollLimit,
                pollInterval: ProxySyncPolicy.RemoteControl.logAckPollInterval,
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

    func waitForRemoteCommandAck(
        _ commandID: String,
        pollLimit: Int = ProxySyncPolicy.RemoteControl.commandAckPollLimit,
        pollInterval: Duration = ProxySyncPolicy.RemoteControl.commandAckPollInterval,
        acceptance: ((ProxyControlSnapshot) -> Bool)? = nil
    ) async throws -> ProxyControlSnapshot? {
        guard let proxyControlRemoteCommandService else { return nil }

        for _ in 0..<pollLimit {
            if let acknowledgedSnapshot = acceptedAppliedRemoteSnapshot(
                for: commandID,
                acceptance: acceptance
            ) {
                return acknowledgedSnapshot
            }

            if let snapshot = try await proxyControlRemoteCommandService.pullRemoteSnapshot() {
                let isAccepted = acceptance?(snapshot) ?? (snapshot.lastHandledCommandID == commandID)
                applyRemoteSnapshot(snapshot)
                if isAccepted {
                    return snapshot
                }
            }
            try? await Task.sleep(for: pollInterval)
        }

        return nil
    }

    func performLocalCommand(
        kind: ProxyControlCommandKind,
        preferredProxyPort: Int? = nil,
        autoStartProxy: Bool? = nil,
        cloudflaredInput: StartCloudflaredTunnelInput? = nil,
        proxyConfiguration: ProxyConfiguration? = nil,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        previousRemoteServerID: String? = nil,
        logLines: Int? = nil,
        removeRemoteDirectory: Bool? = nil
    ) async throws -> ProxyControlSnapshot {
        guard let localProxyCommandService else {
            throw AppError.invalidData("Local proxy command service is unavailable.")
        }

        let command = makeProxyControlCommand(
            sourceDeviceID: "macos-proxy-control",
            kind: kind,
            preferredProxyPort: preferredProxyPort,
            autoStartProxy: autoStartProxy,
            cloudflaredInput: cloudflaredInput,
            proxyConfiguration: proxyConfiguration,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            previousRemoteServerID: previousRemoteServerID,
            logLines: logLines,
            removeRemoteDirectory: removeRemoteDirectory
        )
        return try await localProxyCommandService.performLocalCommand(command)
    }

    func makeProxyControlCommand(
        sourceDeviceID: String,
        kind: ProxyControlCommandKind,
        preferredProxyPort: Int? = nil,
        autoStartProxy: Bool? = nil,
        cloudflaredInput: StartCloudflaredTunnelInput? = nil,
        proxyConfiguration: ProxyConfiguration? = nil,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        previousRemoteServerID: String? = nil,
        logLines: Int? = nil,
        removeRemoteDirectory: Bool? = nil
    ) -> ProxyControlCommand {
        ProxyControlCommand(
            id: UUID().uuidString,
            createdAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: sourceDeviceID,
            kind: kind,
            preferredProxyPort: preferredProxyPort,
            autoStartProxy: autoStartProxy,
            cloudflaredInput: cloudflaredInput,
            proxyConfiguration: proxyConfiguration,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            previousRemoteServerID: previousRemoteServerID,
            logLines: logLines,
            removeRemoteDirectory: removeRemoteDirectory
        )
    }
}
