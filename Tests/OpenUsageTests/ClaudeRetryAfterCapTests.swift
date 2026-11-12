import XCTest
@testable import OpenUsage

/// A provider's `Retry-After` wait is honored up to an hour; a longer one is cut to an hour.
final class ClaudeRetryAfterCapTests: XCTestCase {
    private func seconds(_ header: String, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Int? {
        let response = HTTPResponse(statusCode: 429, headers: ["retry-after": header], body: Data())
        return ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now)
    }

    func testAShortWaitIsKept() {
        XCTAssertEqual(seconds("120"), 120)
    }

    func testALongWaitIsCutToAnHour() {
        XCTAssertEqual(seconds("86400"), 3600)
        XCTAssertEqual(seconds("Fri, 01 Jan 2100 00:00:00 GMT"), 3600)
    }
}
