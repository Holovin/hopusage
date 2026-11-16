import XCTest
@testable import OpenUsage

final class CopilotCLIAuthStoreTests: XCTestCase {
    private let config = """
    // User settings belong in settings.json.
    // This file is managed automatically.
    {
      "loggedInUsers": [
        { "host": "https://github.com", "login": "older" },
        { "host": "https://github.com", "login": "work" }
      ],
      "lastLoggedInUser": { "host": "https://github.com", "login": "work" }
    }
    """

    func testReadsTokenForLastLoggedInUser() {
        let keychain = AccountKeychain([
            "https://github.com:older": "gho_older",
            "https://github.com:work": "gho_work"
        ])
        let store = CopilotCLIAuthStore(files: FakeFiles([CopilotCLIAuthStore.configPath: config]), keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "gho_work")
        XCTAssertEqual(keychain.services, [CopilotCLIAuthStore.keychainService])
    }

    func testFallsBackToGithubSuffixedAccount() {
        let store = CopilotCLIAuthStore(
            files: FakeFiles([CopilotCLIAuthStore.configPath: config]),
            keychain: AccountKeychain(["https://github.com:work:github": "gho_suffixed"])
        )

        XCTAssertEqual(store.loadToken()?.value, "gho_suffixed")
    }

    func testNilWithoutConfigOrKeychainItem() {
        XCTAssertNil(CopilotCLIAuthStore(files: FakeFiles(), keychain: AccountKeychain(["https://github.com:work": "gho_x"])).loadToken())
        XCTAssertNil(CopilotCLIAuthStore(files: FakeFiles([CopilotCLIAuthStore.configPath: config]), keychain: AccountKeychain()).loadToken())
    }

    func testLoginFallsBackToFirstGithubUserAndSkipsOtherHosts() {
        let text = #"{ "loggedInUsers": [ { "host": "https://ghe.corp.example", "login": "ent" }, { "host": "https://github.com", "login": "dotcom" } ], "lastLoggedInUser": { "host": "https://ghe.corp.example", "login": "ent" } }"#

        XCTAssertEqual(CopilotCLIAuthStore.login(fromConfig: text), "dotcom")
    }

    func testLoginNilForEnterpriseOnlyOrBrokenConfig() {
        XCTAssertNil(CopilotCLIAuthStore.login(fromConfig: #"{ "lastLoggedInUser": { "host": "https://ghe.corp.example", "login": "ent" } }"#))
        XCTAssertNil(CopilotCLIAuthStore.login(fromConfig: "// only a comment"))
    }
}

@MainActor
final class CopilotCLIProviderTests: XCTestCase {
    func testCardHasOwnIdentityAndMetricIDs() {
        let provider = CopilotProvider.cli(defaults: UserDefaults(suiteName: #function)!)

        XCTAssertEqual(provider.provider.id, "copilot-cli")
        XCTAssertEqual(provider.provider.displayName, "Copilot (CLI/Desktop)")
        XCTAssertEqual(
            provider.widgetDescriptors.map(\.id),
            ["copilot-cli.premium", "copilot-cli.today", "copilot-cli.yesterday", "copilot-cli.trend", "copilot-cli.period",
             "copilot-cli.orgCredits", "copilot-cli.orgSpend", "copilot-cli.chat", "copilot-cli.completions",
             "copilot-cli.extra", "copilot-cli.last30"]
        )
        XCTAssertEqual(provider.widgetDescriptors.filter(\.isSpendTile).map(\.id),
                       ["copilot-cli.today", "copilot-cli.yesterday", "copilot-cli.last30"])
        XCTAssertFalse(CopilotProvider().widgetDescriptors.contains(where: \.isSpendTile))
        XCTAssertEqual(CopilotProvider().widgetDescriptors.first?.id, "copilot.premium")
    }

    func testAppSpecificErrorsWhenSignedOutOrRejected() async {
        let signedOut = CopilotProvider(
            provider: CopilotProvider.makeProvider(id: CopilotProvider.cliProviderID, displayName: "Copilot (CLI/Desktop)"),
            authStore: CopilotCLIAuthStore(files: FakeFiles(), keychain: AccountKeychain())
        )
        let signedOutSnapshot = await signedOut.refresh()
        XCTAssertEqual(signedOutSnapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(signedOutSnapshot.lines, [.badge(label: MetricLine.errorBadgeLabel, text: CopilotAuthError.appNotLoggedIn.errorDescription!, colorHex: "#EF4444")])

        let rejected = CopilotProvider(
            provider: CopilotProvider.makeProvider(id: CopilotProvider.cliProviderID, displayName: "Copilot (CLI/Desktop)"),
            authStore: CopilotCLIAuthStore(
                files: FakeFiles([CopilotCLIAuthStore.configPath: #"{ "lastLoggedInUser": { "host": "https://github.com", "login": "work" } }"#]),
                keychain: AccountKeychain(["https://github.com:work": "gho_work"])
            ),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data())))
        )
        let rejectedSnapshot = await rejected.refresh()
        XCTAssertEqual(rejectedSnapshot.errorCategory, .authExpired)
        XCTAssertEqual(rejectedSnapshot.lines, [.badge(label: MetricLine.errorBadgeLabel, text: CopilotAuthError.appTokenInvalid.errorDescription!, colorHex: "#EF4444")])
    }
}

/// Keychain fake keyed by account, recording which services were read.
private final class AccountKeychain: KeychainAccessing, @unchecked Sendable {
    private let values: [String: String]
    private(set) var services: Set<String> = []

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws {}
    func readGenericPassword(service: String, account: String) throws -> String? {
        services.insert(service)
        return values[account]
    }
    func writeGenericPassword(service: String, account: String, value: String) throws {}
    func genericPasswordExists(service: String) -> Bool? { nil }
}
