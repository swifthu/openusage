# 使用节奏（Usage Rhythm）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record how fast each account's provider-reported window fills up, keep 90 days of it on this Mac, and show it in a new Dashboard tab that answers "which hours do I burn my quota".

**Architecture:** A new `Sources/OpenUsage/Rhythm/` module with four units: `RhythmStore` (a protocol plus a one-file-per-day local implementation), `RhythmRecorder` (differences each refresh's reading against the last one and accumulates five-minute buckets), `RhythmAnalytics` (pure functions that turn buckets into chart bars), and the SwiftUI tab. The recorder hangs off `WidgetDataStore.refresh` after a successful read, so a failed refresh leaves a hole in the chart rather than a zero.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Foundation. No new dependencies.

**Design document:** `docs/superpowers/specs/2026-11-06-usage-rhythm-design.md`

## Global Constraints

- Every task below runs in the repo at `/Volumes/CC/Fork/openusage`, on the branch `feat/usage-velocity-tracker`. Never commit to `main`. Never push to `origin` — that is the upstream `robinebers/openusage`. Only `swifthu/openusage` may ever be pushed to.
- **Build on the local disk.** This checkout is on a network volume, where SwiftPM's build database, index store and module cache get corrupted. Always `swift build --scratch-path "$HOME/build"`.
- **Run tests with `script/test_quiet.sh`**, never `swift test` — the suite hosts real windows and takes the keyboard and the screen. `script/test_quiet.sh` already defaults to the local scratch path; pass `--filter <Suite>` to narrow it.
- Swift 6 strict concurrency. `RhythmStore` and everything it hands out are `Sendable`; `RhythmRecorder` is `@MainActor`.
- Copy used as a title is title case: "Rhythm", "All Day", "12 Hours", "6 Hours", "2 Hours".
- The repo bans yellow in sources (`SeverityPaletteTests.testSourcesNeverUseYellow` greps for `systemYellow` and `.yellow`). The chart uses `Theme.severityColor(.normal)`, which is `systemBlue`.
- Files stay under roughly 500 lines. Split a file that grows past that.
- No new dependencies.
- `AGENTS.md` gains a fifth divergence section; the sync-cadence section becomes the sixth.
- Commit after every task.

---

## File Structure

**New source files**

| File | Responsibility |
|---|---|
| `Sources/OpenUsage/Rhythm/RhythmModels.swift` | The data types: `RhythmSeries`, `RhythmSeriesRecord`, `RhythmDayRecord`, `RhythmReading`, `RhythmDelta`, `RhythmBucketShare` |
| `Sources/OpenUsage/Rhythm/RhythmClock.swift` | The five-minute grid: bucket count, bucket index, bucket start, day file names, and the split of an interval across buckets |
| `Sources/OpenUsage/Rhythm/RhythmStore.swift` | The `RhythmStore` protocol, `FileRhythmStore`, and `RhythmStoreError` |
| `Sources/OpenUsage/Rhythm/RhythmRecorder.swift` | `RhythmDifferencer` (pure) and `RhythmRecorder` (the state machine that accumulates buckets and flushes them) |
| `Sources/OpenUsage/Rhythm/RhythmAnalytics.swift` | `RhythmBar`, `RhythmZoom`, and the pure functions that turn records into bars, averages and peak ranges |
| `Sources/OpenUsage/Views/RhythmChart.swift` | The bar chart |
| `Sources/OpenUsage/Views/RhythmContextStrip.swift` | The whole-day overview with the draggable window |
| `Sources/OpenUsage/Views/RhythmView.swift` | The tab: mode switch, day picker, zoom slider, summary line |

**New store file**

- `Sources/OpenUsage/Stores/RhythmSettings.swift` — the on/off switch and the retention length

**New test files**

- `Tests/OpenUsageTests/RhythmClockTests.swift`
- `Tests/OpenUsageTests/RhythmStoreTests.swift`
- `Tests/OpenUsageTests/RhythmRecorderTests.swift`
- `Tests/OpenUsageTests/RhythmAnalyticsTests.swift`
- `Tests/OpenUsageTests/RhythmChartTests.swift`

**Modified files**

| File | Change |
|---|---|
| `Sources/OpenUsage/Stores/WidgetDataStore.swift` | Take a recorder and call it after a successful refresh |
| `Sources/OpenUsage/App/AppContainer.swift` | Build the recorder and the setting, pass the recorder to the data store |
| `Sources/OpenUsage/Models/DashboardTab.swift` | Add the `rhythm` case |
| `Sources/OpenUsage/Views/DashboardContentView.swift` | Show `RhythmView` for the new tab |
| `Sources/OpenUsage/Views/SettingsScreen.swift` | The switch and the "Delete History" button |
| `Sources/OpenUsage/Support/AppLog.swift` | Add the `rhythm` log tag |
| `AGENTS.md` | The fifth divergence section |
| `docs/rhythm.md` | New user documentation |
| `docs/dashboard.md` | A section pointing at `docs/rhythm.md` |

---

### Task 1: The grid and the day files

The five-minute grid and the file store. Together they are the layer everything else reads and writes, so they land first and get their own tests.

**Files:**
- Create: `Sources/OpenUsage/Rhythm/RhythmModels.swift`
- Create: `Sources/OpenUsage/Rhythm/RhythmClock.swift`
- Create: `Sources/OpenUsage/Rhythm/RhythmStore.swift`
- Test: `Tests/OpenUsageTests/RhythmClockTests.swift`
- Test: `Tests/OpenUsageTests/RhythmStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct RhythmSeries: Hashable, Sendable, Codable` with `key: String`, `kind: ProviderKind`, `label: String`, `windowMs: Int`
  - `struct RhythmSeriesRecord: Hashable, Sendable, Codable` with `key`, `kind`, `label`, `windowMs`, `points: [Double]`, `samples: [Int]`
  - `struct RhythmDayRecord: Hashable, Sendable` with `day: Date`, `series: [RhythmSeriesRecord]`, and `static let currentSchema = "openusage.rhythm.v1"`
  - `struct RhythmReading: Hashable, Sendable` with `key`, `kind`, `label`, `windowMs`, `fraction: Double`, `resetsAt: Date?`, `at: Date`
  - `struct RhythmDelta: Hashable, Sendable` with `points: Double`, `buckets: [RhythmBucketShare]`
  - `struct RhythmBucketShare: Hashable, Sendable` with `index: Int`, `share: Double`
  - `enum RhythmClock` with `bucketSeconds`, `bucketCount(on:calendar:)`, `bucketIndex(for:on:calendar:)`, `start(of:on:calendar:)`, `shares(from:to:day:calendar:)`, `fileName(for:calendar:)`, `day(fromFileName:calendar:)`
  - `protocol RhythmStore: Sendable` with `save(_:)`, `load(day:)`, `load(days:)`, `recordedDays()`, `delete(before:)`
  - `struct FileRhythmStore: RhythmStore` with `init(directory:calendar:)` — the calendar decides which file a moment belongs to, so the store must be told which one rather than reaching for `Calendar.current` — and `static var defaultDirectory: URL`
  - `enum RhythmStoreError: LocalizedError` with `unknownSchema(String)`
  - `LogTag.rhythm` — the log tag the rhythm feature writes under

- [ ] **Step 1: Write the failing clock tests**

Create `Tests/OpenUsageTests/RhythmClockTests.swift`:

```swift
import XCTest
@testable import OpenUsage

/// The five-minute grid the rhythm history sits on. The bucket count follows the local calendar,
/// so a day that loses an hour to daylight saving has fewer buckets than one that gains an hour.
final class RhythmClockTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // A zone that keeps daylight saving, so the bucket count really does change with the
        // season. Asia/Shanghai abolished daylight saving in 1991 and would never show it.
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testANormalDayHasTwoHundredAndEightyEightBuckets() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!

        XCTAssertEqual(RhythmClock.bucketCount(on: day, calendar: calendar), 288)
    }

    func testADayThatLosesAnHourHasFewerBuckets() {
        // 2026-03-08: the clocks go forward at 02:00 in this zone, so the day is 23 hours long.
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!

        XCTAssertEqual(RhythmClock.bucketCount(on: day, calendar: calendar), 276)
    }

    func testADayThatGainsAnHourHasMoreBuckets() {
        // 2026-11-01: the clocks go back at 02:00, so the day is 25 hours long.
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!

        XCTAssertEqual(RhythmClock.bucketCount(on: day, calendar: calendar), 300)
    }

    func testAMomentFallsInTheBucketItsFiveMinutesSuggest() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let moment = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 17))!

        XCTAssertEqual(RhythmClock.bucketIndex(for: moment, on: day, calendar: calendar), 171)
    }

    func testAMomentOutsideTheDayHasNoBucket() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7))!

        XCTAssertNil(RhythmClock.bucketIndex(for: nextDay, on: day, calendar: calendar))
    }

    func testAnIntervalIsSplitAcrossTheBucketsItTouches() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 3))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 8))!

        let shares = RhythmClock.shares(from: start, to: end, day: day, calendar: calendar)

        XCTAssertEqual(shares.count, 2)
        XCTAssertEqual(shares[0].index, 168)
        XCTAssertEqual(shares[1].index, 169)
        XCTAssertEqual(shares[0].share, 0.4, accuracy: 0.001)
        XCTAssertEqual(shares[1].share, 0.6, accuracy: 0.001)
        XCTAssertEqual(shares[0].share + shares[1].share, 1, accuracy: 0.001)
    }

    func testADayFileNameCarriesItsDate() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!

        XCTAssertEqual(RhythmClock.fileName(for: day, calendar: calendar), "2026-11-06.json")
        XCTAssertEqual(
            RhythmClock.day(fromFileName: "2026-11-06.json", calendar: calendar),
            calendar.startOfDay(for: day)
        )
    }
}
```

- [ ] **Step 2: Run the clock tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmClockTests`

Expected: FAIL — `cannot find 'RhythmClock' in scope`.

- [ ] **Step 3: Write the models**

Create `Sources/OpenUsage/Rhythm/RhythmModels.swift`:

```swift
import Foundation

/// One account's one metric, tracked over time.
struct RhythmSeries: Hashable, Sendable, Codable {
    /// The account's card id and the metric's label, joined so two accounts' metrics never collide.
    var key: String
    /// The provider the account belongs to, so the chart can group a family's accounts.
    var kind: ProviderKind
    /// The metric's label, e.g. "Session".
    var label: String
    /// The length of the window the metric counts down in, in milliseconds.
    var windowMs: Int
}

/// One series' buckets for one day.
struct RhythmSeriesRecord: Hashable, Sendable, Codable {
    var key: String
    var kind: ProviderKind
    var label: String
    var windowMs: Int
    /// One entry per five-minute bucket: how much of the window that bucket burned, in points.
    var points: [Double]
    /// One entry per bucket: how many samples landed in it. Zero means nothing was read, which is
    /// not the same as nothing being used.
    var samples: [Int]

    var series: RhythmSeries {
        RhythmSeries(key: key, kind: kind, label: label, windowMs: windowMs)
    }
}

/// Everything recorded for one local day.
struct RhythmDayRecord: Hashable, Sendable {
    /// The version of the on-disk format. A file with another version is skipped, not guessed at.
    static let currentSchema = "openusage.rhythm.v1"

    /// The day's local midnight.
    var day: Date
    /// One entry per series tracked that day.
    var series: [RhythmSeriesRecord]
}

/// What one reading of one series says.
struct RhythmReading: Hashable, Sendable {
    var key: String
    var kind: ProviderKind
    var label: String
    var windowMs: Int
    /// The share of the window that had been used, 0...1.
    var fraction: Double
    /// When the window this reading describes resets.
    var resetsAt: Date?
    /// When the reading was taken.
    var at: Date
}

/// How much of a window was burned between two readings, and the buckets it belongs to.
struct RhythmDelta: Hashable, Sendable {
    /// The share of the window that was burned, in points. Never more than one.
    var points: Double
    /// Where the burned share goes.
    var buckets: [RhythmBucketShare]
}

/// One bucket's share of a delta.
struct RhythmBucketShare: Hashable, Sendable {
    var index: Int
    /// How much of the delta falls in this bucket, 0...1.
    var share: Double
}
```

- [ ] **Step 4: Write the clock**

Create `Sources/OpenUsage/Rhythm/RhythmClock.swift`:

```swift
import Foundation

/// The five-minute grid the rhythm history sits on. The bucket count follows the local calendar,
/// so a day that loses an hour to daylight saving has fewer buckets and one that gains an hour has
/// more. The bucket an instant falls in is measured in real seconds from the day's midnight, so
/// the hour a day repeats is recorded twice rather than merged.
enum RhythmClock {
    /// The length of one bucket, in seconds.
    static let bucketSeconds: TimeInterval = 5 * 60

    /// How many buckets the day has.
    static func bucketCount(on day: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return Int((end.timeIntervalSince(start) / bucketSeconds).rounded())
    }

    /// The bucket an instant falls in, nil when it is outside the day.
    static func bucketIndex(for date: Date, on day: Date, calendar: Calendar = .current) -> Int? {
        let start = calendar.startOfDay(for: day)
        let offset = date.timeIntervalSince(start)
        let count = bucketCount(on: day, calendar: calendar)
        guard offset >= 0, offset < Double(count) * bucketSeconds else { return nil }
        return Int(offset / bucketSeconds)
    }

    /// The start of a bucket.
    static func start(of index: Int, on day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(
            byAdding: .second,
            value: index * Int(bucketSeconds),
            to: calendar.startOfDay(for: day)
        ) ?? day
    }

    /// The buckets an interval touches, and the share of it that falls in each.
    ///
    /// The shares are fractions of the **whole** interval, and they cover only the part of it
    /// that falls inside `day`. The interval's **start** has to be inside `day` as well: an
    /// interval that began before the day's midnight covers nothing in that day and returns
    /// nothing. A caller that differences two readings across midnight therefore loses that
    /// whole interval's consumption — at most one refresh interval (five minutes) once per day,
    /// the same order as the use before a provider's window resets that the recorder also does
    /// not see.
    static func shares(
        from start: Date,
        to end: Date,
        day: Date,
        calendar: Calendar = .current
    ) -> [RhythmBucketShare] {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return [] }

        let count = bucketCount(on: day, calendar: calendar)
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(Double(count) * bucketSeconds)
        // An interval that ends on the next midnight belongs to this day, up to its last bucket.
        let clampedEnd = min(end, dayEnd)

        let first: Int
        let last: Int
        if let index = bucketIndex(for: start, on: day, calendar: calendar) {
            first = index
        } else {
            return []
        }
        if let index = bucketIndex(for: clampedEnd, on: day, calendar: calendar) {
            last = index
        } else {
            // The end landed exactly on the day's boundary, so it is the day's last bucket.
            last = count - 1
        }
        guard last >= first else { return [] }

        var result: [RhythmBucketShare] = []
        for index in first...last {
            let bucketStart = self.start(of: index, on: day, calendar: calendar)
            let bucketEnd = bucketStart.addingTimeInterval(bucketSeconds)
            let overlap = min(bucketEnd, end).timeIntervalSince(max(bucketStart, start))
            guard overlap > 0 else { continue }
            result.append(RhythmBucketShare(index: index, share: overlap / total))
        }
        return result
    }

    /// The name a day's file carries.
    static func fileName(for day: Date, calendar: Calendar = .current) -> String {
        formatter(calendar: calendar).string(from: day) + ".json"
    }

    /// The day a file name carries, nil when the name is not one of ours.
    static func day(fromFileName name: String, calendar: Calendar = .current) -> Date? {
        guard name.hasSuffix(".json") else { return nil }
        guard let day = formatter(calendar: calendar).date(from: String(name.dropLast(5))) else { return nil }
        return calendar.startOfDay(for: day)
    }

    private static func formatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
```

- [ ] **Step 5: Run the clock tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmClockTests`

Expected: PASS — 7 tests, 0 failures.

- [ ] **Step 6: Write the failing store tests**

Create `Tests/OpenUsageTests/RhythmStoreTests.swift`:

```swift
import XCTest
@testable import OpenUsage

/// The rhythm history as one file per day. A day that was never recorded has no file, and a file
/// that was written half way through is skipped rather than taking the whole history with it.
final class RhythmStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // The teardown block captures the URL, not `self`: Swift 6's strict concurrency rejects a
        // teardown block that captures the test case.
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
        let store = FileRhythmStore(directory: directory, calendar: calendar)
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
        let store = FileRhythmStore(directory: directory, calendar: calendar)

        XCTAssertNil(try store.load(day: day(11, 6)))
    }

    func testSavingADayTwiceReplacesIt() throws {
        let store = FileRhythmStore(directory: directory, calendar: calendar)

        try store.save(record(day(11, 6), points: [Double](repeating: 1, count: 288)))
        try store.save(record(day(11, 6), points: [Double](repeating: 2, count: 288)))

        let loaded = try XCTUnwrap(store.load(day: day(11, 6)))
        XCTAssertEqual(loaded.series[0].points.first, 2)
    }

    func testTheRecordedDaysAreListedOldestFirst() throws {
        let store = FileRhythmStore(directory: directory, calendar: calendar)

        try store.save(record(day(11, 8), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 7), points: []))

        XCTAssertEqual(try store.recordedDays(), [day(11, 6), day(11, 7), day(11, 8)])
    }

    func testTheRecordsBeforeADateAreDeleted() throws {
        let store = FileRhythmStore(directory: directory, calendar: calendar)
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))

        try store.delete(before: day(11, 7))

        XCTAssertEqual(try store.recordedDays(), [day(11, 8)])
    }

    func testTheRecordsOfARangeComeBackOldestFirst() throws {
        let store = FileRhythmStore(directory: directory, calendar: calendar)
        try store.save(record(day(11, 1), points: []))
        try store.save(record(day(11, 6), points: []))
        try store.save(record(day(11, 8), points: []))

        let loaded = try store.load(days: day(11, 6)...day(11, 8))

        XCTAssertEqual(loaded.map(\.day), [day(11, 6), day(11, 8)])
    }

    func testAFileThatIsNotOursIsSkipped() throws {
        let store = FileRhythmStore(directory: directory, calendar: calendar)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("2026-11-06.json"))

        XCTAssertThrowsError(try store.load(day: day(11, 6)))
    }

    func testAFileWithAnotherSchemaIsRefused() throws {
        let store = FileRhythmStore(directory: directory, calendar: calendar)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = #"{"schema":"openusage.rhythm.v99","series":[]}"#
        try Data(payload.utf8).write(to: directory.appendingPathComponent("2026-11-06.json"))

        XCTAssertThrowsError(try store.load(day: day(11, 6))) { error in
            guard case RhythmStoreError.unknownSchema = error else {
                return XCTFail("expected an unknown schema error, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 7: Run the store tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmStoreTests`

Expected: FAIL — `cannot find 'FileRhythmStore' in scope`.

- [ ] **Step 8: Write the store**

Create `Sources/OpenUsage/Rhythm/RhythmStore.swift`:

```swift
import Foundation

/// A rhythm history that cannot be read.
enum RhythmStoreError: LocalizedError {
    case unknownSchema(String)

    var errorDescription: String? {
        switch self {
        case .unknownSchema(let schema):
            "The rhythm history uses an unknown format (\(schema))."
        }
    }
}

/// Where the rhythm history lives. The local file store is today's implementation; a cloud store
/// that puts the same records elsewhere can be added without touching the recorder or the chart.
protocol RhythmStore: Sendable {
    /// Writes a day's record, replacing what was there.
    func save(_ record: RhythmDayRecord) throws
    /// The record of a day, nil when nothing was recorded for it.
    func load(day: Date) throws -> RhythmDayRecord?
    /// The records of the days in a range, oldest first.
    func load(days: ClosedRange<Date>) throws -> [RhythmDayRecord]
    /// The days that have a record, oldest first.
    func recordedDays() throws -> [Date]
    /// Deletes the records before a date.
    func delete(before date: Date) throws
}

/// The rhythm history as one file per day under Application Support.
struct FileRhythmStore: RhythmStore {
    /// The folder the day files live in.
    let directory: URL
    /// The calendar the days are measured in. It decides which file a moment belongs to, so it has
    /// to be the same one the recorder writes with.
    let calendar: Calendar

    init(directory: URL = FileRhythmStore.defaultDirectory, calendar: Calendar) {
        self.directory = directory
        self.calendar = calendar
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("rhythm", isDirectory: true)
    }

    private struct Payload: Codable {
        var schema: String
        var series: [RhythmSeriesRecord]
    }

    func save(_ record: RhythmDayRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Payload(schema: RhythmDayRecord.currentSchema, series: record.series)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: url(for: record.day), options: .atomic)
    }

    func load(day: Date) throws -> RhythmDayRecord? {
        let file = url(for: day)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: file))
        guard payload.schema == RhythmDayRecord.currentSchema else {
            throw RhythmStoreError.unknownSchema(payload.schema)
        }
        return RhythmDayRecord(day: calendar.startOfDay(for: day), series: payload.series)
    }

    /// A day that cannot be read is skipped: one broken file must not take the whole range with it.
    func load(days: ClosedRange<Date>) throws -> [RhythmDayRecord] {
        // The range names days, so it is compared as days: a range that starts in the afternoon
        // still includes the record of that same day.
        let firstDay = calendar.startOfDay(for: days.lowerBound)
        let lastDay = calendar.startOfDay(for: days.upperBound)
        return try recordedDays()
            .filter { $0 >= firstDay && $0 <= lastDay }
            .compactMap { day in
                do {
                    return try load(day: day)
                } catch {
                    AppLog.warn(.rhythm, "Skipping the unreadable rhythm day file \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
                    return nil
                }
            }
    }

    /// The days that have a record, oldest first. A folder that does not exist yet holds no
    /// records; anything else that goes wrong is thrown, because a history that cannot be read is
    /// not the same as a history that is empty.
    func recordedDays() throws -> [Date] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .compactMap { RhythmClock.day(fromFileName: $0, calendar: calendar) }
            .sorted()
    }

    /// Deletes the records before a date. The date names a day, so it is compared as one.
    func delete(before date: Date) throws {
        let cutoff = calendar.startOfDay(for: date)
        for day in try recordedDays() where day < cutoff {
            try FileManager.default.removeItem(at: url(for: day))
        }
    }

    private func url(for day: Date) -> URL {
        directory.appendingPathComponent(RhythmClock.fileName(for: day, calendar: calendar))
    }
}
```

- [ ] **Step 9: Run the store tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmStoreTests`

Expected: PASS — 8 tests, 0 failures.

- [ ] **Step 10: Commit**

```bash
git add Sources/OpenUsage/Rhythm Tests/OpenUsageTests/RhythmClockTests.swift Tests/OpenUsageTests/RhythmStoreTests.swift
git commit -m "feat(rhythm): add the five-minute grid and the day files"
```

---

### Task 2: Reading a refresh and differencing it

The recorder. It reads a refresh's snapshot, differences it against the last reading of the same series, and accumulates the burned share into the day's five-minute buckets.

**Files:**
- Create: `Sources/OpenUsage/Rhythm/RhythmRecorder.swift`
- Test: `Tests/OpenUsageTests/RhythmRecorderTests.swift`

**Interfaces:**
- Consumes: `RhythmReading`, `RhythmDelta`, `RhythmBucketShare`, `RhythmClock`, `RhythmStore`, `RhythmDayRecord`, `RhythmSeriesRecord` from Task 1.
- Produces:
  - `enum RhythmDifferencer` with `static func delta(from:to:day:calendar:) -> RhythmDelta`
  - `@MainActor final class RhythmRecorder` with
    - `init(store:settings:calendar:flushInterval:)`
    - `func record(_ snapshot: ProviderSnapshot, kind: ProviderKind, at now: Date)`
    - `func flush(at now: Date)`
    - `static func readings(from snapshot: ProviderSnapshot, kind: ProviderKind, at now: Date) -> [RhythmReading]`
    - `var pendingSeries: [RhythmSeriesRecord]` — for tests, the series whose buckets changed since
      the last write. The recorder keeps the whole day in memory and writes all of it, because the
      store's `save` replaces the day's file rather than adding to it.
  - `Sources/OpenUsage/Stores/RhythmSettings.swift` — `@MainActor final class RhythmSettings` with `static let key`, `static let retentionDays = 90`, `var isEnabled: Bool`, `init(defaults:)`

**Note on the reset rule:** the reliable signal that a window reset is `resetsAt`. When the previous reading's `resetsAt` falls at or before the current reading's moment, the two readings describe different windows, so the difference between them is not consumption. Only when a provider reports no `resetsAt` does the recorder fall back to "the reading went down, so the window reset".

- [ ] **Step 1: Write the failing differencer tests**

Create `Tests/OpenUsageTests/RhythmRecorderTests.swift`:

```swift
import XCTest
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
```

- [ ] **Step 2: Run the recorder tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmRecorderTests`

Expected: FAIL — `cannot find 'RhythmRecorder' in scope`.

- [ ] **Step 3: Write the setting**

Create `Sources/OpenUsage/Stores/RhythmSettings.swift`:

```swift
import Foundation
import Observation

/// Whether the app records how fast each account's window fills up, and how long it keeps the
/// history. The history never leaves this Mac.
@MainActor
@Observable
final class RhythmSettings {
    static let key = "recordsUsageRhythm"
    /// How many days of history are kept.
    static let retentionDays = 90
    /// The longest window the rhythm history records: a day. A longer window sampled every few
    /// minutes is a slow drift, and its hourly rate says nothing about when the account is used.
    static let shortWindowMs = MetricPeriod.dayMs

    /// Whether the history is being recorded.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Recording is on by default: the history stays on this Mac, and the switch in Settings
        // turns it off in one step.
        self.isEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}
```

- [ ] **Step 4: Write the recorder**

The recorder holds the **whole day** in memory and writes all of it, because the store's `save`
replaces the day's file rather than adding to it — a recorder that wrote only what was new would
drop the earlier part of the day. It tracks what was last written so it knows what has changed
since, and when the day rolls over it continues from the record the store already holds, so a
restart does not lose the part of the day that came before it.

Create `Sources/OpenUsage/Rhythm/RhythmRecorder.swift`:

```swift
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
```

- [ ] **Step 5: Check the log tag is there**

`Sources/OpenUsage/Support/AppLog.swift` already carries `case rhythm` — Task 1 added it when the
store started logging the days it skips. Confirm it is present; add it if it is not.

```swift
    case rhythm
```

- [ ] **Step 6: Run the recorder tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmRecorderTests`

Expected: PASS — 13 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenUsage/Rhythm/RhythmRecorder.swift Sources/OpenUsage/Stores/RhythmSettings.swift Sources/OpenUsage/Support/AppLog.swift Tests/OpenUsageTests/RhythmRecorderTests.swift
git commit -m "feat(rhythm): record how fast each window fills up"
```

---

### Task 3: Hang the recorder on the refresh

The recorder now exists but nothing calls it. Wire it into `WidgetDataStore` and `AppContainer`, and add the switch that turns it off.

**Files:**
- Modify: `Sources/OpenUsage/Stores/WidgetDataStore.swift` (the `init` and the `refresh` method)
- Modify: `Sources/OpenUsage/App/AppContainer.swift` (the `init`)
- Test: `Tests/OpenUsageTests/RhythmRecorderTests.swift` (add the wiring test)

**Interfaces:**
- Consumes: `RhythmRecorder`, `RhythmSettings`, `FileRhythmStore` from Tasks 1 and 2.
- Produces:
  - `WidgetDataStore.init(..., rhythm: RhythmRecorder? = nil)`
  - `AppContainer.rhythm: RhythmRecorder` and `AppContainer.rhythmSettings: RhythmSettings`

- [ ] **Step 1: Write the failing wiring test**

Append to `Tests/OpenUsageTests/RhythmRecorderTests.swift`:

```swift
    func testASuccessfulRefreshFeedsTheRecorder() async {
        let store = RecordingRhythmStore()
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
        let runtime = StubRuntime(
            provider: Provider(id: "account-1", kind: .claude),
            descriptors: [],
            snapshot: snapshot(fraction: 0.2)
        )
        let dataStore = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), rhythm: recorder)

        await dataStore.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertEqual(recorder.pendingSeries.count, 1)
        XCTAssertEqual(recorder.pendingSeries[0].key, "account-1/Session")
    }

    func testAFailedRefreshFeedsTheRecorderNothing() async {
        let store = RecordingRhythmStore()
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
        let runtime = StubRuntime(
            provider: Provider(id: "account-1", kind: .claude),
            descriptors: [],
            failure: .unreachable
        )
        let dataStore = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), rhythm: recorder)

        await dataStore.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertTrue(recorder.pendingSeries.isEmpty)
    }
```

- [ ] **Step 2: Run the wiring tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmRecorderTests`

Expected: FAIL — `StubRuntime` does not take a `rhythm:` parameter and `WidgetDataStore.forTesting` has no `rhythm:` argument yet.

- [ ] **Step 3: Take the recorder in `WidgetDataStore`**

In `Sources/OpenUsage/Stores/WidgetDataStore.swift`, add the stored property next to the other collaborators:

```swift
    /// Records how fast each account's window fills up. Nil when the app does not record it.
    @ObservationIgnored private let rhythm: RhythmRecorder?
```

Add it to `init`:

```swift
    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout,
        rhythm: RhythmRecorder? = nil
    ) {
```

and assign it:

```swift
        self.rhythm = rhythm
```

Then, in `refresh(providerID:force:)`, right after the snapshot is stored — the line `snapshots[providerID] = snapshot` — record the reading:

```swift
        snapshots[providerID] = snapshot
        // A refresh that failed leaves the hours it covered empty rather than showing as no usage.
        rhythm?.record(snapshot, kind: provider.kind, at: now())
```

- [ ] **Step 4: Let the test helper take a recorder**

In `Tests/OpenUsageTests/TestSupport.swift`, add the parameter to `WidgetDataStore.forTesting`:

```swift
    static func forTesting(
        _ runtimes: [ProviderRuntime],
        registry: WidgetRegistry? = nil,
        cache: ProviderSnapshotCache? = nil,
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout,
        rhythm: RhythmRecorder? = nil
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: registry ?? .from(runtimes),
            providers: runtimes,
            cache: cache ?? ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            now: now,
            providerRefreshTimeout: providerRefreshTimeout,
            rhythm: rhythm
        )
    }
