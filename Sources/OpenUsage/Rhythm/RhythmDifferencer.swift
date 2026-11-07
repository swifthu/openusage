import Foundation

/// The consumption between two readings of the same series.
enum RhythmDifferencer {
    /// What was burned between two readings, and the buckets it belongs to.
    ///
    /// A window that reset burns nothing: the use before the reset was never read, and the new
    /// window's reading counts from its own zero. A gap longer than the window burns nothing for
    /// the same reason — the two readings describe different windows.
    ///
    /// The buckets are the ones of the day that is asked about. An interval that crosses midnight
    /// therefore has to be asked about twice — once for the day that ended and once for the day
    /// that began — or the part of it that fell in the other day is lost.
    static func delta(
        from previous: RhythmReading,
        to current: RhythmReading,
        day: Date,
        calendar: Calendar
    ) -> RhythmDelta {
        let interval = current.at.timeIntervalSince(previous.at)
        guard interval > 0 else { return RhythmDelta(points: 0, buckets: [], clamped: false) }
        guard interval <= Double(current.windowMs) / 1000 else {
            return RhythmDelta(points: 0, buckets: [], clamped: false)
        }
        // The window the last reading described ended before this reading was taken, so the two
        // are not two points on the same window's curve.
        let reset: Bool
        if let previousReset = previous.resetsAt {
            reset = previousReset <= current.at
        } else {
            reset = current.fraction < previous.fraction
        }
        guard !reset else { return RhythmDelta(points: 0, buckets: [], clamped: false) }

        let burned = current.fraction - previous.fraction
        guard burned > 0 else { return RhythmDelta(points: 0, buckets: [], clamped: false) }
        let points = min(burned, 1)
        // More than the whole window burned in one interval: the provider's denominator changed —
        // a new plan, a smaller limit — and the chart would show a full bar that nobody burned.
        // The bar is drawn, so the log has to say that it is not a rate.
        //
        // The warning is logged once, for the day the reading belongs to: an interval that
        // crosses midnight is asked about twice, and the clamp is one event.
        if burned > 1, calendar.isDate(day, inSameDayAs: current.at) {
            AppLog.warn(.rhythm, "the rhythm of \(current.key) burned \(String(format: "%.2f", burned)) points in \(Int(interval))s "
                + "and was clamped to the whole window: the provider's limit probably changed")
        }
        return RhythmDelta(
            points: points,
            buckets: RhythmClock.shares(from: previous.at, to: current.at, day: day, calendar: calendar),
            clamped: burned > 1
        )
    }
}
