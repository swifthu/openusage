import XCTest
@testable import OpenUsage

/// The midnight the recorder has to survive: a burn that crosses it, and a day that ended while
/// the app was closed.
///
/// These tests write to a real file store in a temporary directory, because the bug they cover is
/// the file being replaced: a store that only remembers what it was told would not show it.
@MainActor
final class RhythmRecorderMidnightTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// A moment of the day the tests are about.
    private func moment(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: hour, minute: minute))!
    }

    /// The midnight that ends the day the tests are about.
    private var nextDay: Date {
        calendar.date(byAdding: .day, value: 1, to: moment(0))!
    }

    /// Ten minutes past the midnight.
    private var afterMidnight: Date {
        nextDay.addingTimeInterval(600)
    }

    private func store() -> (FileRhythmStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rhythm-midnight-\(UUID().uuidString)", isDirectory: true)
        return (FileRhythmStore(directory: directory, calendar: calendar), directory)
    }

    private func recorder(_ store: FileRhythmStore) -> RhythmRecorder {
        RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
    }

    /// A snapshot with one line per label. The window runs on past the midnight, so a reading
    /// after it is a reading of the same window and not of a reset one.
    private func snapshot(
        fraction: Double,
        at now: Date,
        providerID: String = "account-1",
        labels: [String] = ["Session"]
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            displayName: "Claude",
            lines: labels.map { label in
                .progress(
                    label: label,
                    used: fraction * 100,
                    limit: 100,
                    format: .percent,
                    resetsAt: nextDay.addingTimeInterval(19 * 3600),
                    periodDurationMs: MetricPeriod.sessionMs
                )
            },
            refreshedAt: now
        )
    }

    /// The app was closed across the midnight and opened again: the recorder holds no part of the
    /// day that ended, so it has to take that day back from the store before it books anything
    /// into it. The write of the file store replaces the whole file, so a day that holds only a
    /// fragment of itself would take the whole day with it.
    func testTheDayThatEndedKeepsItsWholeDayOnDisk() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = moment(0)
        // The day that ended, with a whole day of readings on disk.
        let whole = RhythmSeriesRecord(
            key: "account-1/Session",
            kind: .claude,
            label: "Session",
            windowMs: MetricPeriod.sessionMs,
            points: Array(repeating: 0.01, count: 288),
            samples: Array(repeating: 1, count: 288)
        )
        try store.save(RhythmDayRecord(day: day, series: [whole]))

        let recorder = recorder(store)
        // The app was closed at 23:50 and opened again at 00:10. The cache holds the reading of
        // the moment it was closed, and it is the baseline of the first reading of this run.
        recorder.adoptBaseline(snapshot(fraction: 0.4, at: moment(23, 50)), kind: .claude)
        recorder.record(snapshot(fraction: 0.55, at: afterMidnight), kind: .claude, at: afterMidnight)

        let written = try XCTUnwrap(store.load(day: day))
        let series = try XCTUnwrap(written.series.first)
        // The whole day is still there: every bucket of it still holds its reading.
        XCTAssertEqual(series.samples.reduce(0, +), 288)
        // And the part of the burn that crossed the midnight is added to it: ten of the twenty
        // minutes fell before the midnight, so half of the 0.15 is on the day that ended.
        XCTAssertEqual(series.points.reduce(0, +), 2.88 + 0.075, accuracy: 0.0001)
        XCTAssertEqual(series.points[286], 0.01 + 0.0375, accuracy: 0.0001)
        XCTAssertEqual(series.points[287], 0.01 + 0.0375, accuracy: 0.0001)
    }

    /// The rollover is decided per series: every series that crosses the midnight books the part
    /// of its burn that fell before it, and not only the first one.
    func testEverySeriesThatCrossesTheMidnightIsBooked() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = recorder(store)

        // The evening before the midnight: two series of the first account and the series of a
        // second account are read.
        recorder.record(
            snapshot(fraction: 0.4, at: moment(23, 50), labels: ["Session", "Other"]),
            kind: .claude,
            at: moment(23, 50)
        )
        recorder.record(
            snapshot(fraction: 0.2, at: moment(23, 50), providerID: "account-2"),
            kind: .claude,
            at: moment(23, 50)
        )

        // After the midnight every one of them crosses it.
        recorder.record(
            snapshot(fraction: 0.55, at: afterMidnight, labels: ["Session", "Other"]),
            kind: .claude,
            at: afterMidnight
        )
        recorder.record(
            snapshot(fraction: 0.35, at: afterMidnight, providerID: "account-2"),
            kind: .claude,
            at: afterMidnight
        )

        let ended = try XCTUnwrap(store.load(day: moment(0)))
        XCTAssertEqual(ended.series.count, 3)
        for series in ended.series {
            // Half of the burn fell before the midnight, so that half is on the day that ended —
            // for every series, and not only for the first one that crossed.
            XCTAssertEqual(series.points.reduce(0, +), 0.075, accuracy: 0.0001)
        }

        recorder.flush(at: nextDay.addingTimeInterval(3600))
        let begun = try XCTUnwrap(store.load(day: nextDay))
        XCTAssertEqual(begun.series.count, 3)
        for series in begun.series {
            // The other half is on the day that began, so nothing of the burn is lost.
            XCTAssertEqual(series.points.reduce(0, +), 0.075, accuracy: 0.0001)
        }
    }

    // MARK: - The files the store refuses

    /// A file the store refuses: it holds 300 buckets where the day has 288, so its buckets do
    /// not fit the day it is read on. The store skips it with a warning.
    private func refusedPayload(day: String, buckets: Int = 300) -> String {
        let points = Array(repeating: "0.5", count: buckets).joined(separator: ",")
        let samples = Array(repeating: "7", count: buckets).joined(separator: ",")
        return """
        {"schema":"openusage.rhythm.v1","day":"\(day)","series":[{"key":"account-1/Session","kind":"claude","label":"Session","windowMs":\(MetricPeriod.sessionMs),"points":[\(points)],"samples":[\(samples)]}]}
        """
    }

    /// Writes a file as it is, without the store's own encoding.
    private func writeRaw(_ directory: URL, _ name: String, _ payload: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: directory.appendingPathComponent(name))
    }

    /// Reads a file back as it is on disk.
    private func readRaw(_ directory: URL, _ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The day that ended had a file the store refuses, and the recorder held that day in memory
    /// because the app ran on it before the midnight. The file must come out exactly as it went
    /// in: the recorder does not know what it holds, and replacing it with what the recorder has
    /// would destroy it.
    func testAFileTheStoreRefusedIsNotWrittenOver() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "2026-11-06.json"
        let payload = refusedPayload(day: "2026-11-06")
        try writeRaw(directory, name, payload)

        let recorder = recorder(store)
        // The app runs on that day, so the recorder holds it when the midnight comes.
        recorder.record(snapshot(fraction: 0.2, at: moment(23, 50)), kind: .claude, at: moment(23, 50))
        recorder.record(snapshot(fraction: 0.55, at: afterMidnight), kind: .claude, at: afterMidnight)

        XCTAssertEqual(
            try readRaw(directory, name),
            Data(payload.utf8),
            "the refused file is left exactly as it was"
        )
    }

    /// The same, but the app was closed across the midnight, so the recorder never held the day
    /// that ended.
    func testAFileTheStoreRefusedIsNotWrittenOverWhenItWasNeverHeld() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "2026-11-06.json"
        let payload = refusedPayload(day: "2026-11-06")
        try writeRaw(directory, name, payload)

        let recorder = recorder(store)
        recorder.adoptBaseline(snapshot(fraction: 0.4, at: moment(23, 50)), kind: .claude)
        recorder.record(snapshot(fraction: 0.55, at: afterMidnight), kind: .claude, at: afterMidnight)

        XCTAssertEqual(
            try readRaw(directory, name),
            Data(payload.utf8),
            "the refused file is left exactly as it was"
        )
    }

    /// The current day's file is refused: it is left exactly as it was, and the day records
    /// nothing, because the app cannot merge with a file it cannot read.
    func testAFileTheStoreRefusedIsNotWrittenOverForTheCurrentDay() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "2026-11-07.json"
        let payload = refusedPayload(day: "2026-11-07")
        try writeRaw(directory, name, payload)

        let recorder = recorder(store)
        recorder.record(snapshot(fraction: 0.55, at: afterMidnight), kind: .claude, at: afterMidnight)
        recorder.flush(at: afterMidnight)

        XCTAssertEqual(
            try readRaw(directory, name),
            Data(payload.utf8),
            "the refused file is left exactly as it was"
        )
        XCTAssertTrue(recorder.pendingDays.isEmpty, "the day records nothing")
    }

    /// The second account crosses the midnight five minutes after the first one did, by which
    /// time the day that ended has been written and let go of the memory. The recorder has to
    /// take that day back from the store, and both accounts keep their own part of the night.
    func testAnAccountThatCrossesLaterStillBooksItsPartOfTheNight() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = recorder(store)

        // Both accounts are read before the midnight.
        recorder.record(
            snapshot(fraction: 0.4, at: moment(23, 50), providerID: "account-1"),
            kind: .claude,
            at: moment(23, 50)
        )
        recorder.record(
            snapshot(fraction: 0.4, at: moment(23, 50), providerID: "account-2"),
            kind: .claude,
            at: moment(23, 50)
        )

        // The first account crosses ten minutes after the midnight. It burned 0.15 over the
        // twenty minutes since its last reading, and ten of those twenty minutes fell before the
        // midnight, so half of the burn belongs to the day that ended.
        recorder.record(
            snapshot(fraction: 0.55, at: afterMidnight, providerID: "account-1"),
            kind: .claude,
            at: afterMidnight
        )

        // The second one crosses five minutes later. It burned 0.25 over twenty-five minutes, and
        // ten of those fell before the midnight, so two fifths of the burn belongs to the day
        // that ended.
        recorder.record(
            snapshot(fraction: 0.65, at: nextDay.addingTimeInterval(900), providerID: "account-2"),
            kind: .claude,
            at: nextDay.addingTimeInterval(900)
        )

        let ended = try XCTUnwrap(store.load(day: moment(0)))
        XCTAssertEqual(ended.series.count, 2, "both accounts are on the day that ended")
        let burned = Dictionary(uniqueKeysWithValues: ended.series.map { ($0.key, $0.points.reduce(0, +)) })
        XCTAssertEqual(
            burned["account-1/Session"] ?? 0,
            0.075,
            accuracy: 0.0001,
            "half of the first account's burn fell before the midnight"
        )
        XCTAssertEqual(
            burned["account-2/Session"] ?? 0,
            0.1,
            accuracy: 0.0001,
            "two fifths of the second account's burn fell before the midnight"
        )
    }
}
