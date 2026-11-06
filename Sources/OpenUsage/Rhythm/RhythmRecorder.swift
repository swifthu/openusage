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

/// Records how fast each account's window fills up, and keeps the last so many days of it.
///
/// The recorder holds the day's buckets in memory and writes them every few minutes, so a refresh
/// does not touch the disk every time. What is in memory is the whole day, so writing it twice
/// does not lose the part that was written first, and a day another run of the app started is
/// continued from what was written.
///
/// A burn belongs to the days the interval covered. An interval that crosses midnight is booked
/// on both days: the part before midnight on the day that ended, the rest on the day that began.
/// The consumption before a provider's window resets is still not seen, and the recorder does not
/// guess at it.
@MainActor
@Observable
final class RhythmRecorder {
    private let history: any RhythmStore
    private let settings: RhythmSettings
    private let calendar: Calendar

    /// The last reading of every series, so the next one can be differenced against it.
    @ObservationIgnored private var lastReading: [String: RhythmReading] = [:]
    /// The buckets of the days the recorder holds, by day. A day stays here until it is on disk.
    @ObservationIgnored private var days: [Date: [String: RhythmSeriesRecord]] = [:]
    /// What was written of each held day, by day.
    @ObservationIgnored private var written: [Date: [String: RhythmSeriesRecord]] = [:]
    /// The day the readings belong to.
    @ObservationIgnored private var recordedDay: Date?
    /// When the day's buckets were last written.
    @ObservationIgnored private var lastFlush: Date?
    /// When the last write failed. A failed write is not tried again before the interval has
    /// passed, so a disk that cannot be written does not fill the log with one warning per
    /// reading.
    @ObservationIgnored private var lastFailure: Date?
    /// How long the day's buckets are kept in memory before they are written.
    @ObservationIgnored private let flushInterval: TimeInterval
    /// How many writes have failed in a row.
    @ObservationIgnored private var failures = 0
    /// What went wrong the last time the history could not be written, if anything. The recorder
    /// keeps retrying, but the user has to know that the chart is not being filled — a disk that
    /// cannot be written leaves the chart empty with no explanation anywhere else.
    private(set) var lastWriteError: String?
    /// Whether a write was already attempted after the recording was turned off. The first such
    /// write is the user's own request and is not held back by the backoff; the retries after it
    /// are, so a disk that cannot be written does not warn on every refresh.
    @ObservationIgnored private var wroteAfterSwitchingOff = false

    init(
        store: any RhythmStore,
        settings: RhythmSettings,
        calendar: Calendar,
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
        guard let day = recordedDay else { return [] }
        return pendingSeries(on: day)
    }

    /// The days that are held in memory and are not on disk yet, oldest first. A day whose write
    /// failed stays here until the write lands. The tests read this; the app does not.
    var pendingDays: [Date] {
        days.keys.filter { !pendingSeries(on: $0).isEmpty }.sorted()
    }

    /// The days the recorder holds in memory. The tests read this; the app does not.
    var heldDays: [Date] { days.keys.sorted() }

    /// The readings a snapshot carries: the session-sized metrics of one account.
    static func readings(from snapshot: ProviderSnapshot, kind: ProviderKind, at now: Date) -> [RhythmReading] {
        snapshot.lines.compactMap { line in
            guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodMs) = line else {
                return nil
            }
            // The share of a money budget is the rate at which money is spent, and this fork does
            // not chart spending. A count and a percentage are both shares of a window.
            guard !format.isMoney else { return nil }
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
        guard settings.isEnabled else {
            // Turning the recording off stops the readings, but what was already recorded is
            // written out rather than thrown away. The first write after the switch is not held
            // back by the backoff of a failed write — the user asked for it — but the retries
            // after it are, so a disk that cannot be written does not warn on every refresh.
            if !wroteAfterSwitchingOff || canWrite(at: now) {
                wroteAfterSwitchingOff = true
                flush(at: now)
            }
            return
        }
        // The recording is on, so the next time it is turned off its first write is again the
        // user's own request.
        wroteAfterSwitchingOff = false
        // The day's buckets are written before the new reading is folded in, so what is on disk is
        // always a whole number of readings and the newest one is still waiting to be written.
        checkpointIfDue(at: now)
        for reading in Self.readings(from: snapshot, kind: kind, at: now) {
            apply(reading, at: now)
        }
    }

