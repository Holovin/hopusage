import XCTest
@testable import OpenUsage

/// Claude's Extra Usage follows the account's billing currency instead of always reading as dollars.
final class ClaudeExtraUsageCurrencyTests: XCTestCase {
    private func lines(_ extraUsage: String) throws -> [MetricLine] {
        let body = Data(#"{"extra_usage":\#(extraUsage)}"#.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
        return try ClaudeUsageMapper.mapUsageResponse(response, credentials: ClaudeOAuth()).lines
    }

    func testABoundedRowCarriesTheBillingCurrency() throws {
        let lines = try lines(#"{"is_enabled":true,"used_credits":500,"monthly_limit":1000,"currency":"EUR"}"#)
        guard case .progress(_, let used, let limit, let format, _, _, _, let currencyCode) =
            lines.first(where: { $0.label == "Extra usage spent" })
        else { return XCTFail("no Extra Usage meter") }
        XCTAssertEqual(used, 5)
        XCTAssertEqual(limit, 10)
        XCTAssertEqual(format, .dollars)
        XCTAssertEqual(currencyCode, "EUR")
    }

    func testAnUnboundedRowCarriesTheBillingCurrency() throws {
        let lines = try lines(#"{"is_enabled":true,"used_credits":1234,"currency":"eur"}"#)
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == "Extra usage spent" })
        else { return XCTFail("no Extra Usage row") }
        XCTAssertEqual(values.first?.currencyCode, "EUR")
        XCTAssertEqual(values.first.map { MetricFormatter.string(for: $0, style: .row) }, "€12.34")
    }

    func testDollarsAndAMissingCurrencyStayPlainDollars() throws {
        for currency in [#","currency":"USD""#, ""] {
            let lines = try lines(#"{"is_enabled":true,"used_credits":500,"monthly_limit":1000\#(currency)}"#)
            guard case .progress(_, _, _, _, _, _, _, let currencyCode) =
                lines.first(where: { $0.label == "Extra usage spent" })
            else { return XCTFail("no Extra Usage meter") }
            XCTAssertNil(currencyCode)
        }
    }

    func testDecimalPlacesSetTheMinorUnit() throws {
        let lines = try lines(#"{"is_enabled":true,"used_credits":500,"monthly_limit":1000,"currency":"JPY","decimal_places":0}"#)
        guard case .progress(_, let used, let limit, _, _, _, _, _) =
            lines.first(where: { $0.label == "Extra usage spent" })
        else { return XCTFail("no Extra Usage meter") }
        XCTAssertEqual(used, 500)
        XCTAssertEqual(limit, 1000)
    }

    func testTheFormatterPrintsTheCurrencySymbolInEveryStyle() {
        XCTAssertEqual(MetricFormatter.number(12.34, kind: .dollars, style: .row, currencyCode: "EUR"), "€12.34")
        XCTAssertEqual(MetricFormatter.number(12.34, kind: .dollars, style: .tray, currencyCode: "EUR"), "€12")
        XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .row, currencyCode: "GBP"), "£2.1K")
        XCTAssertEqual(MetricFormatter.number(12.34, kind: .dollars, style: .row), "$12.34")
        XCTAssertEqual(MetricFormatter.number(12.34, kind: .dollars, style: .row, currencyCode: "USD"), "$12.34")
    }

    func testACurrencyCodeSurvivesTheSnapshotCache() throws {
        let line = MetricLine.progress(label: "Extra usage spent", used: 5, limit: 10, format: .dollars, currencyCode: "EUR")
        let decoded = try JSONDecoder().decode(MetricLine.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(decoded, line)
    }
}
