import Foundation

enum RefreshSetting {
    /// UserDefaults key for the chosen refresh interval, in seconds.
    static let key = "refreshIntervalSeconds"
    /// The shortest interval the user can pick.
    static let minInterval: TimeInterval = 30
    /// The longest interval the user can pick — and the default, so a fresh install keeps the
    /// conservative cadence.
    static let maxInterval: TimeInterval = 5 * 60

    /// How often the app refreshes provider usage: the user's choice, clamped to the supported
    /// range. Nothing stored means the default.
    static var interval: TimeInterval {
        clamped(UserDefaults.standard.double(forKey: key))
    }

    /// A stored value that is missing, zero or out of range lands on the default or the nearest
    /// supported bound.
    static func clamped(_ stored: Double) -> TimeInterval {
        guard stored > 0 else { return maxInterval }
        return min(max(stored, minInterval), maxInterval)
    }

    /// A failed provider is retried one interval later, then backs off from there. Tied to the
    /// chosen interval so a faster cadence also recovers faster.
    static var failureBackoffBase: TimeInterval { interval }
    static let failureBackoffCap: TimeInterval = 60 * 60

    static let secondaryReadInterval: TimeInterval = 60 * 60
    static let forcedResetGrantsMinimumAge: TimeInterval = 15 * 60
}