    /// Removes the whole history: the days on disk and the ones the recorder still holds.
    ///
    /// The recorder writes the day it is on again on the next refresh, so a history that was only
    /// deleted from the store would come back the same afternoon.
    func deleteHistory(now: Date = Date(), calendar: Calendar = .current) throws {
        try history.deleteAll(now: now, calendar: calendar)
        days.removeAll()
        written.removeAll()
        // The baselines go with it: the next reading starts a new day rather than booking the
        // jump between the last reading and it as consumption.
        lastReading.removeAll()
    }

    /// Tells the recorder that the account behind a provider's slot may be a different one now —
    /// another account's key was pasted into it. The jump between the old reading and the new one
    /// is then that account's state and not consumption, so the old reading is dropped and the
    /// next one starts a new baseline.
    func forgetReadings(for providerID: String) {
        let prefix = "\(providerID)/"
        let keys = lastReading.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        AppLog.info(.rhythm, "the rhythm of \(providerID) starts a new baseline: \(keys.count) readings dropped, the account behind it may be a different one")
        for key in keys {
            lastReading.removeValue(forKey: key)
        }
    }

    /// Takes the readings of a snapshot as the baseline of the next ones, without booking a burn.
    ///
    /// The app's cache holds the last snapshot of every provider, so the consumption between it
    /// and the first reading of this run — a whole night, for a provider with a day-long window —
    /// is not lost.
    func adoptBaseline(_ snapshot: ProviderSnapshot, kind: ProviderKind) {
        for reading in Self.readings(from: snapshot, kind: kind, at: snapshot.refreshedAt) {
            lastReading[reading.key] = reading
        }
    }

