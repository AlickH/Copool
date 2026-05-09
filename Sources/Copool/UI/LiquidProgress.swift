import SwiftUI

struct LiquidProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = LayoutRules.liquidProgressHeight

    @Environment(\.colorScheme) private var colorScheme

    private var clampedProgress: Double {
        max(0, min(1, progress))
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = LiquidProgressMetrics(
                progress: clampedProgress,
                totalWidth: geometry.size.width,
                totalHeight: height
            )

            ZStack(alignment: .leading) {
                FlatProgressTrack(colorScheme: colorScheme)

                if metrics.visibleFillWidth > 0 {
                    FlatProgressFill(tint: tint, colorScheme: colorScheme)
                        .frame(width: metrics.visibleFillWidth, height: metrics.grooveHeight)
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, metrics.horizontalInset)
                        .padding(.vertical, metrics.verticalInset)
                }
            }
        }
        .frame(height: height)
        .animation(
            ProgressAnimationTokens.barSpring,
            value: clampedProgress
        )
    }
}

struct LiquidProgressRenderModel {
    let fillScale: Double

    init(progress: Double) {
        fillScale = max(0, min(1, progress))
    }

    var showsFill: Bool {
        fillScale > 0
    }
}

struct LiquidProgressRing: View {
    let progress: Double
    let tint: Color
    let lineWidth: CGFloat

    private var clampedProgress: Double {
        max(0, min(1, progress))
    }

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
        .animation(
            ProgressAnimationTokens.ringSpring,
            value: clampedProgress
        )
    }

    private var progressMetrics: LiquidRingMetrics {
        LiquidRingMetrics(progress: clampedProgress, lineWidth: lineWidth)
    }
}

private enum ProgressAnimationTokens {
    static let barSpring: Animation = .spring(
        response: 0.34,
        dampingFraction: 0.86,
        blendDuration: 0.1
    )
    static let ringSpring: Animation = .spring(
        response: 0.32,
        dampingFraction: 0.88,
        blendDuration: 0.08
    )
}

struct LiquidProgressMetrics {
    let progress: Double
    let totalWidth: CGFloat
    let totalHeight: CGFloat

    init(
        progress: Double,
        totalWidth: CGFloat,
        totalHeight: CGFloat = LayoutRules.liquidProgressHeight
    ) {
        self.progress = progress
        self.totalWidth = totalWidth
        self.totalHeight = totalHeight
    }

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
        max(4, totalHeight - verticalInset * 2)
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

private struct FlatProgressTrack: View {
    let colorScheme: ColorScheme

    var body: some View {
        Capsule()
            .fill(trackColor)
            .overlay {
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }

    private var trackColor: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.10)
        default:
            Color.black.opacity(0.08)
        }
    }

    private var borderColor: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.06)
        default:
            Color.black.opacity(0.06)
        }
    }
}

private struct FlatProgressFill: View {
    let tint: Color
    let colorScheme: ColorScheme

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [leadingColor, trailingColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    private var leadingColor: Color {
        switch colorScheme {
        case .dark:
            tint.opacity(0.92)
        default:
            tint.opacity(0.84)
        }
    }

    private var trailingColor: Color {
        switch colorScheme {
        case .dark:
            tint.opacity(0.74)
        default:
            tint.opacity(0.96)
        }
    }
}

struct LiquidRingMetrics {
    let progress: Double
    let lineWidth: CGFloat

    var trimEnd: Double {
        max(0, min(1, progress))
    }

    var isFullCircle: Bool {
        trimEnd >= 0.999
    }

    var rotationDegrees: Double {
        -90
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

    var dotDiameter: CGFloat {
        max(5.8, fillWidth * 1.04)
    }

    func dotThreshold(in size: CGSize) -> Double {
        let radius = max(
            0,
            min(size.width, size.height) * 0.5 - grooveCenterInset
        )
        guard radius > 0 else { return 0 }
        let circumference = 2 * .pi * radius
        guard circumference > 0 else { return 0 }
        return min(1, Double(dotDiameter / circumference))
    }
}

struct LiquidGroovePalette {
    let glassTintOpacity: Double
    let topEdgeOpacity: Double
    let centerGlowOpacity: Double
    let ringOuterHighlightOpacity: Double
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
            glassTintOpacity = 0.14
            topEdgeOpacity = 0.24
            centerGlowOpacity = 0.11
            ringOuterHighlightOpacity = 0.22
            glassTint = Color.white.opacity(glassTintOpacity)
            coreTop = Color.white.opacity(0.07)
            coreMid = Color.black.opacity(0.30)
            coreBottom = Color.white.opacity(0.03)
            topEdge = Color.white.opacity(topEdgeOpacity)
            bottomEdge = Color.black.opacity(0.42)
            centerGlow = Color.white.opacity(centerGlowOpacity)
            innerEdge = Color.black.opacity(0.24)
            ringOuterHighlight = Color.white.opacity(ringOuterHighlightOpacity)
            ringInnerHighlight = Color.white.opacity(0.12)
            ringShadow = Color.black.opacity(0.34)
            ringShadowSoft = Color.black.opacity(0.16)
            ringCoreGlow = Color.white.opacity(0.04)
        default:
            glassTintOpacity = 0.06
            topEdgeOpacity = 0.26
            centerGlowOpacity = 0.08
            ringOuterHighlightOpacity = 0.30
            glassTint = Color.white.opacity(glassTintOpacity)
            coreTop = Color.black.opacity(0.15)
            coreMid = Color.black.opacity(0.05)
            coreBottom = Color.white.opacity(0.05)
            topEdge = Color.white.opacity(topEdgeOpacity)
            bottomEdge = Color.black.opacity(0.1)
            centerGlow = Color.white.opacity(centerGlowOpacity)
            innerEdge = Color.black.opacity(0.08)
            ringOuterHighlight = Color.white.opacity(ringOuterHighlightOpacity)
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

private struct LiquidProgressRingTrack: View {
    @Environment(\.colorScheme) private var colorScheme

    let metrics: LiquidRingMetrics

    var body: some View {
        Circle()
            .inset(by: metrics.trackInset)
            .strokeBorder(trackColor, lineWidth: metrics.trackWidth)
            .overlay {
                Circle()
                    .inset(by: metrics.trackInset)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }

    private var trackColor: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.10)
        default:
            Color.black.opacity(0.08)
        }
    }

    private var borderColor: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.06)
        default:
            Color.black.opacity(0.06)
        }
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
            } else if progress < metrics.dotThreshold(in: geometry.size) {
                startDot(in: geometry.size)
            } else {
                ringSegment(fillGradient, lineWidth: metrics.fillWidth)
            }
        }
    }

    private var fillGradient: LinearGradient {
        LinearGradient(
            colors: [
                tint.opacity(0.82),
                tint.opacity(0.96)
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
            .position(point)
    }
}
