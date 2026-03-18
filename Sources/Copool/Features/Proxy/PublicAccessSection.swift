import SwiftUI

struct PublicAccessSection: View {
    @ObservedObject var model: ProxyPageModel
    let onCopy: (String?) -> Void
    @State private var modeCardHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.cloudflaredExpanded {
                expandedContent
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: LayoutRules.cardRadius)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L10n.tr("proxy.section.public_access"))
                    .font(.headline)

                Spacer(minLength: 0)

                CollapseChevronButton(isExpanded: model.cloudflaredExpanded) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.cloudflaredSectionExpanded.toggle()
                    }
                }
            }

            HStack(spacing: 10) {
                Text(L10n.tr("proxy.toggle.enable_public_access"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                PublicAccessSwitchPill(
                    isOn: Binding(
                        get: { model.publicAccessEnabled },
                        set: { value in
                            model.publicAccessEnabled = value
                            Task { await model.setPublicAccessEnabled(value) }
                        }
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !model.proxyStatus.running {
            callout(
                title: L10n.tr("proxy.public.callout.start_local_first_title"),
                message: L10n.tr("proxy.public.callout.start_local_first_message")
            )
        }

        if !model.cloudflaredStatus.installed {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("proxy.public.not_installed_label"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("proxy.public.install_title"))
                        .font(.headline)
                    Text(L10n.tr("proxy.public.install_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("proxy.public.install_action") {
                    Task { await model.installCloudflared() }
                }
                .liquidGlassActionButtonStyle(prominent: true)
                .disabled(model.loading)
            }
            .padding(12)
            .cardSurface(cornerRadius: 12)
        } else {
            modeGrid

            if model.cloudflaredTunnelMode == .quick {
                callout(
                    title: L10n.tr("proxy.public.quick_note_title"),
                    message: L10n.tr("proxy.public.quick_note_message")
                )
            }

            if model.cloudflaredTunnelMode == .named {
                namedTunnelForm
            }

            toolbar
            statusGrid
        }
    }

    private var modeGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10),
                GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10)
            ],
            spacing: 10
        ) {
            PublicAccessModeCard(
                kicker: L10n.tr("proxy.public.mode.quick_kicker"),
                title: L10n.tr("proxy.public.mode.quick_title"),
                message: L10n.tr("proxy.public.mode.quick_message"),
                selected: model.cloudflaredTunnelMode == .quick
            ) {
                model.cloudflaredTunnelMode = .quick
            }
            .frame(height: modeCardHeight > 0 ? modeCardHeight : nil, alignment: .top)
            .disabled(!model.canEditCloudflaredInput)

            PublicAccessModeCard(
                kicker: L10n.tr("proxy.public.mode.named_kicker"),
                title: L10n.tr("proxy.public.mode.named_title"),
                message: L10n.tr("proxy.public.mode.named_message"),
                selected: model.cloudflaredTunnelMode == .named
            ) {
                model.cloudflaredTunnelMode = .named
            }
            .frame(height: modeCardHeight > 0 ? modeCardHeight : nil, alignment: .top)
            .disabled(!model.canEditCloudflaredInput)
        }
        .onPreferenceChange(PublicAccessModeCardHeightKey.self) { nextHeight in
            guard nextHeight > 0, abs(modeCardHeight - nextHeight) > 0.5 else { return }
            modeCardHeight = nextHeight
        }
    }

    private var namedTunnelForm: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: LayoutRules.proxyPublicFieldMinWidth), spacing: 10)],
            spacing: 10
        ) {
            labeledField(
                title: L10n.tr("proxy.public.field.api_token"),
                content: {
                    SecureField(
                        L10n.tr("proxy.public.field.api_token_placeholder"),
                        text: Binding(
                            get: { model.cloudflaredNamedInput.apiToken },
                            set: { model.cloudflaredNamedInput.apiToken = $0 }
                        )
                    )
                    .frostedRoundedInput()
                    .disabled(!model.canEditCloudflaredInput)
                }
            )

            labeledField(
                title: L10n.tr("proxy.public.field.account_id"),
                content: {
                    TextField(
                        L10n.tr("proxy.public.field.account_id_placeholder"),
                        text: Binding(
                            get: { model.cloudflaredNamedInput.accountID },
                            set: { model.cloudflaredNamedInput.accountID = $0 }
                        )
                    )
                    .frostedRoundedInput()
                    .disabled(!model.canEditCloudflaredInput)
                }
            )

            labeledField(
                title: L10n.tr("proxy.public.field.zone_id"),
                content: {
                    TextField(
                        L10n.tr("proxy.public.field.zone_id_placeholder"),
                        text: Binding(
                            get: { model.cloudflaredNamedInput.zoneID },
                            set: { model.cloudflaredNamedInput.zoneID = $0 }
                        )
                    )
                    .frostedRoundedInput()
                    .disabled(!model.canEditCloudflaredInput)
                }
            )

            labeledField(
                title: L10n.tr("proxy.public.field.hostname"),
                content: {
                    TextField(
                        L10n.tr("proxy.public.field.hostname_placeholder"),
                        text: Binding(
                            get: { model.cloudflaredNamedInput.hostname },
                            set: { model.cloudflaredNamedInput.hostname = $0 }
                        )
                    )
                    .frostedRoundedInput()
                    .disabled(!model.canEditCloudflaredInput)
                }
            )
        }
    }

    private var toolbar: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L10n.tr("proxy.toggle.use_http2"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                PublicAccessSwitchPill(
                    isOn: Binding(
                        get: { model.cloudflaredUseHTTP2 },
                        set: { model.cloudflaredUseHTTP2 = $0 }
                    )
                )
                .disabled(!model.canEditCloudflaredInput)
            }

            HStack(spacing: 8) {
                Button("proxy.public.refresh_status") {
                    Task { await model.refreshCloudflared() }
                }
                .liquidGlassActionButtonStyle()
                .disabled(model.loading)

                if model.cloudflaredStatus.running {
                    Button("proxy.public.stop_action", role: .destructive) {
                        Task { await model.stopCloudflared() }
                    }
                    .liquidGlassActionButtonStyle(prominent: true, tint: .red)
                    .disabled(model.loading)
                } else {
                    Button("proxy.public.start_action") {
                        Task { await model.startCloudflared() }
                    }
                    .liquidGlassActionButtonStyle(prominent: true)
                    .disabled(!model.canStartCloudflared)
                }
            }
        }
        #else
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(L10n.tr("proxy.toggle.use_http2"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                PublicAccessSwitchPill(
                    isOn: Binding(
                        get: { model.cloudflaredUseHTTP2 },
                        set: { model.cloudflaredUseHTTP2 = $0 }
                    )
                )
                .disabled(!model.canEditCloudflaredInput)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button("proxy.public.refresh_status") {
                    Task { await model.refreshCloudflared() }
                }
                .liquidGlassActionButtonStyle()
                .disabled(model.loading)

                if model.cloudflaredStatus.running {
                    Button("proxy.public.stop_action", role: .destructive) {
                        Task { await model.stopCloudflared() }
                    }
                    .liquidGlassActionButtonStyle(prominent: true, tint: .red)
                    .disabled(model.loading)
                } else {
                    Button("proxy.public.start_action") {
                        Task { await model.startCloudflared() }
                    }
                    .liquidGlassActionButtonStyle(prominent: true)
                    .disabled(!model.canStartCloudflared)
                }
            }
        }
        #endif
    }

    private var statusGrid: some View {
        LazyVStack(spacing: 10) {
            PublicAccessInfoCard(
                title: L10n.tr("proxy.public.status_title"),
                headline: model.cloudflaredStatus.running ? L10n.tr("proxy.status.running") : L10n.tr("proxy.status.stopped"),
                message: model.cloudflaredStatus.running
                    ? L10n.tr("proxy.public.status_running_message")
                    : L10n.tr("proxy.public.status_stopped_message")
            )

            PublicAccessInfoCard(
                title: L10n.tr("proxy.public.url_title"),
                headline: model.cloudflaredStatus.publicURL ?? L10n.tr("proxy.value.generated_after_start"),
                message: "",
                canCopy: model.cloudflaredStatus.publicURL != nil
            ) {
                onCopy(model.cloudflaredStatus.publicURL)
            }

            PublicAccessInfoCard(
                title: L10n.tr("proxy.public.install_path_title"),
                headline: model.cloudflaredStatus.binaryPath ?? L10n.tr("proxy.public.not_detected"),
                message: ""
            )

            PublicAccessInfoCard(
                title: L10n.tr("proxy.detail.last_error"),
                headline: model.cloudflaredStatus.lastError ?? L10n.tr("common.none"),
                message: ""
            )
        }
    }

    private func callout(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    private func labeledField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct PublicAccessSwitchPill: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Text(isOn ? L10n.tr("proxy.switch.on") : L10n.tr("proxy.switch.off"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frostedCapsuleSurface(prominent: isOn, tint: isOn ? .accentColor : nil)
    }
}

private struct PublicAccessModeCard: View {
    let kicker: String
    let title: String
    let message: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(kicker)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .glassSelectableCard(selected: selected, cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: PublicAccessModeCardHeightKey.self, value: proxy.size.height)
            }
        }
    }
}

private struct PublicAccessModeCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PublicAccessInfoCard: View {
    let title: String
    let headline: String
    let message: String
    var canCopy: Bool = false
    var onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let onCopy {
                    Button("common.copy", action: onCopy)
                        .liquidGlassActionButtonStyle()
                        .disabled(!canCopy)
                }
            }
            Text(headline)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }
}
