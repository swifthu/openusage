import Foundation
import Observation

/// Whether the app records how fast each account's window fills up, and how long it keeps the
/// history. The history never leaves this Mac.
@MainActor
@Observable
final class RhythmSettings {
    static let key = "recordsUsageRhythm"
    /// How many days of history are kept. The store trims the days older than this.
    nonisolated static let retentionDays = 90
    /// The longest window the rhythm history records: a day. A longer window sampled every few
    /// minutes is a slow drift, and its hourly rate says nothing about when the account is used.
    static let shortWindowMs = MetricPeriod.dayMs

    /// Whether the history is being recorded.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Recording is on by default: the history stays on this Mac, and the switch in Settings
        // turns it off in one step.
        self.isEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}
