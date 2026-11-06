import XCTest
import os
@testable import OpenUsage

/// The recorder differences one refresh against the last one, so the history says how much of a
/// window was burned and when. A window that reset, and a gap longer than the window, burn
/// nothing: the use before the reset was never read.
@MainActor
final class RhythmRecorderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func moment(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: hour, minute: minute))!
    }

    private func reading(
        fraction: Double,
        at: Date,
        resetsAt: Date? = nil,
        key: String = "account-1/Session"
    ) -> RhythmReading {
        RhythmReading(
            key: key,
            kind: .claude,
            label: "Session",
            windowMs: MetricPeriod.sessionMs,
            fraction: fraction,
            resetsAt: resetsAt,
            at: at
        )
    }

    func testTheDifferenceBetweenTwoReadingsIsTheBurnedShare() {
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.2, at: moment(14, 0)),
            to: reading(fraction: 0.35, at: moment(14, 5)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertEqual(delta.points, 0.15, accuracy: 0.0001)
        XCTAssertEqual(delta.buckets.count, 1)
        XCTAssertEqual(delta.buckets[0].index, 168)
        XCTAssertEqual(delta.buckets[0].share, 1, accuracy: 0.0001)
    }

    func testAWindowThatResetBurnsNothing() {
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.8, at: moment(14, 0), resetsAt: moment(14, 1)),
            to: reading(fraction: 0.05, at: moment(14, 5), resetsAt: moment(19, 0)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertEqual(delta.points, 0)
        XCTAssertTrue(delta.buckets.isEmpty)
    }

    func testAWindowThatResetIsNoticedEvenWhenTheReadingWentUp() {
        // The old window was nearly empty and the new one is nearly full: the reading went up, but
        // the window reset in between, so nothing was burned.
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.2, at: moment(14, 0), resetsAt: moment(14, 1)),
            to: reading(fraction: 0.9, at: moment(14, 5), resetsAt: moment(19, 0)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertEqual(delta.points, 0)
    }

    func testWithoutAResetInstantAFallingReadingMeansTheWindowReset() {
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.8, at: moment(14, 0)),
            to: reading(fraction: 0.05, at: moment(14, 5)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertEqual(delta.points, 0)
    }

    func testAGapLongerThanTheWindowBurnsNothing() {
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.2, at: moment(10, 0), resetsAt: moment(15, 0)),
            to: reading(fraction: 0.4, at: moment(16, 0), resetsAt: moment(21, 0)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertEqual(delta.points, 0)
    }

    func testTheBurnedShareNeverExceedsTheWholeWindow() {
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.0, at: moment(14, 0), resetsAt: moment(19, 0)),
            to: reading(fraction: 4.0, at: moment(14, 5), resetsAt: moment(19, 0)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertEqual(delta.points, 1, accuracy: 0.0001)
    }

    func testOnlySessionSizedWindowsAreRecorded() {
        let snapshot = ProviderSnapshot(
            providerID: "account-1",
            displayName: "Claude",
            lines: [
                .progress(label: "Session", used: 20, limit: 100, format: .percent, resetsAt: moment(19, 0), periodDurationMs: MetricPeriod.sessionMs),
                .progress(label: "Weekly", used: 30, limit: 100, format: .percent, resetsAt: moment(100, 0), periodDurationMs: MetricPeriod.weekMs),
                .progress(label: "No Window", used: 10, limit: 100, format: .percent),
                .values(label: "Balance", values: []),
                .badge(label: "Top Up", text: "Ready")
            ]
        )

        let readings = RhythmRecorder.readings(from: snapshot, kind: .claude, at: moment(14, 0))

        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings[0].label, "Session")
        XCTAssertEqual(readings[0].fraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(readings[0].key, "account-1/Session")
    }

    func testAMetricWithoutALimitIsNotRecorded() {
        let snapshot = ProviderSnapshot(
            providerID: "account-1",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 20, limit: 0, format: .percent, resetsAt: moment(19, 0), periodDurationMs: MetricPeriod.sessionMs)]
        )

        XCTAssertTrue(RhythmRecorder.readings(from: snapshot, kind: .claude, at: moment(14, 0)).isEmpty)
    }

    func testTheRecorderAccumulatesIntoTheHourOfTheReading() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.record(snapshot(fraction: 0.35), kind: .claude, at: moment(14, 5))

        let pending = try XCTUnwrap(recorder.pendingSeries.first)
        // The interval 14:00 - 14:05 lies wholly in the first bucket, so it carries all of it.
        XCTAssertEqual(pending.points[168], 0.15, accuracy: 0.0001)
        // Each reading is counted in the bucket it was taken in.
        XCTAssertEqual(pending.samples[168], 1)
        XCTAssertEqual(pending.samples[169], 1)
    }

    func testTheRecorderSplitsAGapAcrossTheBucketsItCovers() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.record(snapshot(fraction: 0.5), kind: .claude, at: moment(16, 0))

        let pending = try XCTUnwrap(recorder.pendingSeries.first)
        // The gap covers 14:00 to 16:00: 24 buckets, each carrying the same share of the 0.3
        // that was burned, so the burn shows as a flat two hours rather than one tall bar.
        XCTAssertEqual(pending.points[168], 0.0125, accuracy: 0.0001)
        XCTAssertEqual(pending.points[180], 0.0125, accuracy: 0.0001)
        XCTAssertEqual(pending.points[191], 0.0125, accuracy: 0.0001)
        XCTAssertEqual(pending.points[168...191].reduce(0, +), 0.3, accuracy: 0.0001)
    }

    func testNothingIsRecordedWhileTheSettingIsOff() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let defaults = isolatedDefaults()
        let settings = RhythmSettings(defaults: defaults)
        settings.isEnabled = false
        let recorder = RhythmRecorder(store: store, settings: settings, calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))

        XCTAssertTrue(recorder.pendingSeries.isEmpty)
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testFlushingWritesTheDayAndClearsIt() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.flush(at: moment(14, 1))

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved[0].day, moment(0))
        XCTAssertTrue(recorder.pendingSeries.isEmpty)
    }

    func testANewDayFlushesTheOldOneFirst() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(23, 58))
        recorder.record(snapshot(fraction: 0.3), kind: .claude, at: calendar.date(byAdding: .day, value: 1, to: moment(0))!)

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved[0].day, moment(0))
    }

    func testTheWriteThatClosesTheDayCarriesTheDaysBurn() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2, resetsAt: moment(23, 59)), kind: .claude, at: moment(23, 50))
        recorder.record(snapshot(fraction: 0.35, resetsAt: moment(23, 59)), kind: .claude, at: moment(23, 58))
        recorder.record(snapshot(fraction: 0.1, resetsAt: moment(23, 59)), kind: .claude, at: calendar.date(byAdding: .day, value: 1, to: moment(0))!)

        let written = try XCTUnwrap(store.saved.first { $0.day == moment(0) })
        let series = try XCTUnwrap(written.series.first)
        // The 0.15 that was burned between 23:50 and 23:58 went out with the day it belongs to:
        // 300 of the 480 seconds fell into the bucket of 23:50 and 180 into the one of 23:55.
        XCTAssertEqual(series.points[286], 0.09375, accuracy: 0.0001)
        XCTAssertEqual(series.points[287], 0.05625, accuracy: 0.0001)
        XCTAssertEqual(series.samples[286], 1)
        XCTAssertEqual(series.samples[287], 1)
    }

    func testTheDayIsKeptUntilItsWriteLands() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        store.setFailing(true)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: moment(0))!

        recorder.record(snapshot(fraction: 0.2, resetsAt: moment(23, 59)), kind: .claude, at: moment(23, 50))
        recorder.record(snapshot(fraction: 0.35, resetsAt: moment(23, 59)), kind: .claude, at: moment(23, 58))
        recorder.record(snapshot(fraction: 0.1, resetsAt: moment(23, 59)), kind: .claude, at: nextDay)

        // The write of the day that ended failed, so the day is still in memory.
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(recorder.pendingDays.contains(moment(0)))

        store.setFailing(false)
        recorder.record(
            snapshot(fraction: 0.2, resetsAt: moment(23, 59)),
            kind: .claude,
            at: calendar.date(byAdding: .hour, value: 2, to: nextDay)!
        )

        // The day that could not be written is taken out by the next write that lands.
        let written = try XCTUnwrap(store.saved.first { $0.day == moment(0) })
        let series = try XCTUnwrap(written.series.first)
        XCTAssertEqual(series.points[286], 0.09375, accuracy: 0.0001)
        XCTAssertEqual(series.samples[286], 1)
        XCTAssertEqual(series.samples[287], 1)
    }

    func testTurningTheRecordingOffWritesWhatWasAlreadyRecorded() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let settings = RhythmSettings(defaults: isolatedDefaults())
        let recorder = RhythmRecorder(store: store, settings: settings, calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        settings.isEnabled = false
        recorder.record(snapshot(fraction: 0.35), kind: .claude, at: moment(14, 5))

        let series = try XCTUnwrap(store.saved.first?.series.first)
        // What was recorded before the recording was turned off is on disk.
        XCTAssertEqual(series.samples[168], 1)
        XCTAssertEqual(series.points[168], 0, accuracy: 0.0001)
        // The reading that arrived after the recording was turned off is not recorded.
        XCTAssertEqual(series.samples[169], 0)
    }

    func testAFailedWriteIsNotTriedAgainForEveryReading() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        store.setFailing(true)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.record(snapshot(fraction: 0.35), kind: .claude, at: moment(14, 5))
        XCTAssertEqual(store.saveAttempts, 1)

        recorder.record(snapshot(fraction: 0.5), kind: .claude, at: moment(14, 6))
        recorder.record(snapshot(fraction: 0.6), kind: .claude, at: moment(14, 7))
        recorder.record(snapshot(fraction: 0.7), kind: .claude, at: moment(14, 8))

        // The write that failed is not tried again for every reading that follows.
        XCTAssertEqual(store.saveAttempts, 1)
    }

    func testWritingTheDayTwiceKeepsBothParts() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.flush(at: moment(14, 1))
        recorder.record(snapshot(fraction: 0.35), kind: .claude, at: moment(14, 5))
        recorder.flush(at: moment(14, 6))

        // The second write replaces the record of the day, as the file store does.
        XCTAssertEqual(store.saved.count, 1)
        let series = try XCTUnwrap(store.saved.first?.series.first)
        // The second write holds the burn of both readings, not only the one after the first write.
        XCTAssertEqual(series.points[168], 0.15, accuracy: 0.0001)
        XCTAssertEqual(series.samples[168], 1)
        XCTAssertEqual(series.samples[169], 1)
    }

    func testTheRecorderContinuesADayAnotherRunStarted() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        var earlier = RhythmSeriesRecord(
            key: "account-1/Session",
            kind: .claude,
            label: "Session",
            windowMs: MetricPeriod.sessionMs,
            points: Array(repeating: 0, count: 288),
            samples: Array(repeating: 0, count: 288)
        )
        earlier.points[168] = 0.2
        earlier.samples[168] = 1
        try store.save(RhythmDayRecord(day: moment(0), series: [earlier]))

        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.flush(at: moment(14, 1))

        let series = try XCTUnwrap(store.saved.last?.series.first)
        // The burn another run of the app recorded is still there.
        XCTAssertEqual(series.points[168], 0.2, accuracy: 0.0001)
        XCTAssertEqual(series.samples[168], 2)
    }

    func testTheStoreListsEveryDayOnce() throws {
        let store = RecordingRhythmStore(calendar: calendar)

        try store.save(RhythmDayRecord(day: moment(0), series: []))
        try store.save(RhythmDayRecord(day: moment(0), series: []))

        // A day that was written twice is one day, as it is for the file store.
        XCTAssertEqual(try store.recordedDays(), [moment(0)])
    }

    private func snapshot(fraction: Double, resetsAt: Date? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "account-1",
            displayName: "Claude",
            lines: [.progress(
                label: "Session",
                used: fraction * 100,
                limit: 100,
                format: .percent,
                resetsAt: resetsAt ?? moment(19, 0),
                periodDurationMs: MetricPeriod.sessionMs
            )]
        )
    }
}

