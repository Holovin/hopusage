import Foundation

/// Fork: turns the OpenAI organization Costs / Usage / Projects payloads into the Codex card's API Usage
/// row and its per-project hover breakdown.
enum OpenAIAPIUsageMapper {
    static let label = "API Usage"
    /// Projects shown by name in the breakdown before the rest fold into "Other", like the model lists.
    static let namedProjectCap = 5

    struct BucketPage {
        var buckets: [[String: Any]]
        var nextPage: String?
    }

    struct ProjectsPage {
        var names: [String: String]
        var hasMore: Bool
        var lastID: String?
    }

    /// One project's totals for the period. `projectID` is empty for spend OpenAI reports without one.
    struct ProjectUsage: Equatable {
        var projectID: String
        var name: String
        var costUSD: Double
        var tokens: Int
    }

    static func bucketPage(_ body: Data) -> BucketPage? {
        guard let object = ProviderParse.jsonObject(body), let data = object["data"] as? [[String: Any]] else {
            return nil
        }
        let next = (object["has_more"] as? Bool) == true ? object["next_page"] as? String : nil
        return BucketPage(buckets: data, nextPage: next?.isEmpty == false ? next : nil)
    }

    static func projectsPage(_ body: Data) -> ProjectsPage? {
        guard let object = ProviderParse.jsonObject(body), let data = object["data"] as? [[String: Any]] else {
            return nil
        }
        var names: [String: String] = [:]
        for project in data {
            guard let id = project["id"] as? String else { continue }
            let name = (project["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            names[id] = name?.isEmpty == false ? name : id
        }
        return ProjectsPage(names: names, hasMore: (object["has_more"] as? Bool) == true,
                            lastID: object["last_id"] as? String)
    }

    /// Dollars per project id across every cost bucket.
    static func costsByProject(_ buckets: [[String: Any]]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for result in results(buckets) {
            let amount = result["amount"] as? [String: Any]
            guard let value = ProviderParse.number(amount?["value"]) else { continue }
            totals[projectID(result), default: 0] += value
        }
        return totals
    }

    /// Input + output tokens per project id across every completions usage bucket.
    static func tokensByProject(_ buckets: [[String: Any]]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for result in results(buckets) {
            let input = ProviderParse.number(result["input_tokens"]) ?? 0
            let output = ProviderParse.number(result["output_tokens"]) ?? 0
            totals[projectID(result), default: 0] += Int(max(0, input + output))
        }
        return totals
    }

    /// Projects ranked by cost (then tokens), with names resolved from `names` (falling back to the id).
    static func projects(costs: [String: Double], tokens: [String: Int], names: [String: String]) -> [ProjectUsage] {
        Set(costs.keys).union(tokens.keys)
            .map { id in
                ProjectUsage(
                    projectID: id,
                    name: id.isEmpty ? ModelUsageEntry.unattributedModelName : names[id] ?? id,
                    costUSD: costs[id] ?? 0,
                    tokens: tokens[id] ?? 0
                )
            }
            .filter { $0.costUSD != 0 || $0.tokens != 0 }
            .sorted { lhs, rhs in
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                return lhs.name < rhs.name
            }
    }

    /// The API Usage row: billed dollars, plus tokens when the usage endpoint answered, with the
    /// per-project breakdown on hover. Dollars come from OpenAI's own billing, so they aren't estimated.
    static func usageLine(projects: [ProjectUsage], includesTokens: Bool, periodStart: Date) -> MetricLine {
        let totalCost = max(0, projects.reduce(0) { $0 + $1.costUSD })
        let totalTokens = projects.reduce(0) { $0 + $1.tokens }

        var values = [MetricValue(number: totalCost, kind: .dollars)]
        if includesTokens {
            values.append(MetricValue(number: Double(totalTokens), kind: .count, label: "tokens"))
        }

        var entries = projects.prefix(namedProjectCap).map {
            ModelUsageEntry(model: $0.name, totalTokens: $0.tokens, costUSD: $0.costUSD)
        }
        let rest = projects.dropFirst(namedProjectCap)
        if !rest.isEmpty {
            entries.append(ModelUsageEntry(
                model: ModelUsageEntry.otherModelName,
                totalTokens: rest.reduce(0) { $0 + $1.tokens },
                costUSD: rest.reduce(0) { $0 + $1.costUSD },
                variants: rest.map { ModelUsageVariant(model: $0.name, totalTokens: $0.tokens, costUSD: $0.costUSD) }
            ))
        }
        let breakdown = entries.isEmpty ? nil : ModelUsageBreakdown(
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            models: entries,
            sourceNote: "From the OpenAI Costs API since \(periodLabel(periodStart))"
        )
        return .values(label: label, values: values, modelBreakdown: breakdown)
    }

    private static func results(_ buckets: [[String: Any]]) -> [[String: Any]] {
        buckets.flatMap { ($0["results"] as? [[String: Any]]) ?? [] }
    }

    private static func projectID(_ result: [String: Any]) -> String {
        (result["project_id"] as? String) ?? ""
    }

    private static func periodLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}

/// Fork: where the current OpenAI API usage period began — midnight on the chosen day of this month, or
/// of last month while that day is still ahead. A month without the day starts on its last day.
enum OpenAIAPIPeriod {
    static func start(day: Int, now: Date, calendar: Calendar = .current) -> Date {
        let day = min(max(day, 1), 31)
        let thisMonth = calendar.dateComponents([.year, .month], from: now)
        if let start = anchor(day: day, month: thisMonth, calendar: calendar), start <= now {
            return start
        }
        guard let firstOfMonth = calendar.date(from: thisMonth),
              let previous = calendar.date(byAdding: .month, value: -1, to: firstOfMonth),
              let start = anchor(day: day, month: calendar.dateComponents([.year, .month], from: previous), calendar: calendar)
        else { return calendar.startOfDay(for: now) }
        return start
    }

    private static func anchor(day: Int, month: DateComponents, calendar: Calendar) -> Date? {
        guard let firstOfMonth = calendar.date(from: month),
              let days = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return nil }
        var components = month
        components.day = min(day, days.count)
        return calendar.date(from: components).map(calendar.startOfDay(for:))
    }
}
