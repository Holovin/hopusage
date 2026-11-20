import XCTest
@testable import OpenUsage

final class OpenAIAPIPeriodTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testStartsOnTheChosenDayOfThisOrThePreviousMonth() {
        let cases: [(name: String, day: Int, now: Date, expected: Date)] = [
            ("1st", 1, date(2026, 11, 18), date(2026, 11, 1, hour: 0)),
            ("day already passed", 5, date(2026, 11, 18), date(2026, 11, 5, hour: 0)),
            ("day is today", 18, date(2026, 11, 18), date(2026, 11, 18, hour: 0)),
            ("day still ahead", 20, date(2026, 11, 18), date(2026, 10, 20, hour: 0)),
            ("31st in a 30-day month", 31, date(2026, 11, 30), date(2026, 11, 30, hour: 0)),
            ("31st ahead, previous month has it", 31, date(2026, 11, 18), date(2026, 10, 31, hour: 0)),
            ("30th ahead, previous month is February", 30, date(2026, 3, 10), date(2026, 2, 28, hour: 0)),
            ("previous month crosses a year", 15, date(2027, 1, 3), date(2026, 12, 15, hour: 0))
        ]

        for entry in cases {
            XCTAssertEqual(OpenAIAPIPeriod.start(day: entry.day, now: entry.now, calendar: calendar), entry.expected, entry.name)
        }
    }
}

final class OpenAIAPIUsageMapperTests: XCTestCase {
    func testAggregatesCostsAndTokensPerProjectAndRanksByCost() {
        let costs = OpenAIAPIUsageMapper.costsByProject([
            ["results": [
                ["project_id": "proj_a", "amount": ["value": 1.5, "currency": "usd"]],
                ["project_id": "proj_b", "amount": ["value": 4.0, "currency": "usd"]]
            ]],
            ["results": [
                ["project_id": "proj_a", "amount": ["value": 0.5, "currency": "usd"]],
                ["project_id": NSNull(), "amount": ["value": 0.25, "currency": "usd"]]
            ]]
        ])
        let tokens = OpenAIAPIUsageMapper.tokensByProject([
            ["results": [
                ["project_id": "proj_a", "input_tokens": 1000, "output_tokens": 200],
                ["project_id": "proj_b", "input_tokens": 50, "output_tokens": 50]
            ]]
        ])

        XCTAssertEqual(costs, ["proj_a": 2.0, "proj_b": 4.0, "": 0.25])
        XCTAssertEqual(tokens, ["proj_a": 1200, "proj_b": 100])

        let projects = OpenAIAPIUsageMapper.projects(costs: costs, tokens: tokens, names: ["proj_b": "Backend"])
        XCTAssertEqual(projects.map(\.name), ["Backend", "proj_a", ModelUsageEntry.unattributedModelName])
        XCTAssertEqual(projects.map(\.costUSD), [4.0, 2.0, 0.25])
    }

    func testUsageLineCarriesTotalsAndFoldsTheTailIntoOther() throws {
        let projects = (1...7).map {
            OpenAIAPIUsageMapper.ProjectUsage(projectID: "proj_\($0)", name: "P\($0)", costUSD: Double(10 - $0), tokens: $0 * 100)
        }
        let line = OpenAIAPIUsageMapper.usageLine(projects: projects, includesTokens: true, periodStart: Date())

        guard case .values(let label, let values, _, _, _, let breakdown) = line else {
            return XCTFail("expected a values line")
        }
        XCTAssertEqual(label, "API Usage")
        XCTAssertEqual(values, [
            MetricValue(number: 42, kind: .dollars),
            MetricValue(number: 2800, kind: .count, label: "tokens")
        ])
        let models = try XCTUnwrap(breakdown?.models)
        XCTAssertEqual(models.map(\.model), ["P1", "P2", "P3", "P4", "P5", ModelUsageEntry.otherModelName])
        XCTAssertEqual(models.last?.costUSD, 7)
        XCTAssertEqual(models.last?.totalTokens, 1300)
        XCTAssertEqual(breakdown?.totalCostUSD, 42)
    }

    func testUsageLineWithoutTokensShowsDollarsOnly() {
        let line = OpenAIAPIUsageMapper.usageLine(
            projects: [.init(projectID: "proj_a", name: "A", costUSD: 3, tokens: 0)],
            includesTokens: false, periodStart: Date()
        )
        guard case .values(_, let values, _, _, _, _) = line else { return XCTFail("expected a values line") }
        XCTAssertEqual(values, [MetricValue(number: 3, kind: .dollars)])
    }

