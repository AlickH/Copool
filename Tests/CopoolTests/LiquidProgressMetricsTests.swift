import XCTest
import SwiftUI
@testable import Copool

final class LiquidProgressMetricsTests: XCTestCase {
    func testRenderModelClampsProgressIntoUnitRange() {
        XCTAssertEqual(LiquidProgressRenderModel(progress: -0.4).fillScale, 0)
        XCTAssertEqual(LiquidProgressRenderModel(progress: 0.45).fillScale, 0.45, accuracy: 0.001)
        XCTAssertEqual(LiquidProgressRenderModel(progress: 1.8).fillScale, 1, accuracy: 0.001)
    }

    func testRenderModelOnlyShowsFillForPositiveProgress() {
        XCTAssertFalse(LiquidProgressRenderModel(progress: 0).showsFill)
        XCTAssertTrue(LiquidProgressRenderModel(progress: 0.01).showsFill)
    }

    func testLowProgressUsesFullLeadingCapWidth() {
        let metrics = LiquidProgressMetrics(progress: 0.01, totalWidth: 250)

        XCTAssertGreaterThan(metrics.rawFillWidth, 0)
        XCTAssertLessThan(metrics.rawFillWidth, metrics.grooveHeight)
        XCTAssertEqual(metrics.visibleFillWidth, metrics.grooveHeight)
    }

    func testHigherProgressKeepsMeasuredFillWidth() {
        let metrics = LiquidProgressMetrics(progress: 0.3, totalWidth: 250)

        XCTAssertEqual(metrics.visibleFillWidth, metrics.rawFillWidth)
    }

    func testDarkGroovePaletteKeepsRingTrackVisibleOnBlackBackground() {
        let palette = LiquidGroovePalette(colorScheme: .dark)

        XCTAssertEqual(palette.glassTintOpacity, 0.14, accuracy: 0.001)
        XCTAssertEqual(palette.topEdgeOpacity, 0.24, accuracy: 0.001)
        XCTAssertEqual(palette.centerGlowOpacity, 0.11, accuracy: 0.001)
        XCTAssertEqual(palette.ringOuterHighlightOpacity, 0.22, accuracy: 0.001)
    }
}
