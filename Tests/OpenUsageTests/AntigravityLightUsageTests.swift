import XCTest
@testable import OpenUsage

/// A lightly used Antigravity window keeps its fraction of a percent, so it doesn't read as untouched,
/// and the quota summary asks the daily host first, which has the active counters.
final class AntigravityLightUsageTests: XCTestCase {
    private func used(_ fraction: Double) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _, _) =
            AntigravityUsageMapper.line(pool: "Session", fraction: fraction, resetTime: nil, periodMs: MetricPeriod.sessionMs)
        else { return nil }
        return used
    }

    func testALightlyUsedWindowIsNotRoundedToZero() {
        XCTAssertEqual(used(0.996), 0.4)
        XCTAssertEqual(used(1), 0)
    }

    func testWholePercentsCarryNoFloatNoise() {
        XCTAssertEqual(used(0.8), 20)
        XCTAssertEqual(used(0.7), 30)
    }

    func testTheQuotaSummaryAsksTheDailyHostFirst() {
        XCTAssertEqual(AntigravityUsageClient.quotaSummaryURLs, [
            "https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"
        ])
        XCTAssertEqual(AntigravityUsageClient.cloudCodeURLs.first, "https://cloudcode-pa.googleapis.com")
    }
}
