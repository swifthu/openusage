import XCTest
@testable import OpenUsage

/// The rhythm history as one file per day. A day that was never recorded has no file, and a file
/// that was written half way through is skipped rather than taking the whole history with it.
final class RhythmStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rhythm-tests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func day(_ month: Int, _ dayNumber: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: dayNumber))!
    }

    private func makeStore() -> FileRhythmStore {
        FileRhythmStore(directory: directory, calendar: calendar)
    }

    private func fileName(_ month: Int, _ dayNumber: Int) -> String {
        RhythmClock.fileName(for: day(month, dayNumber), calendar: calendar)
    }

    private func record(_ day: Date, points: [Double]) -> RhythmDayRecord {
        RhythmDayRecord(day: day, series: [
            RhythmSeriesRecord(
                key: "account-1/Session",
                kind: .claude,
                label: "Session",
                windowMs: MetricPeriod.sessionMs,
                points: points,
                samples: points.map { _ in 3 }
            )
        ])
    }

    func testASavedDayComesBack() throws {
        let store = makeStore()
        let points = [Double](repeating: 1.5, count: 288)

        try store.save(record(day(11, 6), points: points))

        let loaded = try XCTUnwrap(store.load(day: day(11, 6)))
        XCTAssertEqual(loaded.day, day(11, 6))
        XCTAssertEqual(loaded.series.count, 1)
        XCTAssertEqual(loaded.series[0].points, points)
        XCTAssertEqual(loaded.series[0].kind, .claude)
        XCTAssertEqual(loaded.series[0].windowMs, MetricPeriod.sessionMs)
    }

    func testADayThatWasNeverRecordedHasNoFile() throws {
        let store = makeStore()

        XCTAssertNil(try store.load(day: day(11, 6)))
    }

    func testSavingADayTwiceReplacesIt() throws {
        let store = makeStore()

        try store.save(record(day(11, 6), points: [Double](repeating: 1, count: 288)))
        try store.save(record(day(11, 6), points: [Double](repeating: 2, count: 288)))

        let loaded = try XCTUnwrap(store.load(day: day(11, 6)))
        XCTAssertEqual(loaded.series[0].points.first, 2)
    }

    func testTheRecordedDaysAreListedOldestFirst() throws {
        let store = makeStore()

        try store.save(record(day(11, 8), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 7), points: []))

        XCTAssertEqual(try store.recordedDays(), [day(11, 6), day(11, 7), day(11, 8)])
    }

    func testTheRecordsBeforeADateAreDeleted() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))

        try store.delete(before: day(11, 7))

        XCTAssertEqual(try store.recordedDays(), [day(11, 8)])
    }

    func testTheRecordsOfARangeComeBackOldestFirst() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))

        let loaded = try store.load(days: day(11, 6)...day(11, 8))

        XCTAssertEqual(loaded.map(\.day), [day(11, 6), day(11, 8)])
    }

    func testAFileThatIsNotOursIsRefused() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(fileName(11, 6)))

        XCTAssertThrowsError(try store.load(day: day(11, 6)))
    }

    func testABrokenFileDoesNotTakeTheRangeWithIt() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(fileName(11, 7)))

        let loaded = try store.load(days: day(11, 1)...day(11, 8))

        XCTAssertEqual(loaded.map(\.day), [day(11, 1), day(11, 6), day(11, 8)])
    }

    func testAFileWithAnotherSchemaIsRefused() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = #"{"schema":"openusage.rhythm.v99","series":[]}"#
        try Data(payload.utf8).write(to: directory.appendingPathComponent(fileName(11, 6)))

        XCTAssertThrowsError(try store.load(day: day(11, 6))) { error in
            guard case RhythmStoreError.unknownSchema = error else {
                return XCTFail("expected an unknown schema error, got \(error)")
            }
        }
    }
}