```

- [ ] **Step 5: Build the recorder in `AppContainer`**

In `Sources/OpenUsage/App/AppContainer.swift`, add the two stored properties:

```swift
    let rhythm: RhythmRecorder
    let rhythmSettings: RhythmSettings
```

and in `init`, before the data store is built:

```swift
        let rhythmSettings = RhythmSettings(defaults: defaults)
        let rhythm = RhythmRecorder(
            store: FileRhythmStore(directory: FileRhythmStore.defaultDirectory, calendar: .current),
            settings: rhythmSettings
        )
        self.rhythmSettings = rhythmSettings
        self.rhythm = rhythm
```

and pass the recorder into the data store:

```swift
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults,
            rhythm: rhythm
        )
```

- [ ] **Step 6: Run the recorder tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmRecorderTests`

Expected: PASS — 15 tests, 0 failures.

- [ ] **Step 7: Build the app**

Run: `swift build --scratch-path "$HOME/build"`

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Sources/OpenUsage/Stores/WidgetDataStore.swift Sources/OpenUsage/App/AppContainer.swift Tests/OpenUsageTests/TestSupport.swift Tests/OpenUsageTests/RhythmRecorderTests.swift
git commit -m "feat(rhythm): record the readings of every refresh"
```

---

### Task 4: Turn the buckets into chart bars

The pure functions that turn a day's records into the bars the chart draws, and that find the peak.

**Files:**
- Create: `Sources/OpenUsage/Rhythm/RhythmAnalytics.swift`
- Test: `Tests/OpenUsageTests/RhythmAnalyticsTests.swift`

**Interfaces:**
- Consumes: `RhythmDayRecord`, `RhythmSeriesRecord`, `RhythmClock` from Task 1.
- Produces:
  - `struct RhythmBar: Hashable, Sendable, Identifiable` with `index: Int`, `points: Double`, `samples: Int`, `start: Date`, and `var id: Int { index }`
  - `enum RhythmZoom: Int, CaseIterable, Sendable` with `case day, halfDay, sixHours, twoHours`, `var window: TimeInterval`, `var barDuration: TimeInterval`, `var label: String`
  - `enum RhythmAnalytics` with
    - `static func bars(for record: RhythmDayRecord, zoom: RhythmZoom, offset: TimeInterval, calendar: Calendar) -> [RhythmBar]`
    - `static func averageBars(for records: [RhythmDayRecord], zoom: RhythmZoom, offset: TimeInterval, calendar: Calendar) -> [RhythmBar]`
    - `static func peakBars(in bars: [RhythmBar]) -> ClosedRange<Int>?`
    - `static func peakStart(for bars: [RhythmBar], zoom: RhythmZoom, offset: TimeInterval, day: Date, calendar: Calendar) -> Date?`

- [ ] **Step 1: Write the failing analytics tests**

Create `Tests/OpenUsageTests/RhythmAnalyticsTests.swift`:

```swift
import XCTest
@testable import OpenUsage

