import Foundation

/// The levels of a series: the readings that carried the share the window still had left.
///
/// The levels are kept apart from the buckets on purpose. A burn is a rate and can be spread over
/// every bucket an interval covered, but a level is a reading of the window at one instant. A
/// window that resets makes a day's levels a series of separate runs rather than one line, so
/// they are kept as readings and not as buckets.
extension RhythmSeriesRecord {
    /// An empty record of a day: every bucket of it holds nothing yet.
    static func empty(
        key: String,
        kind: ProviderKind,
        label: String,
        windowMs: Int,
        bucketCount: Int
    ) -> RhythmSeriesRecord {
        RhythmSeriesRecord(
            key: key,
            kind: kind,
            label: label,
            windowMs: windowMs,
            points: Array(repeating: 0, count: bucketCount),
            samples: Array(repeating: 0, count: bucketCount),
            levels: nil
        )
    }

    /// Keeps one reading's remaining share.
    mutating func keep(level: RhythmLevelSample) {
        if levels == nil { levels = [] }
        levels?.append(level)
    }

    /// The readings that carried a remaining share, oldest first.
    var levelSamples: [RhythmLevelSample] {
        levels ?? []
    }
}
