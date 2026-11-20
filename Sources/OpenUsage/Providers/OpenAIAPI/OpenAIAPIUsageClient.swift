import Foundation

/// Fork: the OpenAI organization Costs, Usage, and Projects endpoints. All three need an Admin key and
/// page through results; each fetch follows the cursor to the end (bounded by `maxPages`).
struct OpenAIAPIUsageClient: Sendable {
    static let baseURL = "https://api.openai.com/v1/organization"
    /// A period is at most 31 daily buckets per project, so a handful of pages covers it; the cap only
    /// stops a misbehaving cursor from looping forever.
    static let maxPages = 20

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Daily cost buckets since `start`, grouped by project.
    func fetchCosts(since start: Date, apiKey: String) async throws -> [[String: Any]] {
        try await fetchBuckets(path: "costs", since: start, limit: 180, apiKey: apiKey)
    }

    /// Daily completions token buckets since `start`, grouped by project.
    func fetchCompletionsUsage(since start: Date, apiKey: String) async throws -> [[String: Any]] {
        try await fetchBuckets(path: "usage/completions", since: start, limit: 31, apiKey: apiKey)
    }

    /// Project id → name, archived projects included so older spend still gets a name.
    func fetchProjectNames(apiKey: String) async throws -> [String: String] {
        var names: [String: String] = [:]
        var after: String?
        for _ in 0..<Self.maxPages {
            var query = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "include_archived", value: "true")]
            if let after { query.append(URLQueryItem(name: "after", value: after)) }
            let page = try await get(path: "projects", query: query, apiKey: apiKey)
            guard let parsed = OpenAIAPIUsageMapper.projectsPage(page) else { throw OpenAIAPIUsageError.invalidResponse }
            names.merge(parsed.names) { _, new in new }
            guard parsed.hasMore, let lastID = parsed.lastID else { return names }
            after = lastID
        }
        return names
    }

    private func fetchBuckets(path: String, since start: Date, limit: Int, apiKey: String) async throws -> [[String: Any]] {
        var buckets: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            var query = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by", value: "project_id"),
                URLQueryItem(name: "limit", value: String(limit))
            ]
            if let cursor { query.append(URLQueryItem(name: "page", value: cursor)) }
            let body = try await get(path: path, query: query, apiKey: apiKey)
            guard let page = OpenAIAPIUsageMapper.bucketPage(body) else { throw OpenAIAPIUsageError.invalidResponse }
            buckets += page.buckets
            guard let next = page.nextPage else { return buckets }
            cursor = next
        }
        return buckets
    }

    private func get(path: String, query: [URLQueryItem], apiKey: String) async throws -> Data {
        guard var components = URLComponents(string: "\(Self.baseURL)/\(path)") else {
            throw OpenAIAPIUsageError.invalidResponse
        }
        components.queryItems = query
        guard let url = components.url else { throw OpenAIAPIUsageError.invalidResponse }

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET",
                url: url,
                headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
                timeout: 20
            ))
        } catch {
            throw OpenAIAPIUsageError.connectionFailed
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw OpenAIAPIAuthError.invalidKey }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIAPIUsageError.requestFailed(response.statusCode)
        }
        return response.body
    }
}

enum OpenAIAPIUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach OpenAI. Check your connection."
        case .invalidResponse:
            return "OpenAI usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "OpenAI request failed (HTTP \(status))."
        }
    }
}
