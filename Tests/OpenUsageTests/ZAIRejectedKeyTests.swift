import XCTest
@testable import OpenUsage

/// Z.ai can refuse a key inside an HTTP 200: `{"success":false,"code":401}`. That is a rejected key.
final class ZAIRejectedKeyTests: XCTestCase {
    func testA401InsideAnOKResponseIsARejectedKey() {
        let refused = Data(#"{"code":401,"msg":"token expired or incorrect","success":false}"#.utf8)
        XCTAssertTrue(ZAIUsageMapper.isRejectedKey(refused))
        XCTAssertFalse(ZAIUsageMapper.isNoCodingPlan(refused))
    }

    func testOtherBodiesAreNotARejectedKey() {
        XCTAssertFalse(ZAIUsageMapper.isRejectedKey(Data(#"{"code":500,"msg":"no coding plan","success":false}"#.utf8)))
        XCTAssertFalse(ZAIUsageMapper.isRejectedKey(Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8)))
    }
}