/// A store that keeps what it was given instead of writing files.
///
/// It behaves like the file store: a write replaces the record of its day, and every day is
/// listed once.
final class RecordingRhythmStore: RhythmStore, @unchecked Sendable {
    /// The calendar the days are measured in, as the file store's is.
    private let calendar: Calendar

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    private struct Records {
        var byDay: [Date: RhythmDayRecord] = [:]
        var saveAttempts = 0
        var failsSave = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: Records())

    /// The record of every day, oldest first.
    var saved: [RhythmDayRecord] { lock.withLock { $0.byDay.values.sorted { $0.day < $1.day } } }
    /// How often the recorder tried to write, whether the write succeeded or not.
    var saveAttempts: Int { lock.withLock { $0.saveAttempts } }

    /// Makes every following write fail, the way a disk that cannot be written does.
    func setFailing(_ failing: Bool) {
        lock.withLock { $0.failsSave = failing }
    }

    func save(_ record: RhythmDayRecord) throws {
        try lock.withLock { records in
            records.saveAttempts += 1
            if records.failsSave { throw RecordingRhythmStoreError.writeFailed }
            records.byDay[record.day] = record
        }
    }

    func load(day: Date) throws -> RhythmDayRecord? {
        lock.withLock { $0.byDay[calendar.startOfDay(for: day)] }
    }

    func load(days: ClosedRange<Date>) throws -> [RhythmDayRecord] {
        let first = calendar.startOfDay(for: days.lowerBound)
        let last = calendar.startOfDay(for: days.upperBound)
        return lock.withLock {
            records in
            records.byDay.values.filter { $0.day >= first && $0.day <= last }.sorted { $0.day < $1.day }
        }
    }

    func recordedDays() throws -> [Date] { lock.withLock { $0.byDay.keys.sorted() } }

    func delete(before date: Date) throws {
        let cutoff = calendar.startOfDay(for: date)
        lock.withLock { $0.byDay = $0.byDay.filter { $0.key < cutoff } }
    }
}

/// A write that did not land.
enum RecordingRhythmStoreError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "The rhythm history could not be written."
    }
}
