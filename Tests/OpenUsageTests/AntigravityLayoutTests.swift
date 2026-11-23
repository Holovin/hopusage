import XCTest
@testable import OpenUsage

/// Layout defaults and migration behavior for Antigravity's quota meters, usage trend, and local
/// spend history. Uses the real provider's registry with the real `DefaultLayout` seeds.
@MainActor
final class AntigravityLayoutTests: XCTestCase {

    func testFreshDefaultsSeedQuotaTrendAndSpendMetricsWithOnlyQuotaPins() {
        let store = makeStore("FreshDefaults")

        // Every quota, trend, and spend metric is enabled in provider declaration order.
        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "antigravity.geminiPro", "antigravity.geminiWeekly",
            "antigravity.claude", "antigravity.claudeWeekly", "antigravity.trend",
            "antigravity.today", "antigravity.yesterday", "antigravity.last30"
        ])

        // Fork: nothing is pinned by default.
        XCTAssertEqual(store.pinnedMetricIDs, [])

        // Gemini pair and trend above the fold; Claude and spend below the caret.
        let group = store.customizeGroups.first { $0.provider.id == "antigravity" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), [
            "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.trend"
        ])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), [
            "antigravity.claude", "antigravity.claudeWeekly",
            "antigravity.today", "antigravity.yesterday", "antigravity.last30"
        ])
        XCTAssertEqual(store.spendCapableProviders.map(\.id), ["antigravity"])
    }

    func testExistingUserLayoutAutoSeedsWeeklyMetricsBelowCaretForClaudePool() {
        // A layout from before the weekly metrics shipped: Antigravity is absent from the migration
        // baseline, so `seedNewDefaultMetrics` auto-enables new weekly metrics once. Claude
        // Weekly (a default-expanded metric) enters below the caret; metrics the user already lived
        // with stay always-shown.
        let defaults = makeDefaults("SeedWeeklies")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isMetricEnabled("antigravity.geminiWeekly"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.claudeWeekly"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.trend"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.today"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.yesterday"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.last30"))
        XCTAssertTrue(store.expandedMetricIDs.contains("antigravity.claudeWeekly"))
        XCTAssertTrue(store.expandedMetricIDs.contains("antigravity.today"))
        XCTAssertTrue(store.expandedMetricIDs.contains("antigravity.yesterday"))
        XCTAssertTrue(store.expandedMetricIDs.contains("antigravity.last30"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.geminiWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.trend"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.claude"),
                       "a metric the user already lived with is never silently tucked away")
    }

    func testSavedGeminiFlashStateIsFilteredEverywhere() {
        // `antigravity.geminiFlash` no longer exists (owner-approved: its layout state drops with no
        // migration). Every load path filters unknown IDs against the registry, so stale saved state
        // self-heals.
        let defaults = makeDefaults("FlashFilter")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.geminiFlash"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)
        defaults.set(["antigravity.geminiPro", "antigravity.geminiFlash"], forKey: "layout.menuBarPins")
        saveStored(
            ["antigravity": ["antigravity.geminiFlash", "antigravity.geminiPro", "antigravity.claude"]],
            forKey: "layout.metricOrderByProvider", in: defaults
        )

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("antigravity.geminiFlash"))
        XCTAssertFalse(store.orderedSupportedMetrics(for: "antigravity").map(\.id).contains("antigravity.geminiFlash"))
        // The saved pin set is respected exactly (dead ID dropped, no weekly pin auto-added).
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro"])
    }

    func testAbsentPinsKeyAdoptsTheDefaultPinsOnUpgrade() {
        // Pins re-derive from current defaults whenever the pins key is absent, and init never
        // persists pins. Fork: the defaults pin nothing, so such a user ends up with no pins.
        let defaults = makeDefaults("PinsAbsent")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.pinnedMetricIDs, [])
    }

    func testRetiredArgonWeeklyIsFilteredFromSavedLayout() {
        // Argon Weekly shipped before Antigravity folded Argon into the shared Gemini pool; a layout
        // saved with it enabled, pinned, ordered, and expanded must drop it everywhere.
        let defaults = makeDefaults("RetiredArgon")
        let savedIDs = currentMetricIDs + ["antigravity.argonWeekly"]
        saveStored(savedIDs.map { PlacedWidget(descriptorID: $0) }, forKey: "layout", in: defaults)
        saveStored(savedIDs, forKey: "layout.seededDefaults", in: defaults)
        saveStored(["antigravity": ["antigravity.argonWeekly"] + currentMetricIDs],
                   forKey: "layout.metricOrderByProvider", in: defaults)
        defaults.set(["antigravity.argonWeekly", "antigravity.claude"], forKey: "layout.menuBarPins")
        defaults.set(["antigravity.argonWeekly"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.placed.contains { $0.descriptorID == "antigravity.argonWeekly" })
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.claude"])
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.argonWeekly"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "antigravity").map(\.id), currentMetricIDs)
    }

    // A saved pins key never gains new default pins — asserted above in
    // testSavedGeminiFlashStateIsFilteredEverywhere (the exact-pin-set check).

    // MARK: - Fixtures

    private var currentMetricIDs: [String] {
        [
            "antigravity.geminiPro", "antigravity.geminiWeekly",
            "antigravity.claude", "antigravity.claudeWeekly", "antigravity.trend",
            "antigravity.today", "antigravity.yesterday", "antigravity.last30"
        ]
    }

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .antigravityOnly, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.AntigravityLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// A registry with just the live Antigravity provider, so `DefaultLayout` seeds its metrics only.
    @MainActor
    static var antigravityOnly: WidgetRegistry { .from([AntigravityProvider()]) }
}
