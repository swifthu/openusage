import Foundation
import Observation

/// The consumption between two readings of the same series.
enum RhythmDifferencer {
    /// What was burned between two readings, and the buckets it belongs to.
    ///
    /// A window that reset burns nothing: the use before the reset was never read, and the new
    /// window's reading counts from its own zero. A gap longer than the window burns nothing for
    /// the same reason — the two readings describe different windows.
    ///
    /// The delta is attributed to the day of the later reading. An interval that crosses midnight
    /// therefore leaves the part before midnight in no bucket, which costs at most one refresh
    /// interval of consumption per day boundary — see `RhythmClock.shares`.
    static func delta(
        from previous: RhythmReading,
        to current: RhythmReading,
        day: Date,
        calendar: Calendar = .current
    ) -> RhythmDelta {
        let interval = current.at.timeIntervalSince(previous.at)
        guard interval > 0 else { return RhythmDelta(points: 0, buckets: []) }
        guard interval <= Double(current.windowMs) / 1000 else {
            return RhythmDelta(points: 0, buckets: [])
        }
        // The window the last reading described ended before this reading was taken, so the two
        // are not two points on the same window's curve.
        let reset: Bool
        if let previousReset = previous.resetsAt {
            reset = previousReset <= current.at
        } else {
            reset = current.fraction < previous.fraction
        }
        guard !reset else { return RhythmDelta(points: 0, buckets: []) }

        let burned = current.fraction - previous.fraction
        guard burned > 0 else { return RhythmDelta(points: 0, buckets: []) }
        let points = min(burned, 1)
        return RhythmDelta(
            points: points,
            buckets: RhythmClock.shares(from: previous.at, to: current.at, day: day, calendar: calendar)
        )
    }
}

/// Records how fast each account's window fills up, and keeps the last so many days of it.
///
/// The recorder holds the day's buckets in memory and writes them every few minutes, so a refresh
/// does not touch the disk every time. What is in memory is the whole day, so writing it twice
/// does not lose the part that was written first, and a day another run of the app started is
/// continued from what was written.
///
/// A delta belongs to the day of the **later** reading. An interval that crosses midnight
/// therefore leaves the part before midnight in no bucket, and an interval that *begins* before
/// the day's midnight — a reading at 23:58 and the next one at 00:02 — lands in no bucket at all.
/// Both losses are bounded by one refresh interval per day boundary, the same order as the use
/// before a provider's window resets that the recorder also does not see.
@MainActor
@Observable
final class RhythmRecorder {
    private let history: any RhythmStore
    private let settings: RhythmSettings
    private let calendar: Calendar

    /// The last reading of every series, so the next one can be differenced against it.
    @ObservationIgnored private var lastReading: [String: RhythmReading] = [:]
    /// The day's buckets as they stand.
    @ObservationIgnored private var buckets: [String: RhythmSeriesRecord] = [:]
    /// The day's buckets as they were last written, so the recorder knows what has changed since.
    @ObservationIgnored private var written: [String: RhythmSeriesRecord] = [:]
    /// The day the buckets belong to.
    @ObservationIgnored private var recordedDay: Date?
    /// When the day's buckets were last written.
    @ObservationIgnored private var lastFlush: Date?
    /// How long the day's buckets are kept in memory before they are written.
    @ObservationIgnored private let flushInterval: TimeInterval
    /// How many writes have failed in a row.
    @ObservationIgnored private var failures = 0

    init(
        store: any RhythmStore,
        settings: RhythmSettings,
        calendar: Calendar = .current,
        flushInterval: TimeInterval = 5 * 60
    ) {
        self.history = store
        self.settings = settings
        self.calendar = calendar
        self.flushInterval = flushInterval
    }

    /// The store the history is kept in. The chart reads the days it holds.
    var store: any RhythmStore { history }

    /// The buckets waiting to be written: the series whose buckets have changed since the last
    /// write. The tests read this; the app does not.
    var pendingSeries: [RhythmSeriesRecord] {
        buckets.values
            .filter { written[$0.key] != $0 }
            .sorted { $0.key < $1.key }
    }

