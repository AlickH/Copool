import SwiftUI

struct NoticeBanner: View {
    let notice: NoticeMessage?

    var body: some View {
        if let notice {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: notice.style))
                    .foregroundStyle(accentColor(for: notice.style))
                Text(notice.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .noticeSurface(style: notice.style)
            .transition(.opacity.combined(with: .move(edge: transitionEdge)))
        }
    }

    private var transitionEdge: Edge {
        #if os(iOS)
        return .bottom
        #else
        return .top
        #endif
    }

    private func accentColor(for style: NoticeStyle) -> Color {
        switch style {
        case .success:
            return .mint
        case .info:
            return .blue
        case .error:
            return .red
        }
    }

    private func iconName(for style: NoticeStyle) -> String {
        switch style {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

private extension View {
    @ViewBuilder
    func noticeSurface(style: NoticeStyle) -> some View {
        #if os(iOS)
        self
            .background {
                RoundedRectangle(
                    cornerRadius: LayoutRules.iOSNoticeCornerRadius,
                    style: .continuous
                )
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: LayoutRules.iOSNoticeCornerRadius))
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(noticeAccentColor(style))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 7)
            }
        #else
        self
            .cardSurface(cornerRadius: 10)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(noticeAccentColor(style))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 7)
            }
        #endif
    }

    private func noticeAccentColor(_ style: NoticeStyle) -> Color {
        switch style {
        case .success:
            return .mint
        case .info:
            return .blue
        case .error:
            return .red
        }
    }
}
