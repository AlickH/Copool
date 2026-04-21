import SwiftUI

struct RemoteServerCardView: View {
    let server: RemoteServerConfig
    let status: RemoteProxyStatus?
    let discoveredInstances: [DiscoveredRemoteProxyInstance]
    let logs: String?
    let deployFeedback: RemoteDeployFeedback?
    let activeAction: RemoteServerAction?
    let actions: RemoteServerCardActions

    @State private var draft: RemoteServerConfig
    @State private var isExpanded: Bool

    init(
        server: RemoteServerConfig,
        status: RemoteProxyStatus?,
        discoveredInstances: [DiscoveredRemoteProxyInstance],
        logs: String?,
        deployFeedback: RemoteDeployFeedback?,
        activeAction: RemoteServerAction?,
        actions: RemoteServerCardActions
    ) {
        self.server = server
        self.status = status
        self.discoveredInstances = discoveredInstances
        self.logs = logs
        self.deployFeedback = deployFeedback
        self.activeAction = activeAction
        self.actions = actions
        _draft = State(initialValue: server)
        _isExpanded = State(initialValue: RemoteServerConfiguration.isPlaceholderDraft(server))
    }

    var body: some View {
        let actionButtons = ProxyActionPresentation.remoteServerButtons(
            isRunning: status?.running == true,
            activeAction: activeAction
        )

        VStack(alignment: .leading, spacing: 10) {
            RemoteServerHeader(
                presentation: RemoteServerCardPresentation.header(
                    label: draft.label,
                    sshUser: draft.sshUser,
                    host: draft.host,
                    sshPort: draft.sshPort,
                    isExpanded: isExpanded,
                    status: status
                ),
                isExpanded: isExpanded,
                onToggle: toggleExpanded
            )

            if isExpanded {
                RemoteServerFieldGrid(draft: $draft)
                RemoteServerAuthSection(
                    draft: $draft,
                    onChooseIdentityFile: actions.onChooseIdentityFile
                )
                if let deployFeedback {
                    RemoteDeployFeedbackBanner(
                        feedback: deployFeedback,
                        onDismiss: actions.onDismissDeployFeedback
                    )
                }
                ProxyActionStrip(
                    buttons: actionButtons,
                    layout: .adaptiveGrid(
                        minimumColumnWidth: LayoutRules.proxyRemoteActionGridMinWidth
                    ),
                    onAction: handleRemoteAction
                )
                if let discoveryPresentation = RemoteServerCardPresentation.discovery(
                    instances: discoveredInstances
                ) {
                    RemoteServerDiscoverySection(
                        presentation: discoveryPresentation,
                        onUseInstance: useDiscoveredInstance
                    )
                }
                RemoteServerStatusGrid(
                    descriptors: RemoteServerCardPresentation.metrics(status: status)
                )
                RemoteServerDetailGrid(
                    descriptors: RemoteServerCardPresentation.details(status: status)
                )
                RemoteServerLogsSection(
                    presentation: RemoteServerCardPresentation.logs(logs: logs)
                )
                RemoteServerErrorSection(
                    message: status?.lastError ?? L10n.tr("common.none")
                )
                RemoteServerActionHelpSection(
                    descriptors: RemoteServerActionHelpPresentation.descriptors(
                        from: actionButtons
                    )
                )
            }
        }
        .padding(10)
        .cardSurface(cornerRadius: 10)
        .onChange(of: server) { _, newValue in
            draft = newValue
            if RemoteServerConfiguration.isPlaceholderDraft(draft) {
                isExpanded = true
            }
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }

    private func handleRemoteAction(_ intent: RemoteServerAction) async {
        switch intent {
        case .save:
            actions.onSave(server.id, draft)
        case .removeLocal:
            actions.onRemove(server.id)
        case .discover:
            actions.onDiscover(draft)
        case .syncAccounts:
            actions.onSyncAccounts()
        case .refresh:
            actions.onRefresh()
        case .deploy:
            actions.onDeploy()
        case .start:
            actions.onStart()
        case .stop:
            actions.onStop()
        case .logs:
            actions.onLogs()
        case .uninstall:
            actions.onUninstall()
        }
    }

    private func useDiscoveredInstance(_ instance: DiscoveredRemoteProxyInstance) {
        draft = RemoteServerConfiguration.adoptingDiscoveredInstance(instance, into: draft)
        actions.onUseDiscoveredInstance(server.id, draft)
    }
}

private struct RemoteDeployFeedbackBanner: View {
    let feedback: RemoteDeployFeedback
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if feedback.state == .deploying {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(accentColor)
            }

            Text(feedback.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if feedback.isDismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor.opacity(0.12))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 6)
        }
    }

    private var accentColor: Color {
        switch feedback.state {
        case .deploying:
            .blue
        case .success:
            .mint
        case .failure:
            .red
        }
    }

    private var iconName: String {
        switch feedback.state {
        case .deploying:
            ""
        case .success:
            "checkmark.circle.fill"
        case .failure:
            "exclamationmark.triangle.fill"
        }
    }
}
