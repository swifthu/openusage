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

    private func makeStore(retentionDays: Int) -> FileRhythmStore {
        FileRhythmStore(directory: directory, calendar: calendar, retentionDays: retentionDays)
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

    func testTwoBundleIdentifiersGiveTwoDifferentFolders() {
        let installed = FileRhythmStore.directory(forBundleIdentifier: "com.example.openusage")
        let development = FileRhythmStore.directory(forBundleIdentifier: "com.example.openusage.dev")

        // Two builds must not land in one folder, or they read each other's history.
        XCTAssertNotEqual(installed, development)
        XCTAssertNotEqual(installed.lastPathComponent, development.lastPathComponent)
        // Both live in the same rhythm folder, side by side.
        XCTAssertEqual(installed.deletingLastPathComponent().lastPathComponent, "rhythm")
        XCTAssertEqual(development.deletingLastPathComponent().lastPathComponent, "rhythm")
        XCTAssertEqual(installed.deletingLastPathComponent(), development.deletingLastPathComponent())
    }

    func testAnIdentifierWithASlashBecomesANestedFolder() {
        let rhythm = FileRhythmStore.directory(forBundleIdentifier: nil).deletingLastPathComponent()
        let directory = FileRhythmStore.directory(forBundleIdentifier: "com.example/openusage")

        // The slash makes the identifier a folder inside the rhythm folder, one level deeper.
        XCTAssertTrue(directory.path.hasPrefix(rhythm.path))
        XCTAssertEqual(directory.pathComponents.count, rhythm.pathComponents.count + 2)
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

    func testAFolderThatWasNeverCreatedHasNoDays() throws {
        let store = makeStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        XCTAssertEqual(try store.recordedDays(), [])
    }

    func testAFailedRemovalIsThrownRatherThanSwallowed() throws {
        try XCTSkipIf(getuid() == 0, "root ignores the folder's permissions")
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        // A folder that cannot be written to refuses the removal, which the caller has to hear
        // about: it would otherwise log a deletion that did not happen.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        XCTAssertThrowsError(try store.delete(before: day(11, 7)))
    }

    func testTheDaysOlderThanTheRetentionAreRemovedWhenADayIsWritten() throws {
        let store = makeStore(retentionDays: 3)

        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 2), points: []))
        try store.save(record(day(11, 3), points: []))
        try store.save(record(day(11, 4), points: []))

        // Three days are kept, the day that was written and the two before it.
        XCTAssertEqual(try store.recordedDays(), [day(11, 2), day(11, 3), day(11, 4)])
    }

    func testTheRecordsBeforeADateAreDeleted() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))

        try store.delete(before: day(11, 7))

        XCTAssertEqual(try store.recordedDays(), [day(11, 8)])
    }

    func testACutoffInTheAfternoonLeavesThatDayAlone() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))

        let cutoff = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15))!
        try store.delete(before: cutoff)

        XCTAssertEqual(try store.recordedDays(), [day(11, 6)])
    }

    func testTheRecordsOfARangeComeBackOldestFirst() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))

        let loaded = try store.load(days: day(11, 6)...day(11, 8))

        XCTAssertEqual(loaded.map(\.day), [day(11, 6), day(11, 8)])
    }

    func testARangeThatDoesNotStartAtMidnightStillIncludesItsBoundaryDays() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))

        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 15))!
        let loaded = try store.load(days: start...end)

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
