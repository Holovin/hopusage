import XCTest
@testable import OpenUsage

/// The resets popover names what each reset refills, and spending one from the popover is switched off.
final class ResetNamesTests: XCTestCase {
    private func grant(_ fields: String) -> ClaudeResetGrantStatus.Grant? {
        let json = #"{"eligible":true,"grants":[{"id":"g1","resets_left":1,"ends_at":"2099-01-01T00:00:00Z",\#(fields)}]}"#
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return ClaudeResetGrantStatus.parse(object)?.grants.first
    }

    func testAClaudeGrantIsNamedByItsTypeThenByWhatItClears() {
        XCTAssertEqual(grant(#""type":"session","clears":[]"#)?.name, "Session")
        XCTAssertEqual(grant(#""type":"weekly","clears":[]"#)?.name, "Weekly")
        XCTAssertEqual(grant(#""type":"full","clears":[]"#)?.name, "Full Reset")
        XCTAssertEqual(grant(#""clears":["five_hour"]"#)?.name, "Session")
        XCTAssertEqual(grant(#""clears":["seven_day"]"#)?.name, "Weekly")
        XCTAssertEqual(grant(#""clears":["five_hour","seven_day"]"#)?.name, "Full Reset")
        XCTAssertEqual(grant(#""clears":[]"#)?.name, "Full Reset")
    }

    func testAGrantThatGivesBackTheWeekIsAFableReset() {
        XCTAssertEqual(grant(#""type":"weekly","gives_back_weekly":true,"clears":["seven_day"]"#)?.name, "Fable")
    }

    func testEveryChatGPTResetIsAFullReset() {
        let expiry = Date(timeIntervalSince1970: 4_000_000_000)
        let line = MetricLine.values(
            label: "Rate Limit Resets",
            values: [MetricValue(number: 2, kind: .count, label: "available")],
            expiriesAt: [expiry, expiry]
        )
        XCTAssertEqual(CodexUsageMapper.resetNames(in: [line]), [ResetName(expiresAt: expiry, name: "Full Reset")])
        XCTAssertTrue(CodexUsageMapper.resetNames(in: []).isEmpty)
    }

    func testThePopoverEntryCarriesItsName() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = now.addingTimeInterval(86_400 * 3)
        let unnamed = now.addingTimeInterval(86_400 * 5)
        let entries = RateLimitResetsDetail.entries(
            from: [unnamed, weekly], names: [ResetName(expiresAt: weekly, name: "Weekly")], now: now
        )
        XCTAssertEqual(entries.map(\.name), ["Weekly", nil])
        XCTAssertTrue(entries[0].accessibilityLabel.hasPrefix("Weekly 1,"))
        XCTAssertTrue(entries[1].accessibilityLabel.hasPrefix("Reset 2,"))
    }

    func testSpendingAResetFromThePopoverIsSwitchedOff() {
        XCTAssertFalse(ResetClaims.isEnabled)
    }
}
