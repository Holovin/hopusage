import Foundation

/// Antigravity quota widget IDs and metric labels, shared by `AntigravityProvider.widgetDescriptors`
/// and `AntigravityUsageMapper` so both sides of the exact-string label binding
/// (`WidgetDescriptor.metricLabel` == `MetricLine.label`, resolved in `WidgetDataStore.data(for:)`)
/// come from one place — label drift there is a silent "No data" failure.
///
/// The shared Gemini and non-Gemini (Claude, GPT-OSS) pools each have a rolling 5-hour window plus a
/// weekly window. The shared Gemini pair is titled "Session" / "Weekly"; the non-Gemini pool is titled
/// after Antigravity's own "Claude and GPT models" group. The `claude*` IDs keep their historical raw
/// values, and `geminiID` keeps `antigravity.geminiPro`, so existing users' layout state
/// (enabled/pin/order) carries over with zero migration.
enum AntigravityMetric {
    static let geminiID = "antigravity.geminiPro"
    static let geminiWeeklyID = "antigravity.geminiWeekly"
    static let claudeID = "antigravity.claude"
    static let claudeWeeklyID = "antigravity.claudeWeekly"

    static let sessionLabel = "Session"
    static let weeklyLabel = "Weekly"
    static let claudeLabel = "Claude and GPT"
    static let claudeWeeklyLabel = "Claude and GPT Weekly"
}
