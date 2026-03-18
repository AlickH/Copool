import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct SectionCard<Content: View, HeaderTrailing: View>: View {
    let title: String
    @ViewBuilder let headerTrailing: HeaderTrailing
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) where HeaderTrailing == EmptyView {
        self.title = title
        self.headerTrailing = EmptyView()
        self.content = content()
    }

    init(
        title: String,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
                headerTrailing
            }
            content
        }
        .padding(16)
        .cardSurface(cornerRadius: LayoutRules.cardRadius)
    }
}

struct CollapseChevronButton: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        }
        .liquidGlassActionButtonStyle(density: .compact)
    }
}

struct CloseGlassButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .accessibilityLabel(L10n.tr("common.close"))
        .liquidGlassActionButtonStyle(density: .compact)
    }
}

struct LanguageMenuButton<Label: View>: View {
    let currentLocale: AppLocale
    let onSelectLocale: (AppLocale) -> Void
    @ViewBuilder let label: Label

    init(
        currentLocale: AppLocale,
        onSelectLocale: @escaping (AppLocale) -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.currentLocale = currentLocale
        self.onSelectLocale = onSelectLocale
        self.label = label()
    }

    var body: some View {
        Menu {
            ForEach(AppLocale.allCases) { locale in
                Button {
                    onSelectLocale(locale)
                } label: {
                    HStack {
                        Text(L10n.tr(locale.displayNameKey))
                        if locale == currentLocale {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            label
        }
        .accessibilityLabel(Text("settings.language"))
    }
}

struct ToolbarIconLabel: View {
    let systemImage: String
    var isSpinning = false
    var opticalScale = CGFloat(1)

    var body: some View {
        baseIcon
            .modifier(ToolbarIconSpinModifier(isSpinning: isSpinning))
    }

    private var baseIcon: some View {
        Image(systemName: systemImage)
            .font(.system(size: LayoutRules.toolbarIconPointSize, weight: .semibold))
            .foregroundStyle(.primary)
            .scaleEffect(opticalScale)
    }
}

private struct ToolbarIconSpinModifier: ViewModifier {
    let isSpinning: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .symbolEffect(.rotate.byLayer, options: .repeating, isActive: isSpinning)
        } else {
            content
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(
                    isSpinning
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.2),
                    value: isSpinning
                )
        }
    }
}

struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background { backgroundSurface }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(separatorColor, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var backgroundSurface: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if let tint {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(tint.opacity(0.28)), in: .rect(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                if let tint {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint)
                }
            }
        }
    }

    private var separatorColor: Color {
        #if canImport(AppKit)
        Color(nsColor: .separatorColor).opacity(0.9)
        #else
        Color.secondary.opacity(0.22)
        #endif
    }
}

private enum FrostedChromeTokens {
    static var separatorColor: Color {
        #if canImport(AppKit)
        Color(nsColor: .separatorColor)
        #else
        Color.secondary.opacity(0.2)
        #endif
    }

    static func tintedGlass(prominent: Bool, tint: Color?) -> Color {
        if let tint {
            return tint.opacity(prominent ? 0.22 : 0.14)
        }
        return Color.white.opacity(prominent ? 0.06 : 0.03)
    }

    static func fallbackFill(prominent: Bool, tint: Color?) -> AnyShapeStyle {
        if let tint, prominent {
            return AnyShapeStyle(tint.opacity(0.14))
        }
        return AnyShapeStyle(prominent ? .regularMaterial : .ultraThinMaterial)
    }
}

private struct FrostedCapsuleSurfaceModifier: ViewModifier {
    let prominent: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background { backgroundSurface }
            .overlay {
                Capsule()
                    .stroke(FrostedChromeTokens.separatorColor.opacity(prominent ? 0.85 : 1), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var backgroundSurface: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(
                    .regular.tint(FrostedChromeTokens.tintedGlass(prominent: prominent, tint: tint)),
                    in: .capsule
                )
        } else {
            Capsule()
                .fill(FrostedChromeTokens.fallbackFill(prominent: prominent, tint: tint))
        }
    }
}

