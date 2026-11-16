import Foundation

/// Reads the GitHub Copilot desktop app / `copilot` CLI usage log for the spend tiles and trend.
/// Both write one `assistant_usage_events` row per model request to `~/.copilot/session-store.db`,
/// carrying the model, the token counts, and `total_nano_aiu` — the AI credits GitHub charged for it.
/// Dollars come straight from those credits (one AI credit is $0.01), so nothing is re-priced.
/// Sessions the database never indexed are filled in from their `events.jsonl` logs
/// (`CopilotCLIEventLogScanner`), skipping requests the database already holds. Read-only, no network.
/// The daily window behind Today / Yesterday / Last 30 Days and the trend, plus the current billing
/// period's usage (`This Period`) when a period start is known.
struct CopilotCLIUsageScan: Sendable {
    var window: LogUsageScan
    var period: LogUsageScan?
}

struct CopilotCLIUsageScanner: Sendable {
    static let databasePath = "~/.copilot/session-store.db"
    static let nanoPerCredit = 1_000_000_000.0
    /// GitHub bills AI credits at one cent each.
    static let dollarsPerCredit = 0.01

    var sqlite: SQLiteAccessing
    var databasePath: String
    var eventLog: CopilotCLIEventLogScanner

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePath: String = CopilotCLIUsageScanner.databasePath,
        eventLog: CopilotCLIEventLogScanner = CopilotCLIEventLogScanner()
    ) {
        self.sqlite = sqlite
        self.databasePath = databasePath
        self.eventLog = eventLog
    }

    /// Per-day tokens, dollars, and per-model breakdown for today plus the previous `daysBack` calendar
    /// days, and the same since `periodStart` (the billing period's first instant) when given. `nil`
    /// when neither the database nor any session log has usage (no CLI / app usage yet) or the scan was
    /// cancelled; throws when the database exists but can't be read.
    func scan(
        now: Date, periodStart: Date? = nil, daysBack: Int = UsageHistoryWindow.previousDays
    ) async throws -> CopilotCLIUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let earliest = min(since, periodStart ?? since)
        // `created_at` is ISO-8601 UTC; a day of slack keeps every row of the oldest local day, and
        // the exact bounds are applied below after parsing.
        let cutoff = OpenUsageISO8601.string(from: earliest.addingTimeInterval(-86_400))
        let path = (databasePath as NSString).expandingTildeInPath
        let databaseRows = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoff: cutoff)).map(Self.parseRows)
        guard let events = await eventLog.entries(since: earliest) else { return nil }
        guard databaseRows != nil || !events.isEmpty else { return nil }
        let rows = Self.merge(databaseRows ?? [], events)
        return CopilotCLIUsageScan(
            window: Self.aggregate(rows, since: since),
            period: periodStart.map { Self.aggregate(rows, since: $0) }
        )
    }

    /// The billing period's first instant: one calendar month (UTC) before the Credits reset, which is
    /// when GitHub's monthly allotment restarts. Without a reset date, the start of the current UTC month.
    static func periodStart(resetsAt: Date?, now: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        if let resetsAt, let start = utc.date(byAdding: .month, value: -1, to: resetsAt), start <= now {
            return start
        }
        return utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now
    }

    // MARK: - Parsing (pure)

    struct Row: Hashable {
        var createdAt: Date
        var sessionID: String
        var model: String
        /// Includes cache reads and writes.
        var inputTokens: Int
        /// Includes reasoning.
        var outputTokens: Int
        var nanoCredits: Double

        var tokens: Int { inputTokens + outputTokens }
    }

    /// A request as both sources record it: same session, model, and token counts.
    private struct RequestKey: Hashable {
        var sessionID: String
        var model: String
        var inputTokens: Int
        var outputTokens: Int
    }

    /// Database rows plus every logged request the database doesn't already hold. Matching is by
    /// session, model, and token counts, as a multiset, so two identical requests in one session
    /// still count twice when only one reached the database.
    static func merge(_ rows: [Row], _ events: [CopilotCLIEventLogScanner.Entry]) -> [Row] {
        var unmatched: [RequestKey: Int] = [:]
        for row in rows {
            unmatched[RequestKey(sessionID: row.sessionID, model: row.model, inputTokens: row.inputTokens, outputTokens: row.outputTokens), default: 0] += 1
        }
        var merged = rows
        for event in events {
            let key = RequestKey(sessionID: event.sessionID, model: event.model, inputTokens: event.inputTokens, outputTokens: event.outputTokens)
            if let count = unmatched[key], count > 0 {
                unmatched[key] = count - 1
                continue
            }
            merged.append(Row(
                createdAt: event.timestamp, sessionID: event.sessionID, model: event.model,
                inputTokens: event.inputTokens, outputTokens: event.outputTokens, nanoCredits: event.nanoCredits
            ))
        }
        return merged
    }

    static func dataSQL(cutoff: String) -> String {
        """
        SELECT json_group_array(json_array(
                 created_at,
                 COALESCE(input_tokens,0),
                 COALESCE(output_tokens,0),
                 COALESCE(total_nano_aiu,0),
                 model,
                 session_id))
        FROM assistant_usage_events
        WHERE created_at >= '\(cutoff.replacingOccurrences(of: "'", with: ""))';
        """
    }

    /// Parse the `[created_at, input, output, nano_aiu, model, session_id]` rows, skipping any with an
    /// unreadable timestamp.
    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        return parsed.compactMap { element in
            guard let entry = element as? [Any], entry.count >= 6,
                  let raw = entry[0] as? String,
                  let date = parseDate(raw)
            else { return nil }
            return Row(
                createdAt: date,
                sessionID: (entry[5] as? String) ?? "",
                model: (entry[4] as? String) ?? "",
                inputTokens: count(entry[1]),
                outputTokens: count(entry[2]),
                nanoCredits: max(ProviderParse.number(entry[3]) ?? 0, 0)
            )
        }
    }

    static func aggregate(_ rows: [Row], since: Date) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for row in rows where row.createdAt >= since {
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: row.createdAt),
                tokens: row.tokens,
                cost: row.nanoCredits / nanoPerCredit * dollarsPerCredit,
                model: row.model
            )
        }
        return accumulator.build()
    }

    /// Clamped before the Int conversion so a corrupt, absurdly large count can't trap.
    private static func count(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
    }

    /// `created_at` is ISO-8601 (`2026-11-16T13:02:26.520Z`); SQLite's own default is
    /// `2026-11-16 13:02:26` (UTC), accepted too.
    private static func parseDate(_ raw: String) -> Date? {
        if let date = OpenUsageISO8601.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
    }
}