/// The buckets become the bars the chart draws. The number of bars never changes; the slice each
/// bar covers does, so zooming in makes the same bar stand for less time.
final class RhythmAnalyticsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func day(_ dayNumber: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: dayNumber))!
    }

    /// A day whose buckets hold the given points, one bucket each from the start of the day.
    private func record(_ dayNumber: Int, points: [Double]) -> RhythmDayRecord {
        RhythmDayRecord(day: day(dayNumber), series: [
            RhythmSeriesRecord(
                key: "account-1/Session",
                kind: .claude,
                label: "Session",
                windowMs: MetricPeriod.sessionMs,
                points: points,
                samples: points.map { _ in 1 }
            )
        ])
    }

    func testTheWholeDayIsTwentyFourHourlyBars() {
        let points = [Double](repeating: 0, count: 288)
        for hour in 0..<24 { points[hour * 12] = Double(hour) }

        let bars = RhythmAnalytics.bars(for: record(6, points: points), zoom: .day, offset: 0, calendar: calendar)

        XCTAssertEqual(bars.count, 24)
        XCTAssertEqual(bars[14].points, 14, accuracy: 0.0001)
        XCTAssertEqual(bars[0].start, calendar.startOfDay(for: day(6)))
    }

    func testZoomingInSplitsTheHoursIntoShorterBars() {
        let points = [Double](repeating: 0, count: 288)
        for index in 168..<180 { points[index] = 1 }  // 14:00 - 15:00, twelve five-minute buckets

        let bars = RhythmAnalytics.bars(for: record(6, points: points), zoom: .sixHours, offset: 12 * 3600, calendar: calendar)

        XCTAssertEqual(bars.count, 24)
        XCTAssertEqual(bars.filter { $0.points > 0 }.count, 4)
        XCTAssertEqual(bars[8].points, 1, accuracy: 0.0001)
        XCTAssertEqual(bars[0].start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!)
    }

    func testTheOffsetMovesTheWindow() {
        let points = [Double](repeating: 0, count: 288)
        for index in 168..<180 { points[index] = 1 }

        let bars = RhythmAnalytics.bars(for: record(6, points: points), zoom: .sixHours, offset: 13 * 3600, calendar: calendar)

        XCTAssertEqual(bars.filter { $0.points > 0 }.count, 4)
        XCTAssertEqual(bars[0].start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 13))!)
    }

    func testSeveralSeriesAddUp() {
        let first = RhythmDayRecord(day: day(6), series: [
            RhythmSeriesRecord(key: "a/Session", kind: .claude, label: "Session", windowMs: MetricPeriod.sessionMs, points: [Double](repeating: 0, count: 288), samples: [Int](repeating: 1, count: 288)),
            RhythmSeriesRecord(key: "b/Session", kind: .minimax, label: "Session", windowMs: MetricPeriod.sessionMs, points: [Double](repeating: 0, count: 288), samples: [Int](repeating: 1, count: 288))
        ])
        var second = first
        second.series[0].points[168] = 3
        second.series[1].points[168] = 2

        let bars = RhythmAnalytics.bars(for: second, zoom: .day, offset: 0, calendar: calendar)

        XCTAssertEqual(bars[14].points, 5, accuracy: 0.0001)
    }

    func testTheAverageDividesByTheDaysThatWereRead() {
        let busy = record(6, points: [Double](repeating: 0, count: 288))
        let quiet = record(7, points: [Double](repeating: 0, count: 288))
        var one = busy
        one.series[0].points[168] = 10
        var two = quiet
        two.series[0].points[168] = 2
        two.series[0].samples[168] = 1

        let bars = RhythmAnalytics.averageBars(for: [one, two], zoom: .day, offset: 0, calendar: calendar)

        XCTAssertEqual(bars[14].points, 6, accuracy: 0.0001)
        XCTAssertEqual(bars[14].samples, 2)
    }

    func testTheAverageSkipsTheDaysThatWereNotRead() {
        let busy = record(6, points: [Double](repeating: 0, count: 288))
        var one = busy
        one.series[0].points[168] = 10
        let empty = record(7, points: [Double](repeating: 0, count: 288))
        var nothing = empty
        nothing.series[0].samples = [Int](repeating: 0, count: 288)

        let bars = RhythmAnalytics.averageBars(for: [one, nothing], zoom: .day, offset: 0, calendar: calendar)

        XCTAssertEqual(bars[14].points, 10, accuracy: 0.0001)
    }

    func testThePeakIsTheRunAroundTheTallestBar() {
        var bars = [RhythmBar](repeating: RhythmBar(index: 0, points: 0, samples: 1, start: Date()), count: 24)
        bars[13].points = 2
        bars[14].points = 9
        bars[15].points = 8
        bars[16].points = 1

        let peak = RhythmAnalytics.peakBars(in: bars)

        XCTAssertEqual(peak, 13...15)
    }

    func testAChartWithNothingInItHasNoPeak() {
        let bars = [RhythmBar](repeating: RhythmBar(index: 0, points: 0, samples: 0, start: Date()), count: 24)

        XCTAssertNil(RhythmAnalytics.peakBars(in: bars))
    }

    func testThePeakStartsWhenItsFirstBarDoes() throws {
        var bars = [RhythmBar](repeating: RhythmBar(index: 0, points: 0, samples: 1, start: Date()), count: 24)
        bars[14].points = 9
        let peak = try XCTUnwrap(RhythmAnalytics.peakBars(in: bars))

        let start = RhythmAnalytics.peakStart(
            for: bars,
            zoom: .day,
            offset: 0,
            day: day(6),
            calendar: calendar
        )

        XCTAssertEqual(start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14))!)
        XCTAssertEqual(peak.lowerBound, 14)
    }
}
```

- [ ] **Step 2: Run the analytics tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmAnalyticsTests`