    /// The readings a snapshot carries: the session-sized metrics of one account.
    static func readings(from snapshot: ProviderSnapshot, kind: ProviderKind, at now: Date) -> [RhythmReading] {
        snapshot.lines.compactMap { line in
            guard case .progress(let label, let used, let limit, _, let resetsAt, let periodMs) = line else {
                return nil
            }
            // Only a window that is short enough to have a rhythm inside a day. A weekly window
            // sampled every few minutes is a slow drift, and its hourly rate says nothing.
            guard let periodMs, periodMs > 0, periodMs <= RhythmSettings.shortWindowMs else { return nil }
            guard limit > 0 else { return nil }
            return RhythmReading(
                key: "\(snapshot.providerID)/\(label)",
                kind: kind,
                label: label,
                windowMs: periodMs,
                fraction: min(max(used / limit, 0), 1),
                resetsAt: resetsAt,
                at: now
            )
        }
    }

    /// Records what a refresh found. A refresh that failed produces no reading, so the hours it
    /// covered stay empty rather than showing as no usage.
    func record(_ snapshot: ProviderSnapshot, kind: ProviderKind, at now: Date) {
        guard settings.isEnabled else { return }
        // The day's buckets are written before the new reading is folded in, so what is on disk is
        // always a whole number of readings and the newest one is still waiting to be written.
        checkpointIfDue(at: now)
        for reading in Self.readings(from: snapshot, kind: kind, at: now) {
            apply(reading, at: now)
        }
    }

    /// Writes the day's buckets, and remembers them as written so only what changed since is
    /// waiting to be written again.
    func flush(at now: Date) {
        guard let day = recordedDay, !buckets.isEmpty else { return }
        guard !pendingSeries.isEmpty else { return }
        let record = RhythmDayRecord(day: day, series: buckets.values.sorted { $0.key < $1.key })
        do {
            try history.save(record)
            failures = 0
            lastFlush = now
            written = buckets
        } catch {
            failures += 1
            AppLog.warn(.rhythm, "could not write the rhythm history for \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
            if failures >= 5 {
                AppLog.error(.rhythm, "the rhythm history stopped being written after \(failures) failures in a row")
            }
        }
    }

    private func apply(_ reading: RhythmReading, at now: Date) {
        let day = calendar.startOfDay(for: now)
        if recordedDay != day {
            flush(at: now)
            buckets.removeAll()
            written.removeAll()
            recordedDay = day
            continueFromStore(on: day)
        }
        var record = buckets[reading.key] ?? RhythmSeriesRecord(
            key: reading.key,
            kind: reading.kind,
            label: reading.label,
            windowMs: reading.windowMs,
            points: Array(repeating: 0, count: RhythmClock.bucketCount(on: day, calendar: calendar)),
            samples: Array(repeating: 0, count: RhythmClock.bucketCount(on: day, calendar: calendar))
        )
        if let previous = lastReading[reading.key] {
            let delta = RhythmDifferencer.delta(from: previous, to: reading, day: day, calendar: calendar)
            for share in delta.buckets where share.index < record.points.count {
                record.points[share.index] += delta.points * share.share
            }
        }
        if let index = RhythmClock.bucketIndex(for: reading.at, on: day, calendar: calendar),
           index < record.samples.count {
            record.samples[index] += 1
        }
        buckets[reading.key] = record
        lastReading[reading.key] = reading
    }

    private func checkpointIfDue(at now: Date) {
        guard let lastFlush else {
            lastFlush = now
            return
        }
        guard now.timeIntervalSince(lastFlush) >= flushInterval else { return }
        flush(at: now)
    }

    /// A day another run of the app started: the recorder continues from what was written, so the
    /// part of the day before the restart is not lost when the day is written again.
    private func continueFromStore(on day: Date) {
        let stored: RhythmDayRecord?
        do {
            stored = try history.load(day: day)
        } catch {
            AppLog.warn(.rhythm, "could not read the rhythm history for \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
            return
        }
        guard let stored else { return }
        let count = RhythmClock.bucketCount(on: day, calendar: calendar)
        for series in stored.series {
            var points = [Double](repeating: 0, count: count)
            var samples = [Int](repeating: 0, count: count)
            for bucket in 0..<min(count, series.points.count) { points[bucket] = series.points[bucket] }
            for bucket in 0..<min(count, series.samples.count) { samples[bucket] = series.samples[bucket] }
            let continued = RhythmSeriesRecord(
                key: series.key,
                kind: series.kind,
                label: series.label,
                windowMs: series.windowMs,
                points: points,
                samples: samples
            )
            buckets[series.key] = continued
            written[series.key] = continued
        }
    }
}
