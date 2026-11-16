import Foundation

/// Reads per-request usage from the Copilot CLI / desktop app session logs,
/// `~/.copilot/session-state/<session>/events.jsonl`. Some sessions — e.g. ones run by certain CLI
/// builds — never reach the `session-store.db` index, but their logs still carry one
/// `session.usage_record` event per model request with the model, tokens, and the AI credits charged.
/// `CopilotCLIUsageScanner` merges these with the database rows, dropping the requests both hold.
///
/// Parsing is incremental and cached across refreshes (and launches) through the shared
/// `IncrementalJSONLScanner`, so only logs that changed are read again.
struct CopilotCLIEventLogScanner: Sendable {
    static let sessionStatePath = "~/.copilot/session-state"

    /// One model request from a `session.usage_record` event.
    struct Entry: Codable, Sendable, Hashable {
        /// The session the log belongs to (`session.start`), the same id the database stores — also for
        /// subagent requests logged in their parent's file.
        var sessionID: String
        var usageID: String?
        var timestamp: Date
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var nanoCredits: Double
    }

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("copilot-cli"),
        persistence: JSONLScanCachePersistence(namespace: "copilot-cli", schemaVersion: 2)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    private let scanner: IncrementalJSONLScanner<Entry>
    var directoryPath: String

    init(
        directoryPath: String = CopilotCLIEventLogScanner.sessionStatePath,
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.directoryPath = directoryPath
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// Usage records from logs modified since `since`, de-duplicated by the request's usage id. `nil`
    /// when the scan was cancelled; an absent directory yields `[]`.
    func entries(since: Date) async -> [Entry]? {
        let directory = URL(fileURLWithPath: (directoryPath as NSString).expandingTildeInPath, isDirectory: true)
        let identity = directory.resolvingSymlinksInPath().standardizedFileURL.path
        // Only each session's own log; checkpoints and research folders hold no usage.
        let files = JSONLScanning.jsonlFiles(under: directory).filter { file in
            let url = URL(fileURLWithPath: file.path)
            return url.lastPathComponent == "events.jsonl"
                && url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                    == directory.standardizedFileURL.path
        }
        // The reader hands the parser a file in batches, so the session id from the file's first
        // `session.start` is carried across batches as the per-file state.
        guard let entries = await scanner.items(
            from: files, since: since, cacheIdentity: identity,
            initialState: String?.none,
            parse: { data, sessionID in Self.parseBatch(data, sessionID: &sessionID) }
        ), !Task.isCancelled
        else { return nil }
        return Self.dedup(entries)
    }

    /// Keep the first copy of each usage id (a forked session can replay its parent's records).
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            guard let id = entry.usageID else { return true }
            return seen.insert(id).inserted
        }
    }

    // MARK: - Parsing (pure)

    /// A whole file in one go (tests and small logs).
    static func parseFile(_ data: Data) -> [Entry] {
        var sessionID: String?
        return parseBatch(data, sessionID: &sessionID)
    }

    /// One batch of complete lines. `sessionID` is set by the file's first `session.start` and applies
    /// to every later batch of the same file.
    static func parseBatch(_ data: Data, sessionID: inout String?) -> [Entry] {
        let startMarker = Data("\"session.start\"".utf8)
        let usageMarker = Data("\"session.usage_record\"".utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if sessionID == nil, line.range(of: startMarker) != nil,
               let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               object["type"] as? String == "session.start" {
                sessionID = ((object["data"] as? [String: Any])?["sessionId"] as? String)?.nilIfEmpty
                continue
            }
            guard line.range(of: usageMarker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let entry = usageEntry(object, sessionID: sessionID)
            else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func usageEntry(_ object: [String: Any], sessionID: String?) -> Entry? {
        guard object["type"] as? String == "session.usage_record",
              let usage = (object["data"] as? [String: Any])?["usage"] as? [String: Any],
              let rawTimestamp = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: rawTimestamp)
        else { return nil }
        let accounting = usage["accounting"] as? [String: Any]
        guard let session = sessionID ?? (accounting?["sourceSessionId"] as? String)?.nilIfEmpty else { return nil }
        let nano = ProviderParse.number((usage["copilotUsage"] as? [String: Any])?["totalNanoAiu"]) ?? 0
        return Entry(
            sessionID: session,
            usageID: (accounting?["usageId"] as? String)?.nilIfEmpty,
            timestamp: timestamp,
            model: (usage["model"] as? String) ?? "",
            inputTokens: count(usage["inputTokens"]),
            outputTokens: count(usage["outputTokens"]),
            nanoCredits: max(nano, 0)
        )
    }

    /// Clamped before the Int conversion so a corrupt, absurdly large count can't trap.
    private static func count(_ value: Any?) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
    }
}