Expected: FAIL — `cannot find 'RhythmAnalytics' in scope`.

- [ ] **Step 3: Write the analytics**

Create `Sources/OpenUsage/Rhythm/RhythmAnalytics.swift`:

```swift
import Foundation

/// One bar of the chart.
struct RhythmBar: Hashable, Sendable, Identifiable {
    var id: Int { index }
    /// The bar's place in the window, 0...23.
    var index: Int
    /// The share of the window the slice burned, in points.
    var points: Double
    /// How many samples the slice holds. Zero means nothing was read, which is not the same as
    /// nothing being used.
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
}

/// Turns the recorded buckets into the bars the chart draws.
enum RhythmAnalytics {
    /// The bars of one day at a zoom level, starting at an offset into the day.
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
                let bucketStart = RhythmClock.start(of: index, on: record.day, calendar: calendar)
                let slice = Int((bucketStart.timeIntervalSince(windowStart) / zoom.barDuration).rounded(.down))
                guard slice >= 0, slice < 24 else { continue }
                points[slice] += value
                samples[slice] += series.samples[index]
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
    /// were read in it, so a day the app was closed does not pull the average down.
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
                totals[bar.index] += bar.points
                readings[bar.index] += bar.samples > 0 ? 1 : 0
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

    /// The bars that make up the peak: the run around the tallest bar that stays above 60% of it.
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

    /// When the peak starts, for the label under the chart.
    static func peakStart(
        for bars: [RhythmBar],
        zoom: RhythmZoom,
        offset: TimeInterval,
        day: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let peak = peakBars(in: bars) else { return nil }
        return bars[peak.lowerBound].start
    }
}
```