    /// Writes the buckets that changed since the last write, and remembers them as written so only
    /// what changed since is waiting to be written again. Returns whether every day was written.
    ///
    /// A day whose write fails stays in memory, so the next write takes it out as well.
    @discardableResult
    func flush(at now: Date) -> Bool {
        var wroteEverything = true
        var failed = false
        for day in days.keys.sorted() {
            let series = days[day] ?? [:]
            guard !pendingSeries(on: day).isEmpty else {
                if day != recordedDay {
                    // The day is on disk and nothing is waiting to be written, so the recorder
                    // does not need to hold it any more.
                    days.removeValue(forKey: day)
                    written.removeValue(forKey: day)
                }
                continue
            }
            let record = RhythmDayRecord(day: day, series: series.values.sorted { $0.key < $1.key })
            do {
                try history.save(record)
                written[day] = series
                lastFlush = now
                lastWriteError = nil
                if day != recordedDay {
                    // The day is on disk, so the recorder does not need to hold it any more.
                    days.removeValue(forKey: day)
                    written.removeValue(forKey: day)
                }
            } catch {
                wroteEverything = false
                failed = true
                failures += 1
                lastFailure = now
                lastWriteError = error.localizedDescription
                AppLog.warn(.rhythm, "could not write the rhythm history for \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
                if failures >= 5 {
                    AppLog.error(.rhythm, "the rhythm history stopped being written after \(failures) failures in a row")
                }
            }
        }
        if !failed { failures = 0 }
        return wroteEverything
    }

    private func apply(_ reading: RhythmReading, at now: Date) {
        let day = calendar.startOfDay(for: reading.at)
        if recordedDay != day {
            // The day rolled over. The burn since the last reading may have crossed midnight: the
            // part before it belongs to the day that ended and the rest to the day that began. It
            // is worked out first, while the day that ended is still in memory — writing that day
            // before the burn is known would lose it.
            let previous = lastReading[reading.key]
            let endedDay = previous.map { calendar.startOfDay(for: $0.at) }
            let endedBurn = previous.flatMap {
                RhythmDifferencer.delta(from: $0, to: reading, day: calendar.startOfDay(for: $0.at), calendar: calendar)
            }
            let begunBurn = previous.flatMap {
                RhythmDifferencer.delta(from: $0, to: reading, day: day, calendar: calendar)
            }
            if let endedBurn, let endedDay, endedDay != day {
                burn(endedBurn, of: reading, on: endedDay)
            }
            // The day that just ended is written before the new reading is folded in, so what is on
            // disk is always a whole number of readings. A day whose write failed stays in memory
            // until it lands.
            recordedDay = day
            days[day] = days[day] ?? [:]
            flush(at: now)
            continueFromStore(on: day)
            // The day that began is continued from what was written, so the burn that belongs to
            // it is added after that.
            if let begunBurn {
                burn(begunBurn, of: reading, on: day)
            }
        } else if let previous = lastReading[reading.key] {
            burn(from: previous, to: reading, on: day)
        }
        var series = days[day] ?? [:]
        var record = series[reading.key] ?? RhythmSeriesRecord(
            key: reading.key,
            kind: reading.kind,
            label: reading.label,
            windowMs: reading.windowMs,
            points: Array(repeating: 0, count: RhythmClock.bucketCount(on: day, calendar: calendar)),
            samples: Array(repeating: 0, count: RhythmClock.bucketCount(on: day, calendar: calendar))
        )
        if let index = RhythmClock.bucketIndex(for: reading.at, on: day, calendar: calendar),
           index < record.samples.count {
            record.samples[index] += 1
        }
        series[reading.key] = record
        days[day] = series
        lastReading[reading.key] = reading
    }

    /// Adds the burn between two readings to the buckets of the day it is asked about.
    private func burn(from previous: RhythmReading, to current: RhythmReading, on day: Date) {
        let delta = RhythmDifferencer.delta(from: previous, to: current, day: day, calendar: calendar)
        burn(delta, of: current, on: day)
    }

    /// Adds a burn to the buckets of the day it belongs to.
    private func burn(_ delta: RhythmDelta, of reading: RhythmReading, on day: Date) {
        guard !delta.buckets.isEmpty else { return }
        var series = days[day] ?? [:]
        var record = series[reading.key] ?? RhythmSeriesRecord(
            key: reading.key,
            kind: reading.kind,
            label: reading.label,
            windowMs: reading.windowMs,
            points: Array(repeating: 0, count: RhythmClock.bucketCount(on: day, calendar: calendar)),
            samples: Array(repeating: 0, count: RhythmClock.bucketCount(on: day, calendar: calendar))
        )
        for share in delta.buckets where share.index < record.points.count {
            record.points[share.index] += delta.points * share.share
        }
        series[reading.key] = record
        days[day] = series
    }

    private func pendingSeries(on day: Date) -> [RhythmSeriesRecord] {
        let series = days[day] ?? [:]
        let writtenSeries = written[day] ?? [:]
        return series.values
            .filter { writtenSeries[$0.key] != $0 }
            .sorted { $0.key < $1.key }
    }

    private func checkpointIfDue(at now: Date) {
        guard let lastFlush else {
            lastFlush = now
            return
        }
        guard now.timeIntervalSince(lastFlush) >= flushInterval else { return }
        guard canWrite(at: now) else { return }
        flush(at: now)
    }

    /// Whether a write may be attempted. A write that failed is not tried again before the
    /// interval has passed, so a disk that cannot be written does not produce a warning for
    /// every reading.
    private func canWrite(at now: Date) -> Bool {
        guard let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= flushInterval
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
        var series = days[day] ?? [:]
        var writtenSeries = written[day] ?? [:]
        for storedSeries in stored.series {
            var points = [Double](repeating: 0, count: count)
            var samples = [Int](repeating: 0, count: count)
            for bucket in 0..<min(count, storedSeries.points.count) { points[bucket] = storedSeries.points[bucket] }
            for bucket in 0..<min(count, storedSeries.samples.count) { samples[bucket] = storedSeries.samples[bucket] }
            let continued = RhythmSeriesRecord(
                key: storedSeries.key,
                kind: storedSeries.kind,
                label: storedSeries.label,
                windowMs: storedSeries.windowMs,
                points: points,
                samples: samples
            )
            series[storedSeries.key] = continued
            writtenSeries[storedSeries.key] = continued
        }
        days[day] = series
        written[day] = writtenSeries
    }
}
