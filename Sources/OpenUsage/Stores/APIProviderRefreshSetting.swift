import Foundation

/// Fork: how often a Codex card's API Usage row fetches new data, set per card in Customize ▸ Codex.
/// The endpoints report daily totals that arrive with a delay, so polling them on the regular 5-minute
/// cadence only repeats the same answer; the row keeps its last result between fetches (see
/// `OpenAIAPIUsage`), and saving a new key or picking another period start fetches right away.
enum APIProviderRefreshSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case twoHours = "2h"
    case fourHours = "4h"
    case eightHours = "8h"

    /// Prefix of the per-card keys (`<key>.<card id>`).
    static let key = "openusage.apiProviderRefresh"
    static var fallback: APIProviderRefreshSetting { .twoHours }

    static func key(cardID: String) -> String { "\(key).\(cardID)" }

    static func current(cardID: String) -> APIProviderRefreshSetting {
        UserDefaults.standard.enumValue(forKey: key(cardID: cardID), default: fallback)
    }

    var interval: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .eightHours: return 8 * 60 * 60
        }
    }

    var label: String {
        switch self {
        case .fifteenMinutes: return "15 Minutes"
        case .thirtyMinutes: return "30 Minutes"
        case .oneHour: return "1 Hour"
        case .twoHours: return "2 Hours"
        case .fourHours: return "4 Hours"
        case .eightHours: return "8 Hours"
        }
    }
}

/// Fork: the day of the month a Codex card's API Usage period starts (1–31), set per card for
/// organizations whose monthly credit grant renews on a day other than the 1st. A month without that
/// day starts on its last day.
enum OpenAIAPIPeriodSetting {
    /// Prefix of the per-card keys (`<key>.<card id>`).
    static let key = "openusage.openaiAPI.periodStartDay"
    static let fallback = 1
    static let days = Array(1...31)

    static func key(cardID: String) -> String { "\(key).\(cardID)" }

    static func current(cardID: String) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key(cardID: cardID))
        return days.contains(stored) ? stored : fallback
    }
}

/// Fork: clears every card's API Usage settings (Reset All Settings).
enum APIUsageSettings {
    static func removeAll(from defaults: UserDefaults = .standard) {
        let prefixes = [APIProviderRefreshSetting.key + ".", OpenAIAPIPeriodSetting.key + "."]
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
