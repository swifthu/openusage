import Foundation

/// One bar of the chart.
struct RhythmBar: Hashable, Sendable, Identifiable {
    var id: Int { index }
    /// The bar's place in the window, 0...23.
    var index: Int
    /// The window points the slice burned. Several series are added together, so the sum can be
    /// more than one.
    var points: Double
    /// The readings that landed in the slice. Zero means no reading landed here, which is not the
    /// same as nothing having been used: a burn is spread over every bucket the interval
    /// covered, while the reading itself lands in the last of them — so a Mac that slept for two
    /// hours leaves two dozen buckets holding a burn and no reading of their own. On an averaged
    /// bar it is the total number of readings behind the average, not the number of days.
    var samples: Int
    /// When the slice starts.
    var start: Date
}

/// How far in the chart is zoomed. The number of bars never changes; the time each bar stands for
/// does, so zooming in shows the same bar covering less of the day.
enum RhythmZoom: Int, CaseIterable, Sendable {
    case day = 0
    case halfDay = 1
    case sixHours = 2
    case twoHours = 3

    /// The time the chart shows.
    var window: TimeInterval {
        switch self {
        case .day: 24 * 3600
        case .halfDay: 12 * 3600
        case .sixHours: 6 * 3600
        case .twoHours: 2 * 3600
        }
    }

    /// The time each bar stands for.
    var barDuration: TimeInterval { window / 24 }

    /// The name on the zoom control.
    var label: String {
        switch self {
        case .day: "All Day"
        case .halfDay: "12 Hours"
        case .sixHours: "6 Hours"
        case .twoHours: "2 Hours"
        }
    }

    /// The name of the time each bar stands for.
    var barDurationLabel: String {
        switch self {
        case .day: "Hour"
        case .halfDay: "30 Minutes"
        case .sixHours: "15 Minutes"
        case .twoHours: "5 Minutes"
        }
    }

    /// The unit of the chart: the share of the window each bar covers. The bars add up the share
    /// of every recorded window, so the unit says how much time each bar stands for.
    var unit: String {
        "Percentage Points / \(barDurationLabel)"
    }
}

/// Turns the recorded buckets into the bars the chart draws.
enum RhythmAnalytics {
    /// The bars of one day at a zoom level, starting at an offset into the day.
    ///
    /// The offset is a time into the day and only makes sense for a window shorter than the day:
    /// it is meaningful up to the day's length minus the window, and the caller clamps it. A whole
    /// day starts at the day's midnight and takes no offset.
    ///
    /// The window is a fixed 24 hours from the day's local midnight, and the 24 bars each stand
    /// for an hour of it. A day that is 25 hours long does not fit in that: the hour past the
    /// window is not in the chart, and the axis shows `01:00` twice. A day that is 23 hours long
    /// has an empty last bar, whose label is the next day's midnight. This is deliberate — the
    /// window means the same thing every day, so the days an average is made of line up — and the
    /// daylight-saving tests pin it.
    static func bars(
        for record: RhythmDayRecord,
        zoom: RhythmZoom,
        offset: TimeInterval = 0,
        calendar: Calendar = .current
    ) -> [RhythmBar] {
        let windowStart = calendar.startOfDay(for: record.day).addingTimeInterval(offset)
        var points = [Double](repeating: 0, count: 24)
        var samples = [Int](repeating: 0, count: 24)
        for series in record.series {
            for (index, value) in series.points.enumerated() {
                // A file written by another version can have two arrays of different lengths, so
                // the samples are read defensively: a missing sample counts as none.
                let sampleCount = index < series.samples.count ? series.samples[index] : 0
                // The bucket starts at the day's midnight plus its index in five-minute steps, so
                // the slice it falls in is arithmetic — no calendar call per bucket.
                let seconds = Double(index) * RhythmClock.bucketSeconds - offset
                let slice = Int((seconds / zoom.barDuration).rounded(.down))
                guard slice >= 0, slice < 24 else { continue }
                points[slice] += value
                samples[slice] += sampleCount
            }
        }
        return (0..<24).map { index in
            RhythmBar(
                index: index,
                points: points[index],
                samples: samples[index],
                start: windowStart.addingTimeInterval(Double(index) * zoom.barDuration)
            )
        }
    }

    /// The bars of several days averaged, slice for slice. A slice is divided by the days that
    /// were read in it, so a day the app was closed does not pull the average down. A day whose
    /// points are in a slice but whose readings are not does not contribute at all: the numerator
    /// and the denominator have to agree.
    ///
    /// An empty input returns no bars at all, where `bars(for:)` always returns 24. That is on
    /// purpose: the view shows its "nothing recorded yet" message when there are no bars.
    static func averageBars(
        for records: [RhythmDayRecord],
        zoom: RhythmZoom,
        offset: TimeInterval = 0,
        calendar: Calendar = .current
    ) -> [RhythmBar] {
        guard let first = records.first else { return [] }
        var totals = [Double](repeating: 0, count: 24)
        var readings = [Int](repeating: 0, count: 24)
        var samples = [Int](repeating: 0, count: 24)
        for record in records {
            for bar in bars(for: record, zoom: zoom, offset: offset, calendar: calendar) {
                // Only a day that was read in this slice contributes, on both sides: a day whose
                // points are here but whose readings are not would raise the average.
                guard bar.samples > 0 else { continue }
                totals[bar.index] += bar.points
                readings[bar.index] += 1
                samples[bar.index] += bar.samples
            }
        }
        let windowStart = calendar.startOfDay(for: first.day).addingTimeInterval(offset)
        return (0..<24).map { index in
            RhythmBar(
                index: index,
                points: readings[index] > 0 ? totals[index] / Double(readings[index]) : 0,
                samples: samples[index],
                start: windowStart.addingTimeInterval(Double(index) * zoom.barDuration)
            )
        }
    }

    /// The bars that make up the peak: the run around the tallest bar that stays at or above 60%
    /// of it. A flat day — every bar the same height — makes the peak the whole chart.
    static func peakBars(in bars: [RhythmBar]) -> ClosedRange<Int>? {
        guard let tallest = bars.map(\.points).max(), tallest > 0,
              let peak = bars.firstIndex(where: { $0.points == tallest })
        else { return nil }
        let threshold = tallest * 0.6
        var first = peak
        while first > 0, bars[first - 1].points >= threshold { first -= 1 }
        var last = peak
        while last < bars.count - 1, bars[last + 1].points >= threshold { last += 1 }
        return first...last
    }
}
