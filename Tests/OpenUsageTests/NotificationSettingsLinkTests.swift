import XCTest
@testable import OpenUsage

/// The "notifications are off" action opens the app's own page in System Settings → Notifications.
@MainActor
final class NotificationSettingsLinkTests: XCTestCase {
    func testTheLinkOpensTheAppsOwnNotificationsPage() {
        XCTAssertEqual(
            AppNotifications.systemNotificationsSettingsURL(bundleID: "com.example.app")?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.example.app"
        )
    }

    func testWithoutABundleIDTheLinkOpensTheNotificationsList() {
        for bundleID in [nil, ""] as [String?] {
            XCTAssertEqual(
                AppNotifications.systemNotificationsSettingsURL(bundleID: bundleID)?.absoluteString,
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            )
        }
    }
}
