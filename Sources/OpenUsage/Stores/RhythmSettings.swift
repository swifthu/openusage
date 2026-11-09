import Foundation
import Observation

/// Whether the app records how fast each account's window fills up. The history never leaves this
/// Mac, and how long it is kept is `RhythmRetention`'s business.
@MainActor
@Observable
final class RhythmSettings {
    static let key = "recordsUsageRhythm"
    /// The longest window the rhythm history records: a day. A longer window sampled every few
    /// minutes is a slow drift, and its hourly rate says nothing about when the account is used.
    static let shortWindowMs = MetricPeriod.dayMs
    /// Where the choice of the window the chart follows is kept.
    static let trackedSessionDefaultsKey = "trackedRhythmSession"
    /// Where the choice of keeping the remaining share is kept.
    static let tracksSessionWindowsKey = "tracksRhythmSessionWindows"

    /// Whether the history is being recorded.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.key) }
    }

    /// Whether the remaining share of the 5-hour windows is kept.
    ///
    /// The rhythm records how fast a window fills up. The share that was left when it was read is
    /// a second thing, and it is only kept for the 5-hour windows: a window that resets every few
    /// hours is the one whose remaining share says something about the plan, and it is what the
    /// chart's line draws.
    var tracksSessionWindows: Bool {
        didSet { defaults.set(tracksSessionWindows, forKey: Self.tracksSessionWindowsKey) }
    }

    /// Which 5-hour window the chart follows, by the key of its series.
    ///
    /// The key holds the account's card id, which is local to this Mac: a key that is not in the
    /// history any more is simply not followed, and the chart falls back to the first window it
    /// holds.
    var trackedSessionKey: String? {
        didSet { defaults.set(trackedSessionKey, forKey: Self.trackedSessionDefaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Recording is on by default: the history stays on this Mac, and the switch in Settings
        // turns it off in one step.
        self.isEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
        // The remaining share of the 5-hour windows is kept by default as well: it is what the
        // chart's line draws, and a setting that is off by default is a feature nobody finds.
        self.tracksSessionWindows = defaults.object(forKey: Self.tracksSessionWindowsKey) as? Bool ?? true
        self.trackedSessionKey = defaults.string(forKey: Self.trackedSessionDefaultsKey)
    }
}
