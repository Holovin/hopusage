import Foundation

/// Fork: the API Usage row of one Codex card — the OpenAI organization's billed spend for the current
/// period, with a per-project breakdown, read with that card's Admin key. Codex refreshes every few
/// minutes, but these numbers are daily and delayed, so the row is fetched at most once per the card's
/// `APIProviderRefreshSetting` interval and reused in between. A new key or another period start fetches
/// right away. Failures are logged and reported as a warning on the Codex card; they never fail Codex.
@MainActor
final class OpenAIAPIUsage {
    /// What the Codex snapshot adds: the row (nil without a key or before the first success) and a
    /// warning when the last fetch failed.
    struct Result: Equatable {
        var line: MetricLine?
        var warning: String?
    }

    /// Project names rarely change; refetch them at most once a day.
    static let projectNamesTTL: TimeInterval = 24 * 60 * 60

    let authStore: OpenAIAPIAuthStore
    let usageClient: OpenAIAPIUsageClient
    let periodStartDay: @Sendable () -> Int
    let refreshInterval: @Sendable () -> TimeInterval
    let now: @Sendable () -> Date
    private let logTag: String

    private struct Fetch {
        var apiKey: String
        var periodStart: Date
        var at: Date
        var line: MetricLine?
        var warning: String?
    }

    private var lastFetch: Fetch?
    private var projectNames: (names: [String: String], fetchedAt: Date, apiKey: String)?

    init(
        cardID: String,
        authStore: OpenAIAPIAuthStore? = nil,
        usageClient: OpenAIAPIUsageClient = OpenAIAPIUsageClient(),
        periodStartDay: (@Sendable () -> Int)? = nil,
        refreshInterval: (@Sendable () -> TimeInterval)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore ?? OpenAIAPIAuthStore(cardID: cardID)
        self.usageClient = usageClient
        self.periodStartDay = periodStartDay ?? { OpenAIAPIPeriodSetting.current(cardID: cardID) }
        self.refreshInterval = refreshInterval ?? { APIProviderRefreshSetting.current(cardID: cardID).interval }
        self.now = now
        logTag = LogTag.plugin(cardID)
    }

    /// A row source with no key store behind it: it never reads a saved key, so it never calls OpenAI.
    static func inert(cardID: String) -> OpenAIAPIUsage {
        OpenAIAPIUsage(cardID: cardID, authStore: OpenAIAPIAuthStore(cardID: cardID, files: NoTextFiles()))
    }

    /// Forget the last fetch, so the next refresh asks OpenAI again (after the key changed).
    func invalidate() {
        lastFetch = nil
        projectNames = nil
    }

    func current() async -> Result {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            lastFetch = nil
            return Result()
        }
        let start = OpenAIAPIPeriod.start(day: periodStartDay(), now: now())
        if let last = lastFetch, last.apiKey == auth.apiKey, last.periodStart == start,
           now().timeIntervalSince(last.at) < refreshInterval() {
            return Result(line: last.line, warning: last.warning)
        }

        let fetch: Fetch
        do {
            let line = try await fetchLine(apiKey: auth.apiKey, periodStart: start)
            fetch = Fetch(apiKey: auth.apiKey, periodStart: start, at: now(), line: line)
        } catch {
            AppLog.error(logTag, "API usage refresh failed: \(error.localizedDescription)")
            // Keep showing the last good row for the same key and period, flagged by the warning.
            let previous = lastFetch.flatMap { $0.apiKey == auth.apiKey && $0.periodStart == start ? $0.line : nil }
            fetch = Fetch(apiKey: auth.apiKey, periodStart: start, at: now(), line: previous,
                          warning: "API Usage: \(error.localizedDescription)")
        }
        lastFetch = fetch
        return Result(line: fetch.line, warning: fetch.warning)
    }

    /// Costs are the row itself, so their failure fails the fetch. Tokens and project names only enrich
    /// it: without them the row shows dollars only, or project ids instead of names.
    private func fetchLine(apiKey: String, periodStart: Date) async throws -> MetricLine {
        let costs = OpenAIAPIUsageMapper.costsByProject(try await usageClient.fetchCosts(since: periodStart, apiKey: apiKey))

        var tokens: [String: Int] = [:]
        var includesTokens = true
        do {
            tokens = OpenAIAPIUsageMapper.tokensByProject(
                try await usageClient.fetchCompletionsUsage(since: periodStart, apiKey: apiKey))
        } catch {
            includesTokens = false
            AppLog.warn(logTag, "API usage tokens unavailable, showing dollars only: \(error.localizedDescription)")
        }

        let names = await loadProjectNames(apiKey: apiKey)
        let projects = OpenAIAPIUsageMapper.projects(costs: costs, tokens: tokens, names: names)
        return OpenAIAPIUsageMapper.usageLine(projects: projects, includesTokens: includesTokens, periodStart: periodStart)
    }

    private func loadProjectNames(apiKey: String) async -> [String: String] {
        if let cached = projectNames, cached.apiKey == apiKey,
           now().timeIntervalSince(cached.fetchedAt) < Self.projectNamesTTL {
            return cached.names
        }
        do {
            let names = try await usageClient.fetchProjectNames(apiKey: apiKey)
            projectNames = (names, now(), apiKey)
            return names
        } catch {
            AppLog.warn(logTag, "API usage project names unavailable, showing ids: \(error.localizedDescription)")
            return projectNames?.apiKey == apiKey ? projectNames?.names ?? [:] : [:]
        }
    }
}

/// A file store that holds nothing and accepts nothing — the key store of an inert `OpenAIAPIUsage`.
private struct NoTextFiles: TextFileAccessing {
    struct Unavailable: Error {}

    func exists(_ path: String) -> Bool { false }
    func readTextIfPresent(_ path: String) throws -> String? { nil }
    func readText(_ path: String) throws -> String { throw Unavailable() }
    func writeText(_ path: String, _ text: String) throws { throw Unavailable() }
    func remove(_ path: String) throws {}
}
