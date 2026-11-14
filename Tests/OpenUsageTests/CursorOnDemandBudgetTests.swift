import XCTest
@testable import OpenUsage

/// Extra Usage spend is read from the same budget as its limit: a personal cap never shows the team's
/// pooled spend, and the team pool never shows one member's.
final class CursorOnDemandBudgetTests: XCTestCase {
    private func onDemand(_ spendLimitUsage: [String: Any], plan: String = "Team") throws -> (used: Double, limit: Double)? {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "planUsage": ["limit": 2000, "autoPercentUsed": 0, "apiPercentUsed": 12],
                "spendLimitUsage": spendLimitUsage
            ],
            planName: plan, creditGrants: nil, stripeBalanceCents: 0
        )
        guard case .progress(_, let used, let limit, _, _, _, _, _)? = mapped.lines.first(where: { $0.label == "On-demand" })
        else { return nil }
        return (used, limit)
    }

    func testAPersonalCapIgnoresTheTeamsPooledSpend() throws {
        let row = try XCTUnwrap(onDemand([
            "individualLimit": 5000, "individualUsed": 0, "individualRemaining": 5000,
            "pooledUsed": 3000, "totalSpend": 3000
        ]))
        XCTAssertEqual(row.used, 0)
        XCTAssertEqual(row.limit, 50)
    }

    func testTheTeamPoolIgnoresOneMembersSpend() throws {
        let row = try XCTUnwrap(onDemand([
            "limitType": "team", "pooledLimit": 10_000, "pooledUsed": 0, "pooledRemaining": 10_000,
            "individualUsed": 700, "totalSpend": 700
        ]))
        XCTAssertEqual(row.used, 0)
        XCTAssertEqual(row.limit, 100)
    }

    func testAPersonalCapWithNoTeamStillFallsBackToTotalSpend() throws {
        let row = try XCTUnwrap(onDemand(
            ["individualLimit": 5000, "individualUsed": 0, "totalSpend": 1200], plan: "Pro"
        ))
        XCTAssertEqual(row.used, 12)
    }

    func testSpendIsInferredFromTheSameBudgetsRemaining() throws {
        let row = try XCTUnwrap(onDemand(["individualLimit": 5000, "individualRemaining": 4000, "pooledRemaining": 100]))
        XCTAssertEqual(row.used, 10)
    }
}
