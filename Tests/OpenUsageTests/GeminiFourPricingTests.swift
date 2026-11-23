import XCTest
@testable import OpenUsage

/// Gemini 4 Neon, Hydrogen, and Carbon resolve offline from the bundled supplement, including the
/// effort, `-tiered`, and display-label forms Antigravity writes to its conversation logs.
final class GeminiFourPricingTests: XCTestCase {
    private let pricing = ModelPricing(
        supplement: TestPricing.bundled.supplement,
        primary: PricingCatalog(),
        secondary: PricingCatalog()
    )

    private func assertPriced(
        _ models: [String], as canonical: String, rates: ModelRates,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for model in models {
            XCTAssertEqual(pricing.resolve(model: model), rates, model, file: file, line: line)
            XCTAssertEqual(pricing.supplement.canonicalName(for: model), canonical, model, file: file, line: line)
            XCTAssertEqual(pricing.familyName(for: model, stripping: ["-preview"]), canonical, model, file: file, line: line)
        }
    }

    func testNeonIDsAndLabelsUseNeonRates() {
        assertPriced([
            "gemini-4-neon", "gemini-4-neon-high", "gemini-4-neon-low", "gemini-4-neon-xhigh",
            "gemini-4-neon-tiered-high", "gemini-4-neon-preview", "gemini-4-neon-high-preview",
            "Gemini 4 Neon", "Gemini 4 Neon (High)", "Gemini 4 Neon (Preview)"
        ], as: "gemini-4-neon", rates: ModelRates(
            inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3, cacheReadPerMillion: 0.15
        ))
    }

    func testHydrogenTieredAndSonarIDsUseHydrogenRates() {
        assertPriced([
            "gemini-4-hydrogen", "gemini-4-hydrogen-tiered-high", "gemini-4-hydrogen-tiered-xhigh",
            "gemini-4-hydrogen-sonar", "gemini-4-hydrogen-sonar-high", "gemini-4-hydrogen-medium",
            "gemini-4-hydrogen-preview", "Gemini 4 Hydrogen (Low)", "Gemini 4 Hydrogen (Preview)"
        ], as: "gemini-4-hydrogen", rates: ModelRates(
            inputPerMillion: 1.5, outputPerMillion: 7.5, cacheWritePerMillion: 1.5, cacheReadPerMillion: 0.075
        ))
    }

    func testCarbonUsesIntroductoryRates() {
        assertPriced([
            "gemini-4-carbon", "gemini-4-carbon-high", "gemini-4-carbon-tiered-high",
            "gemini-4-carbon-preview", "Gemini 4 Carbon (XHigh)", "Gemini 4 Carbon (Preview)"
        ], as: "gemini-4-carbon", rates: ModelRates(
            inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2, cacheReadPerMillion: 0.1
        ))
    }

    func testOtherVersionsAndUnknownVariantsStayUnpriced() {
        for model in [
            "gemini-5-neon", "gemini-4.1-hydrogen", "gemini-4-neon-fast", "gemini-4-hydrogen-turbo",
            "gemini-4-carbon-contributor", "Gemini 4 Neon (Fast)", "Gemini 5 Hydrogen"
        ] {
            XCTAssertNil(pricing.supplement.canonicalName(for: model), model)
            XCTAssertNil(pricing.resolve(model: model), model)
        }
    }
}
