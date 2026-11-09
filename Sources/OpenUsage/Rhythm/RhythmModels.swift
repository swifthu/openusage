import Foundation

/// One account's one metric, tracked over time.
struct RhythmSeries: Hashable, Sendable, Codable {
    /// The account's card id and the metric's label, joined so two accounts' metrics never collide.
    var key: String
    /// The provider the account belongs to, so the chart can group a family's accounts.
    var kind: ProviderKind
    /// The metric's label, e.g. "Session".
    var label: String
    /// The length of the window the metric counts down in, in milliseconds.
    var windowMs: Int
}

/// One reading that carried the share the window still had left.
///
/// The levels are kept apart from the buckets: a burn is a rate and can be spread over the
/// buckets an interval covered, but a level is a reading of the window at one instant, and a
/// window that resets makes the levels of a day a series of separate runs rather than one line.
struct RhythmLevelSample: Hashable, Sendable, Codable {
    /// When the reading was taken.
    var at: Date
    /// The share of the window that was still left, 0...1.
    var remaining: Double
}

/// One series' buckets for one day.
struct RhythmSeriesRecord: Hashable, Sendable, Codable {
    var key: String
    var kind: ProviderKind
    var label: String
    var windowMs: Int
    /// One entry per five-minute bucket: how much of the window that bucket burned, in points.
    var points: [Double]
    /// One entry per bucket: how many samples landed in it. Zero means nothing was read, which is
    /// not the same as nothing being used.
    var samples: [Int]
    /// The readings that carried the window's remaining share, oldest first.
    ///
    /// Nil when the window is not tracked — the setting in Settings is off, or the file was
    /// written before the levels were kept. An empty array is a window that is tracked and has
    /// been read nothing yet.
    var levels: [RhythmLevelSample]?

    var series: RhythmSeries {
        RhythmSeries(key: key, kind: kind, label: label, windowMs: windowMs)
    }
}

/// Everything recorded for one local day.
struct RhythmDayRecord: Hashable, Sendable {
    /// The version of the on-disk format. A file with another version is skipped, not guessed at.
    static let currentSchema = "openusage.rhythm.v1"

    /// The day's local midnight.
    var day: Date
    /// One entry per series tracked that day.
    var series: [RhythmSeriesRecord]
}

/// What one reading of one series says.
struct RhythmReading: Hashable, Sendable {
    var key: String
    var kind: ProviderKind
    var label: String
    var windowMs: Int
    /// The share of the window that had been used, 0...1.
    var fraction: Double
    /// When the window this reading describes resets.
    var resetsAt: Date?
    /// When the reading was taken.
    var at: Date
}

/// One point of the chart's line: where it sits in the chart and how much was left.
struct RhythmLevelPoint: Hashable, Sendable {
    /// Where the point sits in the chart, 0...1 from the left.
    var position: Double
    /// The share of the window that was still left, 0...1.
    var remaining: Double
}

/// A 5-hour window the chart can follow.
///
/// The key holds the account's card id, which is local to this Mac: a window that is not in the
/// history any more is simply not on offer.
struct RhythmSessionWindow: Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var kind: ProviderKind
    var label: String
    /// The name the picker shows.
    var name: String { "\(kind.displayName) · \(label)" }
}

/// How much of a window was burned between two readings, and the buckets it belongs to.
struct RhythmDelta: Hashable, Sendable {
    /// The share of the window that was burned, in points. Never more than one.
    var points: Double
    /// Where the burned share goes.
    var buckets: [RhythmBucketShare]
    /// Whether the burn was bigger than the whole window and was clamped to it. A clamped burn
    /// means the provider's denominator changed, so the bar is not a rate the user burned.
    var clamped: Bool
}

/// One bucket's share of a delta.
struct RhythmBucketShare: Hashable, Sendable {
    var index: Int
    /// How much of the delta falls in this bucket, 0...1.
    var share: Double
}