- [ ] **Step 4: Run the analytics tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmAnalyticsTests`

Expected: PASS — 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenUsage/Rhythm/RhythmAnalytics.swift Tests/OpenUsageTests/RhythmAnalyticsTests.swift
git commit -m "feat(rhythm): turn the recorded buckets into chart bars"
```

---

### Task 5: The chart and the tab

The views. The chart draws the bars, the context strip draws the whole day with a draggable window, and the tab puts them together.

**Files:**
- Create: `Sources/OpenUsage/Views/RhythmChart.swift`
- Create: `Sources/OpenUsage/Views/RhythmContextStrip.swift`
- Create: `Sources/OpenUsage/Views/RhythmView.swift`
- Modify: `Sources/OpenUsage/Models/DashboardTab.swift`
- Modify: `Sources/OpenUsage/Views/DashboardContentView.swift`
- Test: `Tests/OpenUsageTests/RhythmChartTests.swift`

**Interfaces:**
- Consumes: `RhythmBar`, `RhythmZoom`, `RhythmAnalytics` from Task 4; `RhythmRecorder`, `RhythmSettings` from Tasks 2 and 3.
- Produces:
  - `struct RhythmChart: View` with `init(bars:peak:zoom:)`
  - `struct RhythmContextStrip: View` with `init(dayBars:window:onMove:)`
  - `struct RhythmView: View`
  - `DashboardTab.rhythm` with the label "Rhythm"

