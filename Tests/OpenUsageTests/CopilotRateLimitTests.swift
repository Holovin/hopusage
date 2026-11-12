import XCTest
@testable import OpenUsage

/// GitHub sends its rate limits as 403 with `x-ratelimit-remaining: 0` or `retry-after`. That is a
/// wait, not a rejected token.
final class CopilotRateLimitTests: XCTestCase {
    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data())
    }

    func testA403WithRateLimitHeadersIsARateLimit() {
        XCTAssertTrue(CopilotUsageMapper.isRateLimit(response(403, ["x-ratelimit-remaining": "0"])))
        XCTAssertTrue(CopilotUsageMapper.isRateLimit(response(403, ["retry-after": "60"])))
        XCTAssertTrue(CopilotUsageMapper.isRateLimit(response(429)))
    }

    func testAPlain403Or401IsNotARateLimit() {
        XCTAssertFalse(CopilotUsageMapper.isRateLimit(response(403)))
        XCTAssertFalse(CopilotUsageMapper.isRateLimit(response(403, ["x-ratelimit-remaining": "12"])))
        XCTAssertFalse(CopilotUsageMapper.isRateLimit(response(401, ["retry-after": "60"])))
    }

    func testTheRateLimitErrorIsCategorizedAsRateLimited() {
        XCTAssertEqual(CopilotUsageError.rateLimited.errorCategory, .rateLimited)
    }
}