private struct FrostedRoundedSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let prominent: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background { backgroundSurface }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(FrostedChromeTokens.separatorColor.opacity(prominent ? 0.85 : 1), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var backgroundSurface: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(FrostedChromeTokens.tintedGlass(prominent: prominent, tint: tint)),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(FrostedChromeTokens.fallbackFill(prominent: prominent, tint: tint))
        }
    }
}

private struct FrostedRoundedInputModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frostedRoundedSurface(cornerRadius: cornerRadius)
    }
}

private struct GlassSelectableCardModifier: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        content
            .cardSurface(
                cornerRadius: cornerRadius,
                tint: selected ? tint.opacity(0.16) : nil
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        selected
                            ? tint.opacity(0.44)
                            : FrostedChromeTokens.separatorColor.opacity(0.7),
                        lineWidth: 1
                    )
            }
    }
}

struct LiquidProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let metrics = LiquidProgressMetrics(
                progress: progress,
                totalWidth: geometry.size.width
            )

            ZStack(alignment: .leading) {
                LiquidProgressTrack()

                if metrics.visibleFillWidth > 0 {
                    LiquidProgressFill(tint: tint)
                        .frame(width: metrics.visibleFillWidth, height: metrics.grooveHeight)
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, metrics.horizontalInset)
                        .padding(.vertical, metrics.verticalInset)
                }
            }
        }
        .frame(height: LayoutRules.liquidProgressHeight)
    }
}

struct LiquidProgressRing: View {
    let progress: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        let metrics = progressMetrics

        ZStack {
            LiquidProgressRingTrack(metrics: metrics)

            if metrics.trimEnd > 0 {
                LiquidProgressRingFill(
                    progress: metrics.trimEnd,
                    tint: tint,
                    metrics: metrics
                )
            }
        }
    }

    private var progressMetrics: LiquidRingMetrics {
        LiquidRingMetrics(progress: progress, lineWidth: lineWidth)
    }
}

struct LiquidProgressMetrics {
    let progress: Double
    let totalWidth: CGFloat

    private var clampedProgress: Double {
        max(0, min(1, progress))
    }

    var horizontalInset: CGFloat {
        1
    }

    var verticalInset: CGFloat {
        1
    }

    var grooveHeight: CGFloat {
        max(4, LayoutRules.liquidProgressHeight - verticalInset * 2)
    }

    var rawFillWidth: CGFloat {
        let availableWidth = max(0, totalWidth - horizontalInset * 2)
        return availableWidth * clampedProgress
    }

    var minimumVisibleFillWidth: CGFloat {
        grooveHeight
    }

    var visibleFillWidth: CGFloat {
        guard rawFillWidth > 0 else {
            return 0
        }

        return max(rawFillWidth, minimumVisibleFillWidth)
    }
}

private struct LiquidRingMetrics {
    let progress: Double
    let lineWidth: CGFloat

    var trimEnd: Double {
        max(0, min(1, progress))
    }

    var isFullCircle: Bool {
        trimEnd >= 0.999
    }

    var rotationDegrees: Double {
        -102
    }

    var trackInset: CGFloat {
        max(0.05, lineWidth * 0.01)
    }

    var trackWidth: CGFloat {
        lineWidth * 1.22
    }

    var grooveCenterInset: CGFloat {
        trackInset + trackWidth * 0.5
    }

    var fillInset: CGFloat {
        grooveCenterInset
    }

    var fillWidth: CGFloat {
        max(6.2, trackWidth * 0.82)
    }

    var highlightWidth: CGFloat {
        max(1.8, fillWidth * 0.38)
    }

    var dotThreshold: Double {
        0.032
    }

    var dotDiameter: CGFloat {
        max(5.8, fillWidth * 1.04)
    }
}