- [ ] **Step 1: Write the failing chart tests**

Create `Tests/OpenUsageTests/RhythmChartTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The chart draws the peak in the app's blue and everything else in a lighter shade of it. A
/// slice nothing was read from stays empty: "we do not know" must not look like "nothing was
/// used".
@MainActor
final class RhythmChartTests: XCTestCase {
    func testThePeakBarIsDrawnInTheStrongerBlue() throws {
        var bars = [RhythmBar](repeating: RhythmBar(index: 0, points: 0, samples: 1, start: Date()), count: 24)
        bars[14].points = 9
        bars[15].points = 8

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: 14...15, zoom: .day)))

        let strong = try stronglyBluePixels(in: image)
        XCTAssertFalse(strong.isEmpty, "the peak is drawn in the stronger blue")
    }

    func testABarThatWasNotReadIsLeftEmpty() throws {
        var bars = [RhythmBar](repeating: RhythmBar(index: 0, points: 0, samples: 0, start: Date()), count: 24)
        bars[14].points = 9
        bars[14].samples = 0

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: nil, zoom: .day)))

        XCTAssertTrue(try stronglyBluePixels(in: image).isEmpty, "an unread slice draws nothing")
    }

    // MARK: - Rendering

    private func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 300, height: 100))
        renderer.scale = 2
        return renderer.cgImage
    }

    private func pixels(in image: CGImage) throws -> [(r: Int, g: Int, b: Int, a: Int)] {
        let rep = NSBitmapImageRep(cgImage: image)
        var result: [(r: Int, g: Int, b: Int, a: Int)] = []
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y) {
                    result.append((r: Int(color.redComponent * 255), g: Int(color.greenComponent * 255), b: Int(color.blueComponent * 255), a: Int(color.alphaComponent * 255)))
                }
            }
        }
        return result
    }

    /// The pixels the strong blue covers. macOS's system blue is 0, 122, 255.
    private func stronglyBluePixels(in image: CGImage) throws -> [(r: Int, g: Int, b: Int, a: Int)] {
        try pixels(in: image).filter { $0.a > 128 && $0.b > 200 && $0.r < 120 && $0.g < 170 }
    }
}
```

- [ ] **Step 2: Run the chart tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmChartTests`

Expected: FAIL — `cannot find 'RhythmChart' in scope`.

- [ ] **Step 3: Write the chart**

Create `Sources/OpenUsage/Views/RhythmChart.swift`:

```swift
import SwiftUI

/// The rhythm chart: one bar per slice of the visible window. The peak is drawn in the app's
/// blue and the rest in a lighter shade of it. A slice nothing was read from stays empty, so
/// "we do not know" never looks like "nothing was used".
struct RhythmChart: View {
    let bars: [RhythmBar]
    /// The bars that make up the peak.
    let peak: ClosedRange<Int>?
    /// The zoom the chart is at, which decides what each bar's unit of time is.
    let zoom: RhythmZoom

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)

    /// The tallest bar, which sets the scale the others are drawn against.
    private var scale: Double {
        max(bars.map(\.points).max() ?? 0, 0.0001)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bars) { bar in
                    column(bar, maxHeight: geo.size.height)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func column(_ bar: RhythmBar, maxHeight: CGFloat) -> some View {
        Group {
            if bar.samples == 0 && bar.points <= 0 {
                // Nothing was read and nothing was burned: we do not know.
                Color.clear
            } else if bar.points <= 0 {
                // Read, but nothing was used: a baseline, not an empty column.
                Rectangle()
                    .fill(Theme.severityColor(.normal).opacity(0.3))
                    .frame(height: 1)
            } else {
                // A bucket can hold consumption without holding a reading of its own: the burn
                // between two readings is spread over the buckets it covered.
                Self.shape
                    .fill(fill(bar))
                    .frame(height: max(2, maxHeight * CGFloat(bar.points / scale)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func fill(_ bar: RhythmBar) -> Color {
        let blue = Theme.severityColor(.normal)
        guard let peak, peak.contains(bar.index) else { return blue.opacity(0.35) }
        return blue
    }

    private var accessibilityText: String {
        guard let peak = RhythmAnalytics.peakBars(in: bars) else {
            return "Usage rhythm, nothing to show"
        }
        let first = bars[peak.lowerBound].start
        let last = bars[peak.upperBound].start.addingTimeInterval(zoom.barDuration)
        return "Usage rhythm. The peak runs from \(first.formatted(date: .omitted, time: .shortened)) to \(last.formatted(date: .omitted, time: .shortened))."
    }
}
```

- [ ] **Step 4: Write the context strip**

Create `Sources/OpenUsage/Views/RhythmContextStrip.swift`:

```swift
import SwiftUI

/// The whole day as a strip of small bars, with the window the chart is showing marked on it.
/// The mark is the handle: dragging it moves the window through the day.
struct RhythmContextStrip: View {
    /// The whole day, one bar per hour.
    let dayBars: [RhythmBar]
    /// The window the chart is showing, as a share of the day from 0 to 1.
    let window: ClosedRange<Double>
    /// Called while the window is dragged.
    let onMove: (ClosedRange<Double>) -> Void

    private static let shape = RoundedRectangle(cornerRadius: 1, style: .continuous)

    /// The tallest bar, which sets the scale the others are drawn against.
    private var scale: Double {
        max(dayBars.map(\.points).max() ?? 0, 0.0001)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                dayBarsView(height: geo.size.height)
                windowView(width: geo.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // The mark moves to where the pointer is, not by how far the pointer
                        // travelled: the strip is small, and a relative drag would drift.
                        let width = max(geo.size.width, 1)
                        let span = window.upperBound - window.lowerBound
                        let centre = Double(value.location.x / width)
                        let lower = max(0, min(1 - span, centre - span / 2))
                        onMove(lower...(lower + span))
                    }
            )
        }
        .frame(height: 18)
    }

    private func dayBarsView(height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(dayBars) { bar in
                Group {
                    if bar.samples == 0 && bar.points <= 0 {
                        Color.clear
                    } else {
                        Self.shape.fill(Theme.severityColor(.normal).opacity(0.25))
                            .frame(height: max(1, height * CGFloat(bar.points / scale)))
                    }
                }
            }
        }
    }

    private func windowView(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.severityColor(.normal).opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.severityColor(.normal).opacity(0.5), lineWidth: 1.5)
            }
            .frame(width: width * (window.upperBound - window.lowerBound))
            .offset(x: width * window.lowerBound)
    }
}
```

- [ ] **Step 5: Write the tab**

Create `Sources/OpenUsage/Views/RhythmView.swift`:

```swift
import SwiftUI

