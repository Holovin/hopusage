import Foundation

/// A typed read of the usage body's `cedar_ember` block (Anthropic's one-off usage-limit reset grants).
/// Both the Rate Limit Resets row and the claim read this one model.
struct ClaudeResetGrantStatus: Equatable, Sendable {
    struct Grant: Equatable, Sendable {
        var id: String
        var resetsLeft: Int
        var endsAt: Date?
        var clears: [String]
        var type: String?
        var givesBackWeekly = false

        /// What the grant refills, decided as Claude Code decides it: a grant that gives back the week's
        /// Fable use is a Fable reset whatever its type says, then the type, then the windows it clears.
        var name: String {
            if givesBackWeekly { return "Fable" }
            switch type {
            case "session": return "Session"
            case "weekly": return "Weekly"
            case "full": return "Full Reset"
            default: break
            }
            let session = clears.contains("five_hour")
            let other = clears.contains { $0 != "five_hour" }
            if session && !other { return "Session" }
            if other && !session { return "Weekly" }
            return "Full Reset"
        }
    }

    var eligible: Bool
    var grants: [Grant]
    var nextGrantID: String?

    /// `nil` for a missing or `null` block (plans outside the program) and for a block with a malformed
    /// grant: like Claude Code, a block we can't fully read is rejected rather than half-trusted.
    static func parse(_ value: Any?) -> ClaudeResetGrantStatus? {
        guard let object = value as? [String: Any] else { return nil }
        var grants: [Grant] = []
        for entry in object["grants"] as? [Any] ?? [] {
            guard let grant = entry as? [String: Any],
                  let id = grant["id"] as? String, !id.isEmpty,
                  let left = ProviderParse.number(grant["resets_left"]).flatMap({ ProviderParse.int($0.rounded(.down)) })
            else {
                AppLog.warn(LogTag.plugin("claude"), "reset grants block has a malformed grant; ignoring the block")
                return nil
            }
            grants.append(Grant(
                id: id,
                resetsLeft: max(0, left),
                endsAt: ClaudeUsageMapper.resetDate(grant["ends_at"]),
                clears: grant["clears"] as? [String] ?? [],
                type: grant["type"] as? String,
                givesBackWeekly: grant["gives_back_weekly"] as? Bool == true
            ))
        }
        let nextGrantID = (object["next_grant_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeResetGrantStatus(
            eligible: object["eligible"] as? Bool == true,
            grants: grants,
            nextGrantID: nextGrantID
        )
    }

    /// The grant a claim would spend: Anthropic names it in `next_grant_id`, and an ineligible account
    /// can't claim at all.
    var claimableGrantID: String? {
        guard eligible, let nextGrantID, grants.contains(where: { $0.id == nextGrantID && $0.resetsLeft > 0 }) else {
            return nil
        }
        return nextGrantID
    }

    /// The confirm card's line, built from what the next grant refills.
    var confirmDetail: String? {
        guard let id = claimableGrantID, let grant = grants.first(where: { $0.id == id }) else { return nil }
        let names = grant.clears.compactMap { window -> String? in
            switch window {
            case "five_hour": "session"
            case "seven_day": "weekly"
            default: nil
            }
        }
        guard !names.isEmpty else { return nil }
        return "Refills your \(names.joined(separator: " and ")) limits now. This can't be undone."
    }

    /// The grants whose resets the row counts: eligible, with a reset left, and not yet expired.
    func availableGrants(now: Date) -> [Grant] {
        guard eligible else { return [] }
        return grants.filter { grant in
            grant.resetsLeft >= 1 && !(grant.endsAt.map { $0 <= now } ?? false)
        }
    }

    /// What each listed reset refills, for the resets popover.
    func resetNames(now: Date) -> [ResetName] {
        availableGrants(now: now).compactMap { grant in
            grant.endsAt.map { ResetName(expiresAt: $0, name: grant.name) }
        }
    }

    /// The row reads "N available" and each remaining reset's grant deadline rides along in
    /// `expiriesAt` for the resets popover; a grant with several resets left contributes one expiry per
    /// reset. Grants past their deadline or with none left are skipped, and an ineligible account reads
    /// "0 available". Paused grants still count: they are owned, just not usable this instant.
    func line(now: Date) -> MetricLine {
        var count = 0
        var expiries: [Date] = []
        for grant in availableGrants(now: now) {
            count += grant.resetsLeft
            if let endsAt = grant.endsAt { expiries += Array(repeating: endsAt, count: grant.resetsLeft) }
        }
        return .values(
            label: "Rate Limit Resets",
            values: [MetricValue(number: Double(count), kind: .count, label: "available")],
            expiriesAt: expiries.sorted()
        )
    }
}
