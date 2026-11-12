import XCTest
@testable import OpenUsage

/// A provider number too large for an `Int` is treated as malformed instead of trapping.
final class ProviderNumberRangeTests: XCTestCase {
    func testIntRejectsValuesOutsideTheIntRange() {
        XCTAssertEqual(ProviderParse.int(42.9), 42)
        XCTAssertEqual(ProviderParse.int(-3), -3)
        XCTAssertNil(ProviderParse.int(1e300))
        XCTAssertNil(ProviderParse.int(-1e300))
        XCTAssertNil(ProviderParse.int(Double(Int.max)))
    }

    func testAHugeDurationStillFormats() {
        XCTAssertNotNil(Formatters.compactDuration(1e300))
    }

    func testAHugeClaudeResetCountIsMalformed() {
        let block: [String: Any] = ["grants": [["id": "g1", "resets_left": 1e300]]]
        XCTAssertNil(ClaudeResetGrantStatus.parse(block))
    }
}