/// The rhythm tab: when each account's window fills up, and when the peak hours are.
struct RhythmView: View {
    @Environment(AppContainer.self) private var container

    /// Which of the two views is showing.
    private enum Mode: String, CaseIterable, Identifiable {
        case day
        case average
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: "This Day"
            case .average: "Average"
            }
        }
    }

    /// How many days the average covers.
    private enum Range: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue) Days" }
    }

    @State private var mode: Mode = .day
    @State private var day = Date()
    @State private var range: Range = .month
    @State private var zoom: RhythmZoom = .day
    @State private var offset: TimeInterval = 0
    @State private var isPickingDay = false
    @State private var records: [RhythmDayRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            CapsuleSegments(options: Mode.allCases.map { ($0, $0.label) }, selection: $mode)
            chart
            summary
        }
        .task(id: refreshKey) {
            // The history grows while the tab is open, so it reloads on a timer as well as when
            // the day, the mode or the zoom changes.
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// The charts' data.
    private var bars: [RhythmBar] {
        switch mode {
        case .day:
            guard let record = records.first(where: { Calendar.current.isDate($0.day, inSameDayAs: day) }) else { return [] }
            return RhythmAnalytics.bars(for: record, zoom: zoom, offset: offset)
        case .average:
            return RhythmAnalytics.averageBars(for: records, zoom: zoom, offset: offset)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if bars.isEmpty {
                Text("Nothing recorded yet. The rhythm builds up from today.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                if zoom != .day {
                    RhythmContextStrip(
                        dayBars: contextBars,
                        window: windowShare,
                        onMove: { share in move(to: share) }
                    )
                }
                RhythmChart(bars: bars, peak: RhythmAnalytics.peakBars(in: bars), zoom: zoom)
                    .frame(height: 96)
                axis
                zoomSlider
            }
        }
        .padding(10)
        .background { Theme.cardShape.fill(Theme.cardFill) }
    }

    private var header: some View {
        HStack {
            switch mode {
            case .day:
                Button {
                    moveDay(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.severityColor(.normal))

                // A long press opens the calendar: stepping a day at a time is too slow to reach
                // last Tuesday.
                Text(dayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .onLongPressGesture(minimumDuration: 0.4) { _ in isPickingDay = true }

                Button {
                    moveDay(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.severityColor(.normal))
            case .average:
                Text("Last \(range.rawValue) Days")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                CapsuleSegments(options: Range.allCases.map { ($0, $0.label) }, selection: $range)
                    .frame(width: 190)
            }
            Spacer(minLength: 0)
        }
        .popover(isPresented: $isPickingDay) {
            DatePicker("Pick a Day", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
        }
    }

    private var axis: some View {
        HStack {
            ForEach(0..<5) { step in
                Text(axisLabel(at: step))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                if step < 4 { Spacer() }
            }
        }
    }

    private var zoomSlider: some View {
        HStack(spacing: 8) {
            Text("Zoom")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(zoom.rawValue) },
                    set: { zoom = RhythmZoom(rawValue: Int($0.rounded())) ?? .day; clampOffset() }
                ),
                in: 0...Double(RhythmZoom.allCases.count - 1),
                step: 1
            )
            Text(zoom.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var summary: some View {
        Group {
            if let peak = RhythmAnalytics.peakBars(in: bars), !bars.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(Theme.severityColor(.normal)).frame(width: 7, height: 7)
                    Text(summaryText(from: bars[peak.lowerBound].start))
                }
                .font(.system(size: 11))
            }
        }
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The whole day at hourly resolution, for the strip above the chart.
    private var contextBars: [RhythmBar] {
        switch mode {
        case .day:
            guard let record = records.first(where: { Calendar.current.isDate($0.day, inSameDayAs: day) }) else {
                return []
            }
            return RhythmAnalytics.bars(for: record, zoom: .day, offset: 0)
        case .average:
            return RhythmAnalytics.averageBars(for: records, zoom: .day, offset: 0)
        }
    }

    /// The length of the day on show, which is not always 24 hours.
    private var dayLength: TimeInterval {
        Calendar.current.dateInterval(of: .day, for: day)?.duration ?? RhythmZoom.day.window
    }

    /// The window the chart is showing, as a share of the day.
    private var windowShare: ClosedRange<Double> {
        let lower = offset / dayLength
        let span = zoom.window / dayLength
        return lower...(lower + span)
    }

    private var refreshKey: String {
        "\(mode.rawValue)-\(day.timeIntervalSince1970)-\(range.rawValue)-\(zoom.rawValue)"
    }

    private func axisLabel(at step: Int) -> String {
        // Five labels over 24 bars: every sixth bar.
        let start = bars.first?.start ?? Calendar.current.startOfDay(for: day)
        return start.addingTimeInterval(Double(step) * 6 * zoom.barDuration).formatted(date: .omitted, time: .shortened)
    }

    private func summaryText(from start: Date) -> String {
        let end = start.addingTimeInterval(Double(peakBarCount) * zoom.barDuration)
        let window = "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        return mode == .day ? "This day's peak is \(window)" : "Your peak usually runs \(window)"
    }

    private var peakBarCount: Int {
        guard let peak = RhythmAnalytics.peakBars(in: bars) else { return 0 }
        return peak.count
    }

    private func moveDay(by days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day) else { return }
        day = next
        offset = 0
    }

    private func move(to share: ClosedRange<Double>) {
        offset = share.lowerBound * dayLength
        clampOffset()
    }

    private func clampOffset() {
        offset = min(max(offset, 0), max(0, dayLength - zoom.window))
        // The window always starts on a bar boundary, so the bars stay aligned with the buckets.
        offset = (offset / zoom.barDuration).rounded(.down) * zoom.barDuration
    }

    private func load() {
        // The range covers whole days: the store compares days, and a range that starts in the
        // afternoon would otherwise leave that day's record out.
        let today = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -(RhythmSettings.retentionDays - 1), to: today) ?? today
        records = (try? container.rhythm.store.load(days: start...today)) ?? []
    }
}
```

- [ ] **Step 6: Add the tab**

In `Sources/OpenUsage/Models/DashboardTab.swift`, add the case and the label:

```swift
    case rhythm
```

```swift
        case .rhythm: "Rhythm"
```

In `Sources/OpenUsage/Views/DashboardContentView.swift`, add to the switch:

```swift
            case .rhythm:
                RhythmView()
```

- [ ] **Step 7: Run the chart tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmChartTests`

Expected: PASS — 2 tests, 0 failures.

If the pixel assertions do not match macOS's system blue, loosen the filter in `stronglyBluePixels` to the blue that actually came out — print the pixels once and set the thresholds to them. The point of the test is that the peak is the strong blue and an unread slice draws nothing.

- [ ] **Step 8: Build the app**

Run: `swift build --scratch-path "$HOME/build"`

Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Sources/OpenUsage/Views/RhythmChart.swift Sources/OpenUsage/Views/RhythmContextStrip.swift Sources/OpenUsage/Views/RhythmView.swift Sources/OpenUsage/Models/DashboardTab.swift Sources/OpenUsage/Views/DashboardContentView.swift Sources/OpenUsage/Rhythm/RhythmStore.swift Tests/OpenUsageTests/RhythmChartTests.swift
git commit -m "feat(rhythm): show the rhythm in a dashboard tab"
```

---

### Task 6: The settings, the docs and the green suite

**Files:**
- Modify: `Sources/OpenUsage/Views/SettingsScreen.swift`
- Modify: `AGENTS.md`
- Create: `docs/rhythm.md`
- Modify: `docs/dashboard.md`

**Interfaces:**
- Consumes: `RhythmSettings`, `AppContainer.rhythm` from Tasks 2 and 3.
- Produces: the switch and the delete button in Settings; the fifth divergence section in `AGENTS.md`; `docs/rhythm.md`.

- [ ] **Step 1: Add the switch and the delete button**

In `Sources/OpenUsage/Views/SettingsScreen.swift`, add to the "Usage" section:

```swift
            Toggle(isOn: $container.rhythmSettings.isEnabled) {
                titled("Record Usage Rhythm", info: "Keeps how fast your limits fill up, on this Mac")
            }
            Button("Delete Rhythm History") {
                deleteRhythmHistory()
            }
            .disabled(!hasRhythmHistory)
```

`@AppStorage` does not work for an `@Observable` store, so bind the toggle through the store:

```swift
    Toggle(isOn: Binding(
        get: { container.rhythmSettings.isEnabled },
        set: { container.rhythmSettings.isEnabled = $0 }
    )) {
        titled("Record Usage Rhythm", info: "Keeps how fast your limits fill up, on this Mac")
    }
```

Add the two helpers:

```swift
    /// Whether there is any rhythm history to delete.
    private var hasRhythmHistory: Bool {
        (try? container.rhythm.store.recordedDays())?.isEmpty == false
    }

    private func deleteRhythmHistory() {
        let cutoff = Calendar.current.startOfDay(for: Date())
        do {
            try container.rhythm.store.delete(before: cutoff)
            AppLog.notice(.rhythm, "the rhythm history was deleted")
        } catch {
            // Say what happened rather than what was meant: the files are still there.
            AppLog.warn(.rhythm, "the rhythm history could not be deleted: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 2: Write the user documentation**

Create `docs/rhythm.md`:

```markdown
# Usage Rhythm

The **Rhythm** tab of the dashboard records how fast each account's limits fill up, and shows when
your busy hours are.

## What is recorded

Every refresh, the app notes how much of each limit's window has been used and when. From those
notes it builds a five-minute history of the last 90 days, kept in
`~/Library/Application Support/OpenUsage/rhythm/`.

Only what a provider's own API reports is recorded, and only the share of the window that was used
— never a token count, a price, or an account name. Nothing leaves this Mac: the history is never
uploaded, and the app never reads the logs of other tools.

## The two views

**This Day** shows one day. The arrows step a day at a time, and a long press on the date opens a
calendar. **Average** shows the last 7, 30 or 90 days averaged, so the shape of a usual week shows
through the noise of one day.

## Zooming in

The chart always has 24 bars. The zoom control changes how much of the day they cover: a day, half
a day, six hours or two hours. Above the chart, the strip of the whole day marks the window the
chart is showing; drag that mark to move the window through the day.

## Reading the chart

A bar's height is how much of the window that slice burned, in points of the window's percentage.
A darker bar and a tinted band mark the peak. A slice with no bar was never read — the app was
closed, or the provider was not answering — which is not the same as no usage.

Turn the recording off in **Settings → Usage → Record Usage Rhythm**. The history stays until you
delete it.
```

- [ ] **Step 3: Point the dashboard page at it**

In `docs/dashboard.md`, add a section:

```markdown
## Rhythm

The third tab, **Rhythm**, records how fast each limit fills up and shows when your busy hours
are. See [Usage Rhythm](rhythm.md).
```

- [ ] **Step 4: Record the divergence in `AGENTS.md`**

In `AGENTS.md`, insert a fifth section after "### 4. The fork's own menu bar and settings" and
renumber the sync-cadence section to six:

```markdown
### 5. The fork records usage rhythm

Upstream has none of this; the fork keeps it across a sync.

- The **Rhythm** tab records how fast each account's provider-reported window fills up, and shows
  when the peak hours are. The history is the provider's own reported percentage, sampled on every
  refresh and differenced — there is no log scanning, no spend estimate and no pricing anywhere in
  it, so it does not contradict section 3.
- The history lives in `~/Library/Application Support/OpenUsage/rhythm/`, one file per local day,
  and is never uploaded. `AGENTS.md`'s section 3 forbids reading other tools' credentials, files
  and logs; the rhythm feature reads none of them.
- Keep the recording and the chart in `Sources/OpenUsage/Rhythm/`, and the views in
  `Sources/OpenUsage/Views/Rhythm*.swift`. A future cloud store is one more `RhythmStore`
  implementation, not a change to the recorder or the chart — and it needs its own stable identity
  for an account, because the account's card id is local to this Mac.
```

- [ ] **Step 5: Run the whole suite**

Run: `script/test_quiet.sh`

Expected: every test passes, 0 failures. The suite has around 828 tests before this feature; the
count grows with the new ones.

- [ ] **Step 6: Build and check the app runs**

Run: `script/build_and_run.sh verify`

Expected: the build succeeds, the bundle is signed and verifies, and the app is running.

- [ ] **Step 7: Look at the tab**

Open the panel and click the **Rhythm** tab. With no history yet it shows "Nothing recorded yet.
The rhythm builds up from today." After a few refreshes the chart shows the hours that were used.

- [ ] **Step 8: Commit**

```bash
git add Sources/OpenUsage/Views/SettingsScreen.swift AGENTS.md docs/rhythm.md docs/dashboard.md
git commit -m "feat(rhythm): add the settings, the docs and the divergence"
```

---

## Self-Review

**Spec coverage.** Every section of `docs/superpowers/specs/2026-11-06-usage-rhythm-design.md` has a
task: the module split and the data flow (Tasks 1–3), the data model and the storage format
(Task 1), the calculation rules (Task 2), the zoom levels and the cross-day average (Task 4), the
interface (Task 5), the edge cases and the privacy rules (Tasks 2, 4 and 5), the failure handling
(Tasks 2 and 3), the testing strategy (every task), the files to change (every task), and the
divergence note (Task 6).

**Type consistency.** `RhythmReading` carries `resetsAt` from Task 2 onwards; `RhythmAnalytics`
in Task 4 takes `RhythmDayRecord` and returns `RhythmBar`; `RhythmChart` in Task 5 takes
`[RhythmBar]`, `ClosedRange<Int>?` and `RhythmZoom`; `RhythmView` in Task 5 uses
`container.rhythm.store` and `container.rhythmSettings`. `RhythmStore` gains `load(days:)` in
Task 5, which is the only change to the protocol after Task 1.

**Known gaps this plan leaves open, and why.** The chart's axis labels and the summary wording are
written against the English locale; a Chinese or German build shows the times in its own format
because they go through `Date.formatted`. The per-provider breakdown of the chart is deliberately
not built — the data is in the store, but the interface does not offer it. The cloud store is a
protocol implementation, not written now.
