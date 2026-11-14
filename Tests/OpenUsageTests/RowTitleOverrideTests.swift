import XCTest
@testable import OpenUsage

/// A reading can rename a row: Cursor's team-pool Extra Usage reads "Team Spend".
final class RowTitleOverrideTests: XCTestCase {
    private func cursorTitles(spendLimitUsage: [String: Any]) throws -> [String: String] {
        let usage: [String: Any] = [
            "enabled": true,
            "planUsage": ["autoPercentUsed": 0, "apiPercentUsed": 0],
            "spendLimitUsage": spendLimitUsage
        ]
        return try CursorUsageMapper.mapUsage(
            usage: usage, planName: "Team", creditGrants: nil, stripeBalanceCents: 0
        ).lineTitles
    }

    func testCursorTeamPoolReadsTeamSpend() throws {
        let titles = try cursorTitles(spendLimitUsage: ["limitType": "team", "pooledLimit": 50_000, "pooledRemaining": 40_000])
        XCTAssertEqual(titles, ["On-demand": "Team Spend"])
    }

    func testCursorPersonalLimitKeepsExtraUsage() throws {
        let titles = try cursorTitles(spendLimitUsage: ["limitType": "team", "individualLimit": 5_000, "individualRemaining": 4_000])
        XCTAssertTrue(titles.isEmpty)
    }

    func testASnapshotWithoutTitlesStillDecodes() throws {
        var snapshot = ProviderSnapshot(providerID: "cursor", displayName: "Cursor", lines: [])
        snapshot.lineTitles = ["On-demand": "Team Spend"]
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.lineTitles, ["On-demand": "Team Spend"])
    }
}