private struct LiquidGroovePalette {
    let glassTint: Color
    let coreTop: Color
    let coreMid: Color
    let coreBottom: Color
    let topEdge: Color
    let bottomEdge: Color
    let centerGlow: Color
    let innerEdge: Color
    let ringOuterHighlight: Color
    let ringInnerHighlight: Color
    let ringShadow: Color
    let ringShadowSoft: Color
    let ringCoreGlow: Color

    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            glassTint = Color.white.opacity(0.08)
            coreTop = Color.white.opacity(0.035)
            coreMid = Color.black.opacity(0.34)
            coreBottom = Color.white.opacity(0.018)
            topEdge = Color.white.opacity(0.14)
            bottomEdge = Color.black.opacity(0.34)
            centerGlow = Color.white.opacity(0.055)
            innerEdge = Color.black.opacity(0.24)
            ringOuterHighlight = Color.white.opacity(0.14)
            ringInnerHighlight = Color.white.opacity(0.08)
            ringShadow = Color.black.opacity(0.28)
            ringShadowSoft = Color.black.opacity(0.12)
            ringCoreGlow = Color.white.opacity(0.018)
        default:
            glassTint = Color.white.opacity(0.06)
            coreTop = Color.black.opacity(0.15)
            coreMid = Color.black.opacity(0.05)
            coreBottom = Color.white.opacity(0.05)
            topEdge = Color.white.opacity(0.26)
            bottomEdge = Color.black.opacity(0.1)
            centerGlow = Color.white.opacity(0.08)
            innerEdge = Color.black.opacity(0.08)
            ringOuterHighlight = Color.white.opacity(0.3)
            ringInnerHighlight = Color.white.opacity(0.14)
            ringShadow = Color.black.opacity(0.1)
            ringShadowSoft = Color.black.opacity(0.05)
            ringCoreGlow = Color.white.opacity(0.024)
        }
    }

    var coreGradient: LinearGradient {
        LinearGradient(
            colors: [coreTop, coreMid, coreBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct LiquidProgressTrack: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = LiquidGroovePalette(colorScheme: colorScheme)

        ZStack {
            if #available(iOS 26.0, macOS 26.0, *) {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(palette.glassTint), in: .capsule)
            } else {
                Capsule()
                    .fill(palette.coreGradient)
            }

            Capsule()
                .fill(palette.coreGradient)
                .padding(1)
        }
        .overlay {
            Capsule()
                .stroke(palette.topEdge, lineWidth: 1)
                .blur(radius: 0.35)
                .mask(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.black, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
        .overlay {
            Capsule()
                .stroke(palette.bottomEdge, lineWidth: 1)
                .blur(radius: 0.45)
                .mask(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.clear, Color.black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
        .overlay {
            Capsule()
                .fill(palette.centerGlow)
                .padding(.horizontal, 3)
                .padding(.vertical, 2.5)
                .blur(radius: 2.5)
                .mask(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.clear, Color.black, Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .opacity(0.6)
        }
    }
}

private struct LiquidProgressFill: View {
    let tint: Color

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(0.34), location: 0),
                        .init(color: tint.opacity(0.92), location: 0.18),
                        .init(color: tint.opacity(1), location: 0.46),
                        .init(color: tint.opacity(0.84), location: 0.76),
                        .init(color: tint.opacity(0.58), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(0.26),
                                tint.opacity(0.1),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.horizontal, 2.5)
                    .padding(.top, 1)
                    .padding(.bottom, 4)
                    .blur(radius: 0.45)
            }
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.42), location: 0),
                                .init(color: Color.white.opacity(0.22), location: 0.22),
                                .init(color: Color.white.opacity(0.07), location: 0.52),
                                .init(color: Color.clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.horizontal, 3)
                    .padding(.top, 1)
                    .padding(.bottom, 4.5)
                    .blur(radius: 0.55)
                    .blendMode(.screen)
            }
            .overlay {
                LiquidProgressSurfaceHighlights(tint: tint)
            }
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.05),
                                Color.black.opacity(0.1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(1)
                    .opacity(0.62)
            }
            .overlay {
                LiquidProgressBevel(tint: tint)
            }
            .shadow(color: tint.opacity(0.14), radius: 2.4, y: 0.9)
    }
}

