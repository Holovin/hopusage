import XCTest
@testable import OpenUsage

final class CopilotCLIUsageScannerTests: XCTestCase {
    /// The generated SQL against a real `session-store.db` table shaped like the desktop app's, merged
    /// with a session log holding one request the database also has and one it never indexed.
    func testRealDatabaseMergedWithSessionLogs() async throws {
        let dir = try makeTempDir()
        let path = dir.appendingPathComponent("session-store.db").path
        let sqlite = SQLiteCLIAccessor()
        try sqlite.execute(path: path, sql: """
            CREATE TABLE assistant_usage_events (
              id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, model TEXT NOT NULL,
              input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
              reasoning_tokens INTEGER, total_nano_aiu INTEGER, created_at TEXT DEFAULT (datetime('now')));
            """)

        let now = Date()
        let today = OpenUsageISO8601.string(from: now)
        let yesterday = OpenUsageISO8601.string(from: now.addingTimeInterval(-86_400))
        let old = OpenUsageISO8601.string(from: now.addingTimeInterval(-40 * 86_400))
        try sqlite.execute(path: path, sql: """
            INSERT INTO assistant_usage_events (session_id, model, input_tokens, output_tokens, cache_read_tokens, reasoning_tokens, total_nano_aiu, created_at) VALUES
              ('a', 'claude-opus-5.5', 1000, 200, 900, 50, 2500000000, '\(today)'),
              ('a', 'gpt-6.1-terra', 300, NULL, 0, 0, 500000000, '\(today)'),
              ('b', 'gemini-4-argon', 10, 5, 0, 0, NULL, '\(yesterday)'),
              ('c', 'gpt-6-astra', 999, 999, 0, 0, 9000000000, '\(old)');
            """)

        // Session "a" logs its opus request (already in the database) and a Fable request it doesn't.
        let sessionState = dir.appendingPathComponent("session-state", isDirectory: true)
        let sessionDir = sessionState.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try [
            Self.startLine(session: "a"),
            Self.usageLine(model: "claude-opus-5.5", input: 1000, output: 200, nano: 2_500_000_000, usageID: "u1", at: today),
            Self.usageLine(model: "claude-fable-5.1", input: 70_026, output: 293, nano: 88_996_500_000, usageID: "u2", at: today)
        ].joined(separator: "\n").write(to: sessionDir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let scanner = CopilotCLIUsageScanner(
            sqlite: sqlite, databasePath: path,
            eventLog: CopilotCLIEventLogScanner(directoryPath: sessionState.path, incrementalScanner: IncrementalJSONLScanner())
        )
        // A period that began a minute ago holds today's rows (stamped `now`) but not yesterday's.
        let result = try await scanner.scan(now: now, periodStart: now.addingTimeInterval(-60))
        let scan = try XCTUnwrap(result?.window)
        let period = try XCTUnwrap(result?.period)
        XCTAssertEqual(period.series.daily.map(\.totalTokens).reduce(0, +), 1500 + 70_319)
        let todayKey = DailyUsageAccumulator.dayKey(from: now)
        let yesterdayKey = DailyUsageAccumulator.dayKey(from: now.addingTimeInterval(-86_400))

        // Today: 3 database credits + 88.9965 logged Fable credits; the 40-day-old row is outside the window.
        XCTAssertEqual(scan.series.daily.count, 2)
        let todayEntry = try XCTUnwrap(scan.series.daily.first { $0.date == todayKey })
        XCTAssertEqual(todayEntry.totalTokens, 1500 + 70_319)
        XCTAssertEqual(try XCTUnwrap(todayEntry.costUSD), 0.919965, accuracy: 0.000001)
        let yesterdayEntry = try XCTUnwrap(scan.series.daily.first { $0.date == yesterdayKey })
        XCTAssertEqual(yesterdayEntry.totalTokens, 15)
        XCTAssertEqual(yesterdayEntry.costUSD, 0)

        let todayModels = try XCTUnwrap(scan.modelUsage?.daily.first { $0.date == todayKey }).models
        XCTAssertEqual(Set(todayModels.map(\.model)), ["claude-opus-5.5", "gpt-6.1-terra", "claude-fable-5.1"])
        let opus = try XCTUnwrap(todayModels.first { $0.model == "claude-opus-5.5" })
        XCTAssertEqual(opus.totalTokens, 1200)
        XCTAssertEqual(try XCTUnwrap(opus.costUSD), 0.025, accuracy: 0.000001)
    }

    func testNoDatabaseAndNoLogsIsNil() async throws {
        let dir = try makeTempDir()
        let scanner = CopilotCLIUsageScanner(
            sqlite: SQLiteCLIAccessor(),
            databasePath: dir.appendingPathComponent("missing.db").path,
            eventLog: CopilotCLIEventLogScanner(directoryPath: dir.appendingPathComponent("session-state").path, incrementalScanner: IncrementalJSONLScanner())
        )
        let scan = try await scanner.scan(now: Date())
        XCTAssertNil(scan)
    }

    func testParseRowsAcceptsSQLiteDefaultTimestampAndSkipsBadRows() {
        let rows = CopilotCLIUsageScanner.parseRows(#"[["2026-11-16 13:02:26", 7, 3, 1e9, "grok-4.7", "s1"], ["garbage", 5, 0, 0, "x", "s"], [null, 1, 1, 1, "y", "s"]]"#)

        XCTAssertEqual(rows, [CopilotCLIUsageScanner.Row(
            createdAt: Date(timeIntervalSince1970: 1_794_834_146), sessionID: "s1", model: "grok-4.7",
            inputTokens: 7, outputTokens: 3, nanoCredits: 1e9
        )])
    }

    func testPeriodStartIsOneUTCMonthBeforeTheCreditsReset() {
        let iso = { (s: String) in OpenUsageISO8601.date(from: s)! }
        let now = iso("2026-11-16T14:00:00.000Z")

        XCTAssertEqual(CopilotCLIUsageScanner.periodStart(resetsAt: iso("2026-12-01T00:00:00.000Z"), now: now), iso("2026-11-01T00:00:00.000Z"))
        // No reset date: the current UTC month.
        XCTAssertEqual(CopilotCLIUsageScanner.periodStart(resetsAt: nil, now: now), iso("2026-11-01T00:00:00.000Z"))
        // A reset more than a month out can't start the period in the future.
        XCTAssertEqual(CopilotCLIUsageScanner.periodStart(resetsAt: iso("2027-01-01T00:00:00.000Z"), now: now), iso("2026-11-01T00:00:00.000Z"))
    }

    func testMergeSkipsRequestsTheDatabaseHoldsAsAMultiset() {
        let date = Date(timeIntervalSince1970: 1_794_834_146)
        let row = CopilotCLIUsageScanner.Row(createdAt: date, sessionID: "s", model: "m", inputTokens: 10, outputTokens: 2, nanoCredits: 1)
        func event(_ id: String, session: String = "s") -> CopilotCLIEventLogScanner.Entry {
            .init(sessionID: session, usageID: id, timestamp: date, model: "m", inputTokens: 10, outputTokens: 2, nanoCredits: 1)
        }

        // Two identical logged requests, one in the database: only the second is added. A same-shaped
        // request in another session is a different request.
        let merged = CopilotCLIUsageScanner.merge([row], [event("1"), event("2"), event("3", session: "other")])

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.filter { $0.sessionID == "s" }.count, 2)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    static func startLine(session: String) -> String {
        #"{"type":"session.start","data":{"sessionId":"\#(session)","producer":"copilot-agent"},"id":"e0","timestamp":"2026-11-02T17:47:08.133Z"}"#
    }

    static func usageLine(model: String, input: Int, output: Int, nano: Int, usageID: String, at timestamp: String, agentSession: String? = nil) -> String {
        let source = agentSession.map { #""sourceSessionId":"\#($0)","# } ?? ""
        return #"{"type":"session.usage_record","data":{"usage":{"model":"\#(model)","inputTokens":\#(input),"outputTokens":\#(output),"accounting":{\#(source)"usageId":"\#(usageID)"},"copilotUsage":{"totalNanoAiu":\#(nano)}}},"id":"e\#(usageID)","timestamp":"\#(timestamp)"}"#
    }
}

final class CopilotCLIEventLogScannerTests: XCTestCase {
    func testParsesUsageRecordsUnderTheFileSession() {
        let lines = [
            CopilotCLIUsageScannerTests.startLine(session: "parent"),
            #"{"type":"assistant.message","data":{"content":"session.usage_record"},"id":"x","timestamp":"2026-11-02T17:50:00.000Z"}"#,
            // A subagent request logged in its parent's file belongs to the parent, as in the database.
            CopilotCLIUsageScannerTests.usageLine(model: "claude-fable-5.1", input: 70_026, output: 293, nano: 88_996_500_000, usageID: "u1", at: "2026-11-02T17:53:30.198Z", agentSession: "child"),
            "not json"
        ]

        let entries = CopilotCLIEventLogScanner.parseFile(Data(lines.joined(separator: "\n").utf8))

        XCTAssertEqual(entries, [CopilotCLIEventLogScanner.Entry(
            sessionID: "parent", usageID: "u1", timestamp: OpenUsageISO8601.date(from: "2026-11-02T17:53:30.198Z")!,
            model: "claude-fable-5.1", inputTokens: 70_026, outputTokens: 293, nanoCredits: 88_996_500_000
        )])
    }

    func testFallsBackToSourceSessionWithoutStartEvent() {
        let line = CopilotCLIUsageScannerTests.usageLine(model: "m", input: 1, output: 1, nano: 1, usageID: "u", at: "2026-11-02T17:53:30.198Z", agentSession: "src")

        XCTAssertEqual(CopilotCLIEventLogScanner.parseFile(Data(line.utf8)).map(\.sessionID), ["src"])
    }

    func testDedupKeepsFirstCopyOfEachUsageID() {
        let date = Date()
        let entry = CopilotCLIEventLogScanner.Entry(sessionID: "s", usageID: "u", timestamp: date, model: "m", inputTokens: 1, outputTokens: 1, nanoCredits: 1)
        var other = entry
        other.usageID = nil

        XCTAssertEqual(CopilotCLIEventLogScanner.dedup([entry, entry, other, other]).count, 3)
    }
}

extension CopilotCLIEventLogScannerTests {
    /// The streaming reader delivers a file in batches; records after the first batch still belong to
    /// the file's session, not to a subagent's `sourceSessionId` (regression: they were double-counted).
    func testSessionCarriesAcrossBatches() {
        var sessionID: String?
        _ = CopilotCLIEventLogScanner.parseBatch(Data(CopilotCLIUsageScannerTests.startLine(session: "parent").utf8), sessionID: &sessionID)
        let later = CopilotCLIUsageScannerTests.usageLine(model: "m", input: 1, output: 1, nano: 1, usageID: "u", at: "2026-11-02T17:53:30.198Z", agentSession: "child")

        XCTAssertEqual(CopilotCLIEventLogScanner.parseBatch(Data(later.utf8), sessionID: &sessionID).map(\.sessionID), ["parent"])
    }

    /// A real multi-batch read through the shared scanner: a log far larger than one batch.
    func testLargeLogKeepsFileSessionThroughTheScanner() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = dir.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let filler = #"{"type":"assistant.message","data":{"content":""# + String(repeating: "x", count: 4_000) + #""},"id":"f","timestamp":"2026-11-02T17:50:00.000Z"}"#
        let now = OpenUsageISO8601.string(from: Date())
        let lines = [CopilotCLIUsageScannerTests.startLine(session: "parent")]
            + Array(repeating: filler, count: 2_000)
            + [CopilotCLIUsageScannerTests.usageLine(model: "m", input: 1, output: 1, nano: 1, usageID: "u", at: now, agentSession: "child")]
        try lines.joined(separator: "\n").write(to: session.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let entries = await CopilotCLIEventLogScanner(directoryPath: dir.path, incrementalScanner: IncrementalJSONLScanner())
            .entries(since: Date().addingTimeInterval(-86_400))

        XCTAssertEqual(entries?.map(\.sessionID), ["parent"])
    }
}

final class CopilotCLIPeriodLineTests: XCTestCase {
    func testPeriodRowSumsTheWholePeriodWithModelBreakdown() {
        let series = DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-11-02", totalTokens: 1_000, costUSD: 50),
            DailyUsageEntry(date: "2026-11-16", totalTokens: 500, costUSD: 3)
        ])
        let models = ModelUsageSeries(daily: [
            DailyModelUsageEntry(date: "2026-11-02", models: [ModelUsageEntry(model: "claude-fable-5.1", totalTokens: 1_000, costUSD: 50)]),
            DailyModelUsageEntry(date: "2026-11-16", models: [ModelUsageEntry(model: "gpt-6.1-terra", totalTokens: 500, costUSD: 3)])
        ])
        var lines: [MetricLine] = []

        SpendTileMapper.appendPeriodUsage(label: "This Period", series, to: &lines, estimated: false, modelUsage: models, modelSourceNote: "note")

        guard case .values(let label, let values, _, _, _, let breakdown) = lines.first else { return XCTFail("expected a values row") }
        XCTAssertEqual(label, "This Period")
        XCTAssertEqual(values, [
            MetricValue(number: 53, kind: .dollars, estimated: false),
            MetricValue(number: 1_500, kind: .count, label: "tokens")
        ])
        XCTAssertEqual(breakdown?.models.map(\.model), ["claude-fable-5.1", "gpt-6.1-terra"])
    }

    func testIdlePeriodAppendsNothing() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendPeriodUsage(label: "This Period", DailyUsageSeries(daily: []), to: &lines)
        XCTAssertTrue(lines.isEmpty)
    }
}
