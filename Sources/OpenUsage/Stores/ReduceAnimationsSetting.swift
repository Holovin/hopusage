import AppKit
import Foundation

/// App-specific motion preference. It supplements macOS Reduce Motion so either choice can request
/// the same reduced-animation behavior throughout the SwiftUI tree and the AppKit panel bridge.
enum ReduceAnimationsSetting {
    static let key = "reduceAnimations"
    /// Fork default: on (the original leaves it off).
    static let fallback = true

    static func resolve(appPreference: Bool, systemReduceMotion: Bool) -> Bool {
        appPreference || systemReduceMotion
    }

    /// Live value for imperative AppKit animation sites. SwiftUI reads the same two inputs through
    /// `@AppStorage` and `accessibilityReduceMotion` in `ReduceAnimationsModifier`.
    @MainActor
    static var isEnabled: Bool {
        resolve(
            appPreference: UserDefaults.standard.object(forKey: key) as? Bool ?? fallback,
            systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}