private struct LiquidProgressSurfaceHighlights: View {
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = geometry.size.width
            let endGlowWidth = max(height * 1.05, min(width * 0.24, height * 1.85))

            ZStack {
                endHighlight
                    .frame(width: endGlowWidth, height: height)
                    .position(x: endGlowWidth * 0.5, y: height * 0.5)

                endHighlight
                    .scaleEffect(x: -1, y: 1)
                    .frame(width: endGlowWidth, height: height)
                    .position(x: width - endGlowWidth * 0.5, y: height * 0.5)

                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.clear, location: 0),
                                .init(color: Color.white.opacity(0.08), location: 0.18),
                                .init(color: Color.white.opacity(0.15), location: 0.5),
                                .init(color: Color.white.opacity(0.08), location: 0.82),
                                .init(color: Color.clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.horizontal, endGlowWidth * 0.55)
                    .padding(.top, 1)
                    .padding(.bottom, height * 0.42)
                    .frame(width: width, height: height)
                    .blendMode(.screen)
                    .mask(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white, Color.white.opacity(0.7), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .compositingGroup()
        }
        .allowsHitTesting(false)
    }

    private var endHighlight: some View {
        ZStack {
            Capsule()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.26), location: 0),
                            .init(color: tint.opacity(0.34), location: 0),
                            .init(color: Color.white.opacity(0.12), location: 0.14),
                            .init(color: tint.opacity(0.18), location: 0.22),
                            .init(color: tint.opacity(0.06), location: 0.5),
                            .init(color: Color.clear, location: 1)
                        ],
                        center: UnitPoint(x: 0.16, y: 0.3),
                        startRadius: 0,
                        endRadius: 18
                    )
                )
                .blendMode(.screen)

            Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(0.14),
                                tint.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                    )
                )
                .padding(.vertical, 1)
                .blendMode(.screen)
        }
        .mask(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color.white.opacity(0.78),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .blur(radius: 0.06)
    }
}

private struct LiquidProgressBevel: View {
    let tint: Color

