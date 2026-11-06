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
        let store = RecordingRhythmStore()
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
        let store = RecordingRhythmStore()
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
        let store = RecordingRhythmStore()
        let defaults = isolatedDefaults()
        let settings = RhythmSettings(defaults: defaults)
        settings.isEnabled = false
        let recorder = RhythmRecorder(store: store, settings: settings, calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))

        XCTAssertTrue(recorder.pendingSeries.isEmpty)
    }

    func testFlushingWritesTheDayAndClearsIt() throws {
        let store = RecordingRhythmStore()
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.flush(at: moment(14, 1))

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved[0].day, moment(0))
        XCTAssertTrue(recorder.pendingSeries.isEmpty)
    }

    func testANewDayFlushesTheOldOneFirst() throws {
        let store = RecordingRhythmStore()
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(23, 58))
        recorder.record(snapshot(fraction: 0.3), kind: .claude, at: calendar.date(byAdding: .day, value: 1, to: moment(0))!)

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved[0].day, moment(0))
    }

    func testWritingTheDayTwiceKeepsBothParts() throws {
        let store = RecordingRhythmStore()
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.flush(at: moment(14, 1))
        recorder.record(snapshot(fraction: 0.35), kind: .claude, at: moment(14, 5))
        recorder.flush(at: moment(14, 6))

        XCTAssertEqual(store.saved.count, 2)
        let series = try XCTUnwrap(store.saved[1].series.first)
        // The second write holds the burn of both readings, not only the one after the first write.
        XCTAssertEqual(series.points[168], 0.15, accuracy: 0.0001)
        XCTAssertEqual(series.samples[168], 1)
        XCTAssertEqual(series.samples[169], 1)
    }

    func testTheRecorderContinuesADayAnotherRunStarted() throws {
        let store = RecordingRhythmStore()
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

    private func snapshot(fraction: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "account-1",
            displayName: "Claude",
            lines: [.progress(
                label: "Session",
                used: fraction * 100,
                limit: 100,
                format: .percent,
                resetsAt: moment(19, 0),
                periodDurationMs: MetricPeriod.sessionMs
            )]
        )
    }
}

/// A store that keeps what it was given instead of writing files.
final class RecordingRhythmStore: RhythmStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [RhythmDayRecord]())
    var saved: [RhythmDayRecord] { lock.withLock { $0 } }

    func save(_ record: RhythmDayRecord) throws { lock.withLock { $0.append(record) } }
    func load(day: Date) throws -> RhythmDayRecord? { lock.withLock { $0.last { $0.day == day } } }
    func load(days: ClosedRange<Date>) throws -> [RhythmDayRecord] {
        lock.withLock { $0.filter { days.contains($0.day) } }
    }
    func recordedDays() throws -> [Date] { lock.withLock { $0.map(\.day).sorted() } }
    func delete(before date: Date) throws {}
}