    func testPagesReadTheCursorOnlyWhileMoreRemain() {
        let more = OpenAIAPIUsageMapper.bucketPage(Data(#"{"data":[{"results":[]}],"has_more":true,"next_page":"p2"}"#.utf8))
        let last = OpenAIAPIUsageMapper.bucketPage(Data(#"{"data":[],"has_more":false,"next_page":"p3"}"#.utf8))
        XCTAssertEqual(more?.nextPage, "p2")
        XCTAssertEqual(more?.buckets.count, 1)
        XCTAssertNil(last?.nextPage)
        XCTAssertNil(OpenAIAPIUsageMapper.bucketPage(Data(#"{"error":{}}"#.utf8)))

        let projects = OpenAIAPIUsageMapper.projectsPage(Data(#"{"data":[{"id":"proj_a","name":"App"},{"id":"proj_b","name":" "}],"has_more":true,"last_id":"proj_b"}"#.utf8))
        XCTAssertEqual(projects?.names, ["proj_a": "App", "proj_b": "proj_b"])
        XCTAssertEqual(projects?.lastID, "proj_b")
    }
}

@MainActor
final class OpenAIAPIUsageTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_795_000_000)
    }

    private func usage(
        files: FakeFiles = FakeFiles([OpenAIAPIAuthStore.configPath(cardID: "codex@ab12cd34"): #"{"apiKey":"sk-admin-test"}"#]),
        clock: Clock = Clock(),
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> (OpenAIAPIUsage, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        let usage = OpenAIAPIUsage(
            cardID: "codex@ab12cd34",
            authStore: OpenAIAPIAuthStore(cardID: "codex@ab12cd34", files: files, environment: FakeEnvironment()),
            usageClient: OpenAIAPIUsageClient(http: http),
            periodStartDay: { 1 },
            refreshInterval: { 7_200 },
            now: { clock.now }
        )
        return (usage, http)
    }

    nonisolated private static let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
        let path = request.url.path
        let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value
        if path.hasSuffix("/costs") {
            return page == nil
                ? okResponse(#"{"data":[{"results":[{"project_id":"proj_a","amount":{"value":10}}]}],"has_more":true,"next_page":"c2"}"#)
                : okResponse(#"{"data":[{"results":[{"project_id":"proj_b","amount":{"value":2.5}}]}],"has_more":false}"#)
        }
        if path.hasSuffix("/usage/completions") {
            return okResponse(#"{"data":[{"results":[{"project_id":"proj_a","input_tokens":900,"output_tokens":100}]}],"has_more":false}"#)
        }
        return okResponse(#"{"data":[{"id":"proj_a","name":"Agents"},{"id":"proj_b","name":"Website"}],"has_more":false}"#)
    }

    func testCombinesCostPagesTokensAndProjectNames() async throws {
        let (usage, http) = usage(handler: Self.handler)

        let result = await usage.current()

        guard case .values(let label, let values, _, _, _, let breakdown) = try XCTUnwrap(result.line) else {
            return XCTFail("expected a values line")
        }
        XCTAssertNil(result.warning)
        XCTAssertEqual(label, "API Usage")
        XCTAssertEqual(values, [
            MetricValue(number: 12.5, kind: .dollars),
            MetricValue(number: 1000, kind: .count, label: "tokens")
        ])
        XCTAssertEqual(breakdown?.models.map(\.model), ["Agents", "Website"])
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer sk-admin-test" })
        let costQuery = try XCTUnwrap(http.requests.first?.url.query)
        XCTAssertTrue(costQuery.contains("group_by=project_id"))
        XCTAssertTrue(costQuery.contains("bucket_width=1d"))
    }

    func testReusesTheRowUntilTheIntervalPassesOrTheKeyChanges() async {
        let clock = Clock()
        let (usage, http) = usage(clock: clock, handler: Self.handler)
        func costCalls() -> Int { http.requests.filter { $0.url.path.hasSuffix("/costs") }.count }

        _ = await usage.current()
        XCTAssertEqual(costCalls(), 2)

        clock.now += 7_000
        let cached = await usage.current()
        XCTAssertNotNil(cached.line)
        XCTAssertEqual(costCalls(), 2)

        clock.now += 200
        _ = await usage.current()
        XCTAssertEqual(costCalls(), 4)
        // Project names are kept for a day.
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/projects") }.count, 1)

        usage.invalidate()
        _ = await usage.current()
        XCTAssertEqual(costCalls(), 6)
    }

    func testFailureKeepsTheLastRowAndWarns() async {
        let clock = Clock()
        let failing = FailSwitch()
        let (usage, _) = usage(clock: clock) { request in
            if failing.on { return HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
            return try await Self.handler(request)
        }

        let first = await usage.current()
        failing.on = true
        clock.now += 8_000
        let second = await usage.current()

        XCTAssertNotNil(first.line)
        XCTAssertEqual(second.line, first.line)
        XCTAssertEqual(second.warning, "API Usage: OpenAI request failed (HTTP 500).")
    }

    func testTokenAndProjectFailuresStillShowDollars() async throws {
        let (usage, _) = usage { request in
            if request.url.path.hasSuffix("/costs") {
                return okResponse(#"{"data":[{"results":[{"project_id":"proj_a","amount":{"value":3}}]}],"has_more":false}"#)
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }

        let result = await usage.current()

        guard case .values(_, let values, _, _, _, let breakdown) = try XCTUnwrap(result.line) else {
            return XCTFail("expected a values line")
        }
        XCTAssertNil(result.warning)
        XCTAssertEqual(values, [MetricValue(number: 3, kind: .dollars)])
        XCTAssertEqual(breakdown?.models.map(\.model), ["proj_a"])
    }

    func testRejectedKeyWarnsAndNoKeyShowsNothing() async {
        let (rejected, _) = usage { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let rejectedResult = await rejected.current()
        XCTAssertNil(rejectedResult.line)
        XCTAssertEqual(rejectedResult.warning, "API Usage: \(OpenAIAPIAuthError.invalidKey.localizedDescription)")

        let (missing, http) = usage(files: FakeFiles()) { _ in okResponse("{}") }
        let missingResult = await missing.current()
        XCTAssertEqual(missingResult, OpenAIAPIUsage.Result())
        XCTAssertTrue(http.requests.isEmpty)
    }
}

final class OpenAIAPIAuthStoreTests: XCTestCase {
    func testEachCodexCardReadsItsOwnKeyAndIgnoresTheEnvironment() throws {
        let files = FakeFiles()
        let environment = FakeEnvironment(["OPENAI_ADMIN_KEY": "sk-admin-env", "OPENAI_API_KEY": "sk-proj-env"])
        let first = OpenAIAPIAuthStore(cardID: "codex@aaaa0001", files: files, environment: environment)
        let second = OpenAIAPIAuthStore(cardID: "codex@bbbb0002", files: files, environment: environment)

        XCTAssertNil(first.loadAPIKey())
        try first.saveAPIKey("sk-admin-first")

        XCTAssertEqual(first.loadAPIKey()?.apiKey, "sk-admin-first")
        XCTAssertNil(second.loadAPIKey())
        XCTAssertNotNil(files.files["~/.config/hopusage/openai-api/codex@aaaa0001.json"])
    }

    func testDefaultRefreshIntervalIsTwoHours() {
        XCTAssertEqual(APIProviderRefreshSetting.fallback.interval, 2 * 60 * 60)
    }

    func testSettingsArePerCardAndResetTogether() {
        let suite = "apiUsageSettings.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(15, forKey: OpenAIAPIPeriodSetting.key(cardID: "codex@aaaa0001"))
        defaults.set("4h", forKey: APIProviderRefreshSetting.key(cardID: "codex@aaaa0001"))
        defaults.set("keep", forKey: "openusage.other")

        XCTAssertEqual(OpenAIAPIPeriodSetting.key(cardID: "codex@aaaa0001"), "openusage.openaiAPI.periodStartDay.codex@aaaa0001")
        XCTAssertNotEqual(OpenAIAPIPeriodSetting.key(cardID: "codex@aaaa0001"), OpenAIAPIPeriodSetting.key(cardID: "codex@bbbb0002"))

        APIUsageSettings.removeAll(from: defaults)

        XCTAssertNil(defaults.object(forKey: OpenAIAPIPeriodSetting.key(cardID: "codex@aaaa0001")))
        XCTAssertNil(defaults.object(forKey: APIProviderRefreshSetting.key(cardID: "codex@aaaa0001")))
        XCTAssertEqual(defaults.string(forKey: "openusage.other"), "keep")
    }
}

private final class FailSwitch: @unchecked Sendable {
    var on = false
}

private func okResponse(_ json: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
}