    var body: some View {
        ZStack {
            Capsule()
                .stroke(tint.opacity(0.18), lineWidth: 1)
                .blur(radius: 0.4)
                .mask(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.black, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )

            Capsule()
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                .blur(radius: 0.6)
                .mask(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.clear, Color.black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
        .padding(0.5)
    }
}

private struct LiquidProgressRingTrack: View {
    @Environment(\.colorScheme) private var colorScheme

    let metrics: LiquidRingMetrics

    var body: some View {
        GeometryReader { geometry in
            let palette = LiquidGroovePalette(colorScheme: colorScheme)

            ZStack {
                if #available(iOS 26.0, macOS 26.0, *) {
                    Circle()
                        .fill(.clear)
                        .glassEffect(.regular.tint(palette.glassTint), in: .circle)
                        .mask {
                            Circle()
                                .inset(by: metrics.trackInset)
                                .strokeBorder(.white, lineWidth: metrics.trackWidth)
                        }
                } else {
                    Circle()
                        .inset(by: metrics.trackInset)
                        .strokeBorder(palette.glassTint, lineWidth: metrics.trackWidth)
                }

                Circle()
                    .inset(by: metrics.trackInset)
                    .strokeBorder(palette.coreGradient, lineWidth: metrics.trackWidth)

                Circle()
                    .inset(by: metrics.trackInset)
                    .strokeBorder(palette.topEdge, lineWidth: 1)
                    .blur(radius: 0.35)
                    .mask {
                        ringMask(
                            LinearGradient(
                                colors: [Color.black, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }

                Circle()
                    .inset(by: metrics.trackInset)
                    .strokeBorder(palette.bottomEdge, lineWidth: 1)
                    .blur(radius: 0.45)
                    .mask {
                        ringMask(
                            LinearGradient(
                                colors: [Color.clear, Color.black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }

                Circle()
                    .inset(by: metrics.trackInset)
                    .strokeBorder(palette.centerGlow, lineWidth: max(2.6, metrics.trackWidth * 0.42))
                    .blur(radius: 2.1)
                    .mask {
                        ringMask(
                            LinearGradient(
                                colors: [Color.clear, Color.black, Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    }
                    .opacity(0.52)
            }
        }
    }

    private func ringMask(_ style: some ShapeStyle) -> some View {
        Circle()
            .inset(by: metrics.trackInset)
            .strokeBorder(style, lineWidth: metrics.trackWidth)
    }
}

private struct LiquidProgressRingFill: View {
    let progress: Double
    let tint: Color
    let metrics: LiquidRingMetrics

    var body: some View {
        GeometryReader { geometry in
            if progress <= 0 {
                EmptyView()
            } else if progress < metrics.dotThreshold {
                startDot(in: geometry.size)
            } else {
                ringSegment(fillGradient, lineWidth: metrics.fillWidth)
                    .shadow(color: tint.opacity(0.16), radius: 2.8, y: 0.9)
                    .overlay {
                        ringSegment(topHighlightGradient, lineWidth: metrics.highlightWidth)
                            .blur(radius: 0.2)
                    }
                    .overlay {
                        ringSegment(innerLiquidGradient, lineWidth: max(2.2, metrics.fillWidth * 0.72))
                            .blur(radius: 0.22)
                            .blendMode(.screen)
                    }
                    .overlay {
                        ringSegment(bottomShadeGradient, lineWidth: max(1.6, metrics.fillWidth * 0.9))
                            .opacity(0.38)
                    }
            }
        }
    }

    private var fillGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0.34), location: 0),
                .init(color: tint.opacity(0.92), location: 0.18),
                .init(color: tint.opacity(1), location: 0.46),
                .init(color: tint.opacity(0.84), location: 0.76),
                .init(color: tint.opacity(0.58), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var topHighlightGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.42), location: 0),
                .init(color: Color.white.opacity(0.2), location: 0.2),
                .init(color: Color.white.opacity(0.06), location: 0.52),
                .init(color: Color.clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var innerLiquidGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0.22), location: 0),
                .init(color: tint.opacity(0.08), location: 0.38),
                .init(color: Color.clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var bottomShadeGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.clear,
                Color.black.opacity(0.08),
                Color.black.opacity(0.14)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private func ringSegment(_ gradient: LinearGradient, lineWidth: CGFloat) -> some View {
        if metrics.isFullCircle {
            Circle()
                .inset(by: metrics.fillInset)
                .stroke(
                    gradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
        } else {
            Circle()
                .inset(by: metrics.fillInset)
                .trim(from: 0, to: progress)
                .rotation(.degrees(metrics.rotationDegrees))
                .stroke(
                    gradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
        }
    }

    private func startDot(in size: CGSize) -> some View {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let angle = metrics.rotationDegrees * .pi / 180
        let radius = max(
            0,
            min(size.width, size.height) * 0.5 - metrics.grooveCenterInset
        )
        let point = CGPoint(
            x: center.x + CGFloat(cos(angle)) * radius,
            y: center.y + CGFloat(sin(angle)) * radius
        )

        return Circle()
            .fill(fillGradient)
            .frame(width: metrics.dotDiameter, height: metrics.dotDiameter)
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(0.7)
            }
            .shadow(color: tint.opacity(0.14), radius: 2.6, y: 1)
            .position(point)
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = LayoutRules.cardRadius, tint: Color? = nil) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func frostedCapsuleSurface(
        prominent: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(FrostedCapsuleSurfaceModifier(prominent: prominent, tint: tint))
    }

    func frostedRoundedSurface(
        cornerRadius: CGFloat = 12,
        prominent: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(FrostedRoundedSurfaceModifier(cornerRadius: cornerRadius, prominent: prominent, tint: tint))
    }

    func frostedRoundedInput(cornerRadius: CGFloat = 12) -> some View {
        modifier(FrostedRoundedInputModifier(cornerRadius: cornerRadius))
    }

    func glassSelectableCard(
        selected: Bool,
        cornerRadius: CGFloat = 12,
        tint: Color = .accentColor
    ) -> some View {
        modifier(
            GlassSelectableCardModifier(
                selected: selected,
                cornerRadius: cornerRadius,
                tint: tint
            )
        )
    }

    @ViewBuilder
    func copoolActionButtonStyle(
        prominent: Bool = false,
        tint: Color? = nil,
        density: FrostedCapsuleButtonStyle.Density = .regular,
        iOSStyle: CopoolActionButtonIOSStyle = .system
    ) -> some View {
        #if os(iOS)
        if iOSStyle == .liquidGlass {
            self.buttonStyle(.frostedCapsule(prominent: prominent, tint: tint, density: density))
        } else if prominent {
            if let tint {
                self
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(density == .compact ? .small : .regular)
            } else {
                self
                    .buttonStyle(.borderedProminent)
                    .controlSize(density == .compact ? .small : .regular)
            }
        } else {
            if let tint {
                self
                    .buttonStyle(.bordered)
                    .tint(tint)
                    .controlSize(density == .compact ? .small : .regular)
            } else {
                self
                    .buttonStyle(.bordered)
                    .controlSize(density == .compact ? .small : .regular)
            }
        }
        #else
        self.buttonStyle(.frostedCapsule(prominent: prominent, tint: tint, density: density))
        #endif
    }

    func liquidGlassActionButtonStyle(
        prominent: Bool = false,
        tint: Color? = nil,
        density: FrostedCapsuleButtonStyle.Density = .regular
    ) -> some View {
        copoolActionButtonStyle(
            prominent: prominent,
            tint: tint,
            density: density,
            iOSStyle: .liquidGlass
        )
    }

    func frostedCapsuleInput() -> some View {
        modifier(FrostedCapsuleInputModifier())
    }
}

enum CopoolActionButtonIOSStyle {
    case system
    case liquidGlass
}

struct FrostedCapsuleButtonStyle: ButtonStyle {
    enum Density {
        case regular
        case compact
    }

    let prominent: Bool
    let tint: Color?
    let density: Density

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minimumHeight)
            .background(buttonBackground)
            .overlay {
                Capsule()
                    .stroke(separatorColor, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                Capsule()
                    .fill(.clear)
                    .glassEffect(
                        .regular
                            .tint(effectiveTint.opacity(0.22))
                            .interactive(),
                        in: .capsule
                    )
            } else {
                Capsule()
                    .fill(.clear)
                    .glassEffect(
                        .regular
                            .tint(Color.white.opacity(0.03))
                            .interactive(),
                        in: .capsule
                    )
            }
        } else {
            ZStack {
                Capsule()
                    .fill(prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial))
                if prominent {
                    Capsule()
                        .fill(effectiveTint.opacity(0.14))
                }
            }
        }
    }

    private var font: Font {
        switch density {
        case .regular:
            return .subheadline.weight(prominent ? .semibold : .medium)
        case .compact:
            return .callout.weight(prominent ? .semibold : .medium)
        }
    }

    private var horizontalPadding: CGFloat {
        density == .compact ? 10 : 12
    }

    private var verticalPadding: CGFloat {
        density == .compact ? 5 : 7
    }

    private var minimumHeight: CGFloat {
        density == .compact ? 30 : 34
    }

    private var separatorColor: Color {
        #if canImport(AppKit)
        let base = Color(nsColor: .separatorColor)
        #else
        let base = Color.secondary.opacity(0.2)
        #endif
        return prominent ? base.opacity(0.85) : base
    }

    private var effectiveTint: Color {
        tint ?? .accentColor
    }
}

extension ButtonStyle where Self == FrostedCapsuleButtonStyle {
    static func frostedCapsule(
        prominent: Bool = false,
        tint: Color? = nil,
        density: FrostedCapsuleButtonStyle.Density = .regular
    ) -> Self {
        FrostedCapsuleButtonStyle(prominent: prominent, tint: tint, density: density)
    }
}

private struct FrostedCapsuleInputModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frostedCapsuleSurface()
    }
}
