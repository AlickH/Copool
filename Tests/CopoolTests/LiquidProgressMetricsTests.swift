import XCTest
@testable import Copool

final class LiquidProgressMetricsTests: XCTestCase {
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
}
