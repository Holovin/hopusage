import XCTest
@testable import OpenUsage

/// A countdown a month or more away reads in months and days instead of a three-digit day count.
final class ResetCountdownMonthsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date { OpenUsageISO8601.date(from: text)! }

    func testAMonthOrMoreReadsInMonthsAndDays() {
        let now = date("2026-01-01T00:00:00Z")
        XCTAssertEqual(Formatters.countdown(to: date("2026-04-13T12:00:00Z"), now: now, calendar: calendar), "3m 12d")
        XCTAssertEqual(Formatters.countdown(to: date("2026-02-01T00:00:00Z"), now: now, calendar: calendar), "1m 0d")
    }

    func testUnderAMonthKeepsDaysAndHours() {
        let now = date("2026-01-01T00:00:00Z")
        XCTAssertEqual(Formatters.countdown(to: date("2026-01-13T18:00:00Z"), now: now, calendar: calendar), "12d 18h")
        XCTAssertEqual(Formatters.countdown(to: date("2026-01-01T02:30:00Z"), now: now, calendar: calendar), "2h 30m")
    }
}
