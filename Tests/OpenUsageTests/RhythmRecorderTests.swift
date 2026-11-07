import XCTest
@testable import OpenUsage

/// The recorder differences one refresh against the last one, so the history says how much of a
/// window was burned and when. The rules of the difference themselves are in
/// `RhythmRecorderTestsRules`.
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

    /// A burn that crosses midnight is booked on both days: the part before midnight on the day
    /// that ended, the part after midnight on the day that began. The window did not reset in
    /// between, so nothing of the burn is lost.
    func testABurnThatCrossesMidnightIsBookedOnBothDays() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: moment(0))!
        // The window runs on past the midnight, so the two readings describe the same window.
        let resets = calendar.date(byAdding: .day, value: 1, to: moment(19, 0))!

        recorder.record(snapshot(fraction: 0.4, resetsAt: resets), kind: .claude, at: moment(23, 50))
        recorder.record(snapshot(fraction: 0.55, resetsAt: resets), kind: .claude, at: nextDay.addingTimeInterval(600))

        // The part before the midnight belongs to the day that ended. Ten of the twenty minutes
        // fell in it, so each of its two buckets carries a quarter of the 0.15 that was burned.
        let ended = try XCTUnwrap(store.saved.first { $0.day == moment(0) })
        let endedSeries = try XCTUnwrap(ended.series.first)
        XCTAssertEqual(endedSeries.points[286], 0.0375, accuracy: 0.0001)
        XCTAssertEqual(endedSeries.points[287], 0.0375, accuracy: 0.0001)

        // The part after the midnight belongs to the day that began.
        let begun = try XCTUnwrap(recorder.pendingSeries.first)
        XCTAssertEqual(begun.points[0], 0.0375, accuracy: 0.0001)
        XCTAssertEqual(begun.points[1], 0.0375, accuracy: 0.0001)

        // The whole burn is booked, not one part of it.
        XCTAssertEqual(
            endedSeries.points.reduce(0, +) + begun.points.reduce(0, +),
            0.15,
            accuracy: 0.0001
        )
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

    func testADayThatIsAlreadyOnDiskIsLetGoWhenTheDayTurnsOver() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: moment(0))!

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(23, 58))
        recorder.flush(at: moment(23, 59))
        // The day is on disk now, so nothing of it is waiting to be written.
        XCTAssertEqual(store.saved.count, 1)

        recorder.record(snapshot(fraction: 0.3), kind: .claude, at: nextDay)

        // The day that ended is on disk and has nothing new, so the recorder lets it go.
        XCTAssertFalse(recorder.heldDays.contains(moment(0)))
        // The day that is being recorded is still held, because it is still being added to.
        XCTAssertTrue(recorder.heldDays.contains(nextDay))
    }

    func testAFailedWriteDoesNotStopTheRecordingFromBeingTurnedOff() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        store.setFailing(true)
        let settings = RhythmSettings(defaults: isolatedDefaults())
        let recorder = RhythmRecorder(store: store, settings: settings, calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.record(snapshot(fraction: 0.35), kind: .claude, at: moment(14, 5))
        // The write that was due failed, and it is not tried again right away.
        XCTAssertEqual(store.saveAttempts, 1)
        XCTAssertTrue(store.saved.isEmpty)

        store.setFailing(false)
        settings.isEnabled = false
        recorder.record(snapshot(fraction: 0.5), kind: .claude, at: moment(14, 6))

        // Turning the recording off writes what was already recorded, even though the last write
        // failed a moment ago.
        XCTAssertEqual(store.saveAttempts, 2)
        let series = try XCTUnwrap(store.saved.first?.series.first)
        XCTAssertEqual(series.samples[168], 1)
        XCTAssertEqual(series.samples[169], 1)
        XCTAssertEqual(series.points[168], 0.15, accuracy: 0.0001)
        // The reading that arrived after the recording was turned off is not recorded.
        XCTAssertEqual(series.samples[170], 0)
    }

    func testADiskThatCannotBeWrittenIsNotWrittenOnEveryRefreshAfterTheRecordingIsTurnedOff() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        store.setFailing(true)
        let settings = RhythmSettings(defaults: isolatedDefaults())
        let recorder = RhythmRecorder(store: store, settings: settings, calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        XCTAssertEqual(store.saveAttempts, 0)

        settings.isEnabled = false
        recorder.record(snapshot(fraction: 0.35), kind: .claude, at: moment(14, 1))
        // The first write after the switch is the user's own request, so it is tried even though
        // the disk cannot be written.
        XCTAssertEqual(store.saveAttempts, 1)

        recorder.record(snapshot(fraction: 0.4), kind: .claude, at: moment(14, 2))
        recorder.record(snapshot(fraction: 0.45), kind: .claude, at: moment(14, 3))
        recorder.record(snapshot(fraction: 0.5), kind: .claude, at: moment(14, 4))

        // The retries after the first one wait out the backoff, so a disk that cannot be written
        // does not produce a warning for every refresh.
        XCTAssertEqual(store.saveAttempts, 1)

        // Once the backoff has passed, the write is tried again.
        recorder.record(snapshot(fraction: 0.55), kind: .claude, at: moment(14, 7))
        XCTAssertEqual(store.saveAttempts, 2)
    }

    func testTheStoreListsEveryDayOnce() throws {
        let store = RecordingRhythmStore(calendar: calendar)

        try store.save(RhythmDayRecord(day: moment(0), series: []))
        try store.save(RhythmDayRecord(day: moment(0), series: []))

        // A day that was written twice is one day, as it is for the file store.
        XCTAssertEqual(try store.recordedDays(), [moment(0)])
    }

    func testForgettingTheReadingsStartsANewBaseline() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        // The account behind the slot may be a different one now, so its old reading is dropped.
        recorder.forgetReadings(for: "account-1")
        recorder.record(snapshot(fraction: 0.9), kind: .claude, at: moment(14, 5))

        let pending = try XCTUnwrap(recorder.pendingSeries.first)
        // The jump is that other account's state, not consumption, so nothing is booked.
        XCTAssertEqual(pending.points.reduce(0, +), 0, accuracy: 0.0001)
        // Both readings are samples.
        XCTAssertEqual(pending.samples.reduce(0, +), 2)

        // The reading after the new baseline is differenced against it.
        recorder.record(snapshot(fraction: 0.95), kind: .claude, at: moment(14, 10))
        XCTAssertEqual(recorder.pendingSeries.first?.points.reduce(0, +) ?? 0, 0.05, accuracy: 0.0001)
    }

    func testForgettingTheReadingsOfOneProviderLeavesTheOther() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)

        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(14, 0))
        recorder.record(snapshot(fraction: 0.1, providerID: "account-2"), kind: .claude, at: moment(14, 0))

        recorder.forgetReadings(for: "account-1")

        recorder.record(snapshot(fraction: 0.9), kind: .claude, at: moment(14, 5))
        recorder.record(snapshot(fraction: 0.25, providerID: "account-2"), kind: .claude, at: moment(14, 5))

        let series = recorder.pendingSeries
        let first = try XCTUnwrap(series.first { $0.key == "account-1/Session" })
        let second = try XCTUnwrap(series.first { $0.key == "account-2/Session" })
        // The forgotten provider booked nothing.
        XCTAssertEqual(first.points.reduce(0, +), 0, accuracy: 0.0001)
        // The other provider still books the 0.15 it burned.
        XCTAssertEqual(second.points.reduce(0, +), 0.15, accuracy: 0.0001)
    }

    /// The error of a failed write is only cleared when the day that failed is written. The
    /// success of another day does not hide it from the user.
    func testTheErrorOfAFailedWriteIsNotClearedByAnotherDaysSuccess() throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: moment(0))!

        // The write of the day that ended fails.
        store.setFailing(true, on: moment(0))
        recorder.record(snapshot(fraction: 0.2), kind: .claude, at: moment(23, 50))
        recorder.flush(at: moment(23, 51))
        XCTAssertNotNil(recorder.lastWriteError)

        // The next day is written and its write lands.
        recorder.record(snapshot(fraction: 0.3), kind: .claude, at: nextDay)
        recorder.flush(at: nextDay)
        XCTAssertNotNil(recorder.lastWriteError, "the day that could not be written is still not on disk")

        // The day that failed is written, so the error goes away.
        store.setFailing(false, on: moment(0))
        recorder.flush(at: nextDay.addingTimeInterval(600))
        XCTAssertNil(recorder.lastWriteError)
    }

    private func snapshot(fraction: Double, resetsAt: Date? = nil, providerID: String = "account-1") -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
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
