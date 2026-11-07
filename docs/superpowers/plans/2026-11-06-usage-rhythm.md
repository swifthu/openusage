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
| `Sources/OpenUsage/Rhythm/RhythmRetention.swift` | How many days of history are kept — the one constant the store and the settings share |
| `Sources/OpenUsage/Views/RhythmChart.swift` | The bar chart |
| `Sources/OpenUsage/Views/RhythmContextStrip.swift` | The whole-day overview with the draggable window |
| `Sources/OpenUsage/Views/RhythmView.swift` | The tab: mode switch, day picker, zoom slider, summary line |

**New store file**

- `Sources/OpenUsage/Stores/RhythmSettings.swift` — the on/off switch and the retention length

**New test files**

- `Tests/OpenUsageTests/RhythmClockTests.swift`
- `Tests/OpenUsageTests/RhythmStoreTests.swift`
- `Tests/OpenUsageTests/RhythmRecorderTests.swift`
- `Tests/OpenUsageTests/RhythmRecorderTestsRules.swift`
- `Tests/OpenUsageTests/RhythmRecorderMidnightTests.swift`
- `Tests/OpenUsageTests/RhythmAnalyticsTests.swift`
- `Tests/OpenUsageTests/RhythmChartTests.swift`
- `Tests/OpenUsageTests/RhythmViewTests.swift`
- `Tests/OpenUsageTests/RhythmSettingsTests.swift`
- `Tests/OpenUsageTests/RhythmWiringTests.swift`

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

    func testAnIntervalEndingAtMidnightKeepsItsLastShare() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 50))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7))!

        let shares = RhythmClock.shares(from: start, to: end, day: day, calendar: calendar)

        XCTAssertEqual(shares.map(\.index), [286, 287])
        XCTAssertEqual(shares.reduce(0) { $0 + $1.share }, 1, accuracy: 0.001)
    }

    func testAnIntervalCrossingMidnightOnlySharesWhatFallsInTheDay() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 50))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, minute: 10))!

        let shares = RhythmClock.shares(from: start, to: end, day: day, calendar: calendar)

        XCTAssertEqual(shares.map(\.index), [286, 287])
        XCTAssertEqual(shares.reduce(0) { $0 + $1.share }, 0.5, accuracy: 0.001)
    }

    /// The day after the crossing holds the part of the interval that fell in it: the interval
    /// began before its midnight, so the part starts at the day's first bucket.
    func testAnIntervalThatBeganBeforeTheDaySharesWhatFallsInIt() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 50))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, minute: 10))!

        let shares = RhythmClock.shares(from: start, to: end, day: day, calendar: calendar)

        XCTAssertEqual(shares.map(\.index), [0, 1])
        // Ten of the twenty minutes fell in this day.
        XCTAssertEqual(shares.reduce(0) { $0 + $1.share }, 0.5, accuracy: 0.001)
    }

    /// An interval that lies entirely before the day holds nothing of it.
    func testAnIntervalThatEndedBeforeTheDayHoldsNothingOfIt() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 40))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 50))!

        XCTAssertTrue(RhythmClock.shares(from: start, to: end, day: day, calendar: calendar).isEmpty)
    }

    func testABucketStartsWhereTheGridSaysItDoes() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let midnight = calendar.startOfDay(for: day)

        XCTAssertEqual(RhythmClock.start(of: 0, on: day, calendar: calendar), midnight)
        XCTAssertEqual(
            RhythmClock.start(of: 1, on: day, calendar: calendar),
            midnight.addingTimeInterval(RhythmClock.bucketSeconds)
        )
    }

    func testTheBucketsTileTheDayWithoutGapsOrOverlap() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let count = RhythmClock.bucketCount(on: day, calendar: calendar)
        let midnight = calendar.startOfDay(for: day)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!

        for index in 0..<(count - 1) {
            let start = RhythmClock.start(of: index, on: day, calendar: calendar)
            let next = RhythmClock.start(of: index + 1, on: day, calendar: calendar)
            XCTAssertEqual(next.timeIntervalSince(start), RhythmClock.bucketSeconds)
        }

        let lastStart = RhythmClock.start(of: count - 1, on: day, calendar: calendar)
        XCTAssertEqual(lastStart.addingTimeInterval(RhythmClock.bucketSeconds), nextMidnight)
    }

    func testAFileNameThatIsNotOursHasNoDay() {
        XCTAssertNil(RhythmClock.day(fromFileName: "notes.txt", calendar: calendar))
        XCTAssertNil(RhythmClock.day(fromFileName: "2026-13-45.json", calendar: calendar))
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
    /// Whether the burn was bigger than the whole window and was clamped to it. A clamped burn
    /// means the provider's denominator changed, so the bar is not a rate the user burned.
    var clamped: Bool
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
    /// An interval that ends exactly on the next midnight still belongs to the day it started in:
    /// its last instant is that day's last bucket, and dropping it would lose the share the day
    /// burned in its final minutes.
    ///
    /// The shares cover only the part of the interval that falls inside `day`. A share is a
    /// fraction of the **whole** interval, so the shares of the two days an interval crosses sum
    /// to one: the part that fell in the next day is in no bucket of the day it was asked about,
    /// and the part that fell in the day before is in no bucket of the day it was asked about
    /// either. The caller is expected to ask about both days, or to lose the consumption that
    /// crossed the boundary.
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
        let clampedEnd = min(end, dayEnd)

        let first: Int
        if let index = bucketIndex(for: start, on: day, calendar: calendar) {
            first = index
        } else if start < dayStart {
            // The interval began before this day, so the part of it that falls in this day starts
            // at the day's first bucket.
            first = 0
        } else {
            return []
        }
        let last: Int
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
            let overlap = min(bucketEnd, clampedEnd).timeIntervalSince(max(bucketStart, start))
            guard overlap > 0 else { continue }
            result.append(RhythmBucketShare(index: index, share: overlap / total))
        }
        return result
    }

    /// The key a day's file carries, "yyyy-MM-dd".
    ///
    /// The key is built from the calendar's own parts rather than from a formatter, so it is the
    /// same in every time zone the calendar names and no formatter has to be kept alive: the tab
    /// reads up to ninety of these names every thirty seconds.
    static func dayKey(for day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, dayNumber)
    }

    /// The name a day's file carries.
    static func fileName(for day: Date, calendar: Calendar = .current) -> String {
        dayKey(for: day, calendar: calendar) + ".json"
    }

    /// The day a file name carries, nil when the name is not one of ours.
    static func day(fromFileName name: String, calendar: Calendar = .current) -> Date? {
        guard name.hasSuffix(".json") else { return nil }
        let parts = String(name.dropLast(5)).split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayNumber
        guard let date = calendar.date(from: components) else { return nil }
        // A day that does not exist — the thirteenth of a month — is rolled over by the calendar
        // instead of refused, so the name is checked against the day it names.
        let named = calendar.dateComponents([.year, .month, .day], from: date)
        guard named.year == year, named.month == month, named.day == dayNumber else { return nil }
        return calendar.startOfDay(for: date)
    }
}
```

- [ ] **Step 5: Run the clock tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmClockTests`

Expected: PASS — 12 tests, 0 failures.

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

    /// Today's midnight in the store's calendar.
    private var today: Date { calendar.startOfDay(for: Date()) }

    /// A day that is this many days away from today.
    private func daysFromToday(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
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
        // The store refuses a file whose buckets do not fit the day, so a record carries as many
        // buckets as the day it belongs to.
        let count = RhythmClock.bucketCount(on: day, calendar: calendar)
        let padded = points + [Double](repeating: 0, count: max(0, count - points.count))
        return rawRecord(day, points: padded)
    }

    /// A record with the buckets it is given, however many there are.
    private func rawRecord(_ day: Date, points: [Double]) -> RhythmDayRecord {
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

        // The days are counted from today rather than written out, so the test does not depend on
        // what today's date is.
        try store.save(record(daysFromToday(-3), points: []))
        try store.save(record(daysFromToday(-2), points: []))
        try store.save(record(daysFromToday(-1), points: []))
        try store.save(record(today, points: []))

        // Three days are kept, the day that was written and the two before it.
        XCTAssertEqual(try store.recordedDays(), [daysFromToday(-2), daysFromToday(-1), today])
    }

    func testWritingADayInThePastRemovesNothingThatIsInsideTheWindow() throws {
        let store = makeStore(retentionDays: 3)

        try store.save(record(daysFromToday(-2), points: []))
        try store.save(record(daysFromToday(-1), points: []))
        try store.save(record(today, points: []))
        // An old day is written after the days around today.
        try store.save(record(daysFromToday(-3), points: []))

        // The days that are still inside the window are all there.
        XCTAssertEqual(try store.recordedDays(), [daysFromToday(-3), daysFromToday(-2), daysFromToday(-1), today])
    }

    func testWritingADayInTheFutureRemovesNothing() throws {
        let store = makeStore(retentionDays: 3)

        try store.save(record(daysFromToday(-2), points: []))
        try store.save(record(daysFromToday(-1), points: []))
        try store.save(record(today, points: []))
        // The clock was set forward, so the day that was written is in the future.
        try store.save(record(daysFromToday(10), points: []))

        // A clock that is wrong must not cost the user the history that is still inside the
        // window.
        XCTAssertEqual(try store.recordedDays(), [daysFromToday(-2), daysFromToday(-1), today, daysFromToday(10)])
    }

    func testTheHistoryIsKeptForNinetyDays() {
        XCTAssertEqual(RhythmRetention.retentionDays, 90)
        XCTAssertEqual(
            FileRhythmStore(directory: directory, calendar: calendar).retentionDays,
            RhythmRetention.retentionDays
        )
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

    /// The file says which day it holds, so a file that was renamed or restored cannot pass for
    /// the day it is read on.
    func testTheFileCarriesTheDayItHolds() throws {
        let store = makeStore()
        try store.save(record(day(11, 6), points: [Double](repeating: 0, count: 288)))

        let data = try Data(contentsOf: directory.appendingPathComponent(fileName(11, 6)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["day"] as? String, "2026-11-06")
    }

    func testAFileThatHoldsAnotherDayIsRefused() throws {
        let store = makeStore()
        try store.save(record(day(11, 6), points: [Double](repeating: 0, count: 288)))
        // The file is renamed to another day.
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent(fileName(11, 6)),
            to: directory.appendingPathComponent(fileName(11, 7))
        )

        XCTAssertThrowsError(try store.load(day: day(11, 7))) { error in
            guard case RhythmStoreError.dayMismatch = error else {
                return XCTFail("expected a day mismatch, got \(error)")
            }
        }
    }

    func testAFileThatDoesNotSayWhichDayItHoldsIsRefused() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = #"{"schema":"openusage.rhythm.v1","series":[]}"#
        try Data(payload.utf8).write(to: directory.appendingPathComponent(fileName(11, 6)))

        XCTAssertThrowsError(try store.load(day: day(11, 6))) { error in
            guard case RhythmStoreError.dayMismatch = error else {
                return XCTFail("expected a day mismatch, got \(error)")
            }
        }
    }

    /// A file written for a day of 288 buckets that is read on a day of 276 or 300 — or after the
    /// time zone changed — has its buckets out of step, so it is skipped.
    func testAFileWithTheWrongNumberOfBucketsIsRefused() throws {
        let store = makeStore()
        // The day has 288 buckets; the file has 276.
        try store.save(rawRecord(day(11, 6), points: [Double](repeating: 0, count: 276)))

        XCTAssertThrowsError(try store.load(day: day(11, 6))) { error in
            guard case RhythmStoreError.bucketMismatch = error else {
                return XCTFail("expected a bucket mismatch, got \(error)")
            }
        }
    }

    /// A file that does not fit the day is skipped, and the days around it are still read.
    func testAFileThatDoesNotFitTheDayIsSkippedInARange() throws {
        let store = makeStore()
        try store.save(record(day(11, 1), points: [Double](repeating: 0, count: 288)))
        try store.save(rawRecord(day(11, 6), points: [Double](repeating: 0, count: 276)))
        try store.save(record(day(11, 8), points: [Double](repeating: 0, count: 288)))

        let loaded = try store.load(days: day(11, 1)...day(11, 8))

        XCTAssertEqual(loaded.map(\.day), [day(11, 1), day(11, 8)])
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
    /// The file holds another day than the one it was asked for, so it was renamed or restored.
    case dayMismatch(expected: String, actual: String)
    /// The file's buckets do not fit the day it holds, so they are out of step.
    case bucketMismatch(expected: Int, found: Int)

    var errorDescription: String? {
        switch self {
        case .unknownSchema(let schema):
            "The rhythm history uses an unknown format (\(schema))."
        case .dayMismatch(let expected, let actual):
            "The rhythm history file holds \(actual) and was asked for \(expected)."
        case .bucketMismatch(let expected, let found):
            "The rhythm history file has \(found) buckets where \(expected) were expected."
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
    /// The records of a range of days, oldest first.
    func load(days: ClosedRange<Date>) throws -> [RhythmDayRecord]
    /// The days that have a record, oldest first. A history that does not exist yet is empty; a
    /// history that cannot be read is an error.
    func recordedDays() throws -> [Date]
    /// Deletes the records before a date. The date names a day, so it is compared as one: a cutoff
    /// in the afternoon leaves that day's own record alone.
    func delete(before date: Date) throws
}

extension RhythmStore {
    /// Removes every recorded day, today's own record included.
    ///
    /// The store deletes the days *before* the cutoff, so the cutoff has to be tomorrow's
    /// midnight to take today's record with it.
    func deleteAll(now: Date = Date(), calendar: Calendar = .current) throws {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        try delete(before: tomorrow)
    }
}

/// The rhythm history as one file per day under Application Support.
struct FileRhythmStore: RhythmStore {
    /// The folder the day files live in.
    let directory: URL
    /// The calendar the days are measured in. It decides which file a moment belongs to, so it has
    /// to be the same one the recorder writes with.
    let calendar: Calendar
    /// How many days of history are kept. The days older than that are removed when a day is
    /// written, so the history does not grow without end.
    let retentionDays: Int

    init(directory: URL = FileRhythmStore.defaultDirectory, calendar: Calendar, retentionDays: Int = RhythmRetention.retentionDays) {
        self.directory = directory
        self.calendar = calendar
        self.retentionDays = retentionDays
    }

    static var defaultDirectory: URL {
        directory(forBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func directory(forBundleIdentifier identifier: String?) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("rhythm", isDirectory: true)
            // The app is not sandboxed, so Application Support is shared by every build of it.
            // The bundle identifier keeps the development build and the installed one apart.
            .appendingPathComponent(identifier ?? "default", isDirectory: true)
    }

    private struct Payload: Codable {
        var schema: String
        /// The day the file holds. A file that was renamed or restored must not pass for the day
        /// it is asked about.
        var day: String?
        var series: [RhythmSeriesRecord]
    }

    func save(_ record: RhythmDayRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Payload(
            schema: RhythmDayRecord.currentSchema,
            day: RhythmClock.dayKey(for: record.day, calendar: calendar),
            series: record.series
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: url(for: record.day), options: .atomic)
        trimOldDays(around: record.day)
    }

    /// Removes the days that are older than the retention length, so the history does not grow
    /// without end. The days are counted from today and not from the day that was just written:
    /// the retention is a promise about today, so a clock that was set forward must not delete a
    /// history that is still inside the window.
    ///
    /// A day that cannot be removed is left in place and warned about: the history that is there
    /// is better than a history that is gone.
    private func trimOldDays(around day: Date) {
        // A day that was written is normally today, but it can be in the past (a day the app
        // writes after the clock was turned back) or in the future (a clock that was set
        // forward). The cutoff follows the earlier of the two, so the future never pulls it up.
        let today = calendar.startOfDay(for: min(day, Date()))
        guard let cutoffDate = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) else { return }
        // Adding a day to a midnight that falls on a daylight-saving transition gives 01:00 and
        // not 00:00, which would take the boundary day with it and lose a day for nothing.
        let cutoff = calendar.startOfDay(for: cutoffDate)
        let days: [Date]
        do {
            days = try recordedDays()
        } catch {
            AppLog.warn(.rhythm, "could not list the rhythm history to trim it: \(error.localizedDescription)")
            return
        }
        for old in days where old < cutoff {
            do {
                try FileManager.default.removeItem(at: url(for: old))
            } catch {
                AppLog.warn(.rhythm, "could not remove the rhythm history of \(RhythmClock.fileName(for: old, calendar: calendar)): \(error.localizedDescription)")
            }
        }
    }

    func load(day: Date) throws -> RhythmDayRecord? {
        let file = url(for: day)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: file))
        guard payload.schema == RhythmDayRecord.currentSchema else {
            throw RhythmStoreError.unknownSchema(payload.schema)
        }
        // The file has to say which day it holds, and it has to be the day it is asked for: a file
        // that was renamed or restored would otherwise pass for the day it is read on.
        let key = RhythmClock.dayKey(for: day, calendar: calendar)
        guard let payloadDay = payload.day else {
            throw RhythmStoreError.dayMismatch(expected: key, actual: "no day")
        }
        guard payloadDay == key else {
            throw RhythmStoreError.dayMismatch(expected: key, actual: payloadDay)
        }
        // The buckets have to fit the day: a file written for a day of 288 buckets that is read on
        // a day of 276 or 300 — or after the time zone changed — has its buckets out of step.
        let count = RhythmClock.bucketCount(on: day, calendar: calendar)
        for series in payload.series {
            guard series.points.count == count, series.samples.count == count else {
                throw RhythmStoreError.bucketMismatch(expected: count, found: series.points.count)
            }
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

    func recordedDays() throws -> [Date] {
        // A folder that was never created means the app has no history yet, which is not a problem.
        // A folder that exists but cannot be read is a problem the user has to know about, so it is
        // thrown instead of being read as an empty history.
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .compactMap { RhythmClock.day(fromFileName: $0, calendar: calendar) }
            .sorted()
    }

    func delete(before date: Date) throws {
        // The cutoff names a day, so it is compared as days: a cutoff in the afternoon does not
        // take the record of that same day with it.
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

Expected: PASS — 15 tests, 0 failures.

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
    - `func flush(at now: Date) -> Bool` — writes every day it holds, and says whether all of them
      landed. A day is only let go once its write landed, so a failed write is taken out by the
      next successful one.
    - `static func readings(from snapshot: ProviderSnapshot, kind: ProviderKind, at now: Date) -> [RhythmReading]`
    - `var pendingSeries: [RhythmSeriesRecord]` — for tests, the series whose buckets changed since
      the last write. The recorder keeps the whole day in memory and writes all of it, because the
      store's `save` replaces the day's file rather than adding to it.
    - `var pendingDays: [Date]` — for tests, the days that still have something unwritten
  - `Sources/OpenUsage/Stores/RhythmSettings.swift` — `@MainActor final class RhythmSettings` with `static let key`, `static let retentionDays = 90`, `var isEnabled: Bool`, `init(defaults:)`

**Note on the reset rule:** the reliable signal that a window reset is `resetsAt`. When the previous reading's `resetsAt` falls at or before the current reading's moment, the two readings describe different windows, so the difference between them is not consumption. Only when a provider reports no `resetsAt` does the recorder fall back to "the reading went down, so the window reset".

- [ ] **Step 1: Write the failing differencer tests**

Create `Tests/OpenUsageTests/RhythmRecorderTests.swift`:

```swift
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
```

The rules of the difference are many, and the file that holds them grows: the plan splits them
into their own file so that neither file passes five hundred lines.

Create `Tests/OpenUsageTests/RhythmRecorderTestsRules.swift`:

```swift
import XCTest
@testable import OpenUsage

/// The rules of the difference: what a snapshot yields, and what two readings make of each other.
///
/// A window that reset, a gap longer than the window and a metric that is not a share of a window
/// burn nothing: the use before the reset was never read, and money is not a window.
@MainActor
final class RhythmRecorderTestsRules: XCTestCase {
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

    /// A burn that is bigger than the whole window was clamped, and the chart shows a full bar
    /// that nobody burned. The recorder says so in the log, so the flag says it here.
    func testABurnThatIsClampedIsMarkedAsClamped() {
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.0, at: moment(14, 0), resetsAt: moment(19, 0)),
            to: reading(fraction: 4.0, at: moment(14, 5), resetsAt: moment(19, 0)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertTrue(delta.clamped, "the provider's limit probably changed")
    }

    func testABurnThatIsNotClampedIsNotMarkedAsClamped() {
        let delta = RhythmDifferencer.delta(
            from: reading(fraction: 0.2, at: moment(14, 0), resetsAt: moment(19, 0)),
            to: reading(fraction: 0.35, at: moment(14, 5), resetsAt: moment(19, 0)),
            day: moment(0),
            calendar: calendar
        )

        XCTAssertFalse(delta.clamped)
    }

    /// The share of a money budget is the rate at which money is spent, and this fork does not
    /// chart spending. A count is a share of a window like any other.
    func testAMoneyMetricIsNotRecorded() {
        let snapshot = ProviderSnapshot(
            providerID: "account-1",
            displayName: "OpenRouter",
            lines: [
                .progress(label: "Budget", used: 4, limit: 20, format: .dollars, resetsAt: moment(19, 0), periodDurationMs: MetricPeriod.dayMs),
                .progress(label: "Key Limit", used: 2, limit: 10, format: .dollars, resetsAt: moment(19, 0), periodDurationMs: MetricPeriod.dayMs),
                .progress(label: "Free Requests", used: 3, limit: 50, format: .count(suffix: "requests"), resetsAt: moment(19, 0), periodDurationMs: MetricPeriod.dayMs)
            ]
        )

        let readings = RhythmRecorder.readings(from: snapshot, kind: .openrouter, at: moment(14, 0))

        XCTAssertEqual(readings.count, 1, "only the count is a share of a window")
        XCTAssertEqual(readings[0].label, "Free Requests")
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
}
```

The midnight is the one moment the recorder cannot get wrong, so it gets a file of its own:
the burn that crosses the midnight is booked on both days, and the day that ended is taken
back from the store before anything is booked into it.

Create `Tests/OpenUsageTests/RhythmRecorderMidnightTests.swift`:

```swift
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
```
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

- [ ] **Step 2: Run the recorder tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmRecorderTests`

Expected: FAIL — `cannot find 'RhythmRecorder' in scope`.

- [ ] **Step 3: Write the setting**

Create `Sources/OpenUsage/Stores/RhythmSettings.swift`:

```swift
import Foundation
import Observation

/// Whether the app records how fast each account's window fills up. The history never leaves this
/// Mac, and how long it is kept is `RhythmRetention`'s business.
@MainActor
@Observable
final class RhythmSettings {
    static let key = "recordsUsageRhythm"
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
/// The rollover is decided per series — every series has a last reading of its own — so every
/// series that crosses the midnight books the part of its burn that fell before it. The
/// consumption before a provider's window resets is still not seen, and the recorder does not
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
    /// The day the recorder records on: the newest day a reading belongs to. A day that is not
    /// the current one may be let go once it is on disk.
    @ObservationIgnored private var recordedDay: Date?
    /// When the day's buckets were last written.
    @ObservationIgnored private var lastFlush: Date?
    /// When the last write failed. A failed write is not tried again before the interval has
    /// passed, so a disk that cannot be written does not fill the log with one warning per
    /// reading.
    @ObservationIgnored private var lastFailure: Date?
    /// The day whose write failed. The error is only cleared when that day is written, so the
    /// success of another day does not hide it from the user.
    @ObservationIgnored private var failedDay: Date?
    /// The days that could not be read back from the store. The recorder does not know what
    /// their files hold, so it does not book a fragment of them over them.
    @ObservationIgnored private var unreadableDays: Set<Date> = []
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
        // The days that ended are written after every series of the snapshot has booked its part,
        // so the day on disk holds the part of every series that crossed the midnight and not
        // only the part of the first one.
        var ended: [Date] = []
        for reading in Self.readings(from: snapshot, kind: kind, at: now) {
            if let endedDay = apply(reading), !ended.contains(endedDay) {
                ended.append(endedDay)
            }
        }
        for day in ended {
            write(day: day, at: now)
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
        unreadableDays.removeAll()
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
            let result = write(day: day, at: now)
            wroteEverything = result.wrote && wroteEverything
            failed = failed || result.failed
        }
        if !failed { failures = 0 }
        return wroteEverything
    }

    /// Writes one day, if it has something waiting to be written, and remembers what was written.
    ///
    /// A day that is on disk and has nothing waiting to be written is let go, unless it is the
    /// day the recorder records on: that one is still being added to. A day the store could not
    /// read is not written at all.
    @discardableResult
    private func write(day: Date, at now: Date) -> (wrote: Bool, failed: Bool) {
        // A file the store refused is never written over. The recorder does not know what it
        // holds, and replacing it with what the recorder has would destroy it.
        if unreadableDays.contains(day) {
            // The recorder lets the day go: it cannot write it and it must not hold it.
            days.removeValue(forKey: day)
            written.removeValue(forKey: day)
            return (false, false)
        }
        let series = days[day] ?? [:]
        guard !pendingSeries(on: day).isEmpty else {
            if day != recordedDay {
                // The day is on disk and nothing is waiting to be written, so the recorder
                // does not need to hold it any more.
                days.removeValue(forKey: day)
                written.removeValue(forKey: day)
            }
            return (true, false)
        }
        let record = RhythmDayRecord(day: day, series: series.values.sorted { $0.key < $1.key })
        do {
            try history.save(record)
            written[day] = series
            lastFlush = now
            unreadableDays.remove(day)
            if failedDay == day {
                // The day that could not be written is on disk, so the user does not have to be
                // told about it any more. The success of another day does not clear it.
                lastWriteError = nil
                failedDay = nil
            }
            if day != recordedDay {
                // The day is on disk, so the recorder does not need to hold it any more.
                days.removeValue(forKey: day)
                written.removeValue(forKey: day)
            }
            return (true, false)
        } catch {
            failures += 1
            lastFailure = now
            failedDay = day
            lastWriteError = error.localizedDescription
            AppLog.warn(.rhythm, "could not write the rhythm history for \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
            if failures >= 5 {
                AppLog.error(.rhythm, "the rhythm history stopped being written after \(failures) failures in a row")
            }
            return (false, true)
        }
    }

    /// Books a reading: the burn since this series' last reading, and the reading itself.
    ///
    /// Returns the day that ended, when this reading crossed the midnight. The part of the burn
    /// that fell before the midnight belongs to that day, and the day is written once every
    /// series of the snapshot has booked its part.
    ///
    /// A reading whose day the store could not read is not booked: the app cannot merge with a
    /// file it cannot read, and writing over one would destroy it.
    private func apply(_ reading: RhythmReading) -> Date? {
        let day = calendar.startOfDay(for: reading.at)
        // The reading is the baseline of the next one even when its day cannot be kept: the
        // consumption that follows is measured from here.
        defer { lastReading[reading.key] = reading }
        // The day the recorder records on is the newest day a reading belongs to.
        if let current = recordedDay {
            if day > current { recordedDay = day }
        } else {
            recordedDay = day
        }
        // The day the reading belongs to is taken back from the store when the recorder does not
        // hold it, so the part another run of the app recorded is not lost.
        guard holdWholeDay(day) else {
            // The day's file cannot be read, so the recorder does not know what it holds.
            // Writing what it has would replace a file it could not read, so the reading is not
            // booked and the file is left alone.
            return nil
        }
        var endedDay: Date?
        if let previous = lastReading[reading.key] {
            let previousDay = calendar.startOfDay(for: previous.at)
            if previousDay != day {
                // This series crossed the midnight. The burn since its last reading may have
                // crossed it too: the part before it belongs to the day that ended and the rest
                // to the day that began. The rollover is decided per series, so every series that
                // crosses the midnight books the part that fell before it.
                let endedBurn = RhythmDifferencer.delta(from: previous, to: reading, day: previousDay, calendar: calendar)
                let begunBurn = RhythmDifferencer.delta(from: previous, to: reading, day: day, calendar: calendar)
                // The day that ended is taken back from the store before anything is booked into
                // it: the recorder may not hold it at all — the app was closed across the
                // midnight — and the write of the file store replaces the whole file, so a day
                // that holds only a fragment would destroy the day that is on disk.
                if !endedBurn.buckets.isEmpty, holdWholeDay(previousDay) {
                    burn(endedBurn, of: reading, on: previousDay)
                }
                if !begunBurn.buckets.isEmpty {
                    burn(begunBurn, of: reading, on: day)
                }
                endedDay = previousDay
            } else {
                burn(from: previous, to: reading, on: day)
            }
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
        return endedDay
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

    /// Makes sure the recorder holds the whole of a day before anything is booked into it.
    ///
    /// A day another run of the app started is taken back from the store, the way the day the
    /// recorder starts on is. The write of the file store replaces the whole file, so a day that
    /// holds only a fragment of itself would destroy the day that is on disk.
    ///
    /// Returns whether the day is whole now. A day that cannot be read back is not whole: the
    /// caller does not book a fragment of it over a file it cannot see.
    @discardableResult
    private func holdWholeDay(_ day: Date) -> Bool {
        // A day the store could not read is never whole, not even when the recorder holds
        // something for it: what it holds would be a fragment of a day it could not read.
        guard !unreadableDays.contains(day) else { return false }
        guard days[day]?.isEmpty ?? true else { return true }
        guard continueFromStore(on: day) else {
            // The day is not read again and again: the file is the same one every time.
            unreadableDays.insert(day)
            return false
        }
        return true
    }

    /// A day another run of the app started: the recorder continues from what was written, so the
    /// part of the day before the restart is not lost when the day is written again.
    ///
    /// Returns whether the day could be read. A day that cannot be read is not continued: the
    /// recorder does not know what the file holds, so it does not write over it.
    @discardableResult
    private func continueFromStore(on day: Date) -> Bool {
        let stored: RhythmDayRecord?
        do {
            stored = try history.load(day: day)
        } catch {
            AppLog.warn(.rhythm, "could not read the rhythm history for \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription). The file is left alone and the readings of that day are not kept.")
            return false
        }
        guard let stored else { return true }
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
        return true
    }
}
```
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
/// The rollover is decided per series — every series has a last reading of its own — so every
/// series that crosses the midnight books the part of its burn that fell before it. The
/// consumption before a provider's window resets is still not seen, and the recorder does not
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
    /// The day the recorder records on: the newest day a reading belongs to. A day that is not
    /// the current one may be let go once it is on disk.
    @ObservationIgnored private var recordedDay: Date?
    /// When the day's buckets were last written.
    @ObservationIgnored private var lastFlush: Date?
    /// When the last write failed. A failed write is not tried again before the interval has
    /// passed, so a disk that cannot be written does not fill the log with one warning per
    /// reading.
    @ObservationIgnored private var lastFailure: Date?
    /// The day whose write failed. The error is only cleared when that day is written, so the
    /// success of another day does not hide it from the user.
    @ObservationIgnored private var failedDay: Date?
    /// The days that could not be read back from the store. The recorder does not know what
    /// their files hold, so it does not book a fragment of them over them.
    @ObservationIgnored private var unreadableDays: Set<Date> = []
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
        // The days that ended are written after every series of the snapshot has booked its part,
        // so the day on disk holds the part of every series that crossed the midnight and not
        // only the part of the first one.
        var ended: [Date] = []
        for reading in Self.readings(from: snapshot, kind: kind, at: now) {
            if let endedDay = apply(reading), !ended.contains(endedDay) {
                ended.append(endedDay)
            }
        }
        for day in ended {
            write(day: day, at: now)
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
        unreadableDays.removeAll()
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
            let result = write(day: day, at: now)
            wroteEverything = result.wrote && wroteEverything
            failed = failed || result.failed
        }
        if !failed { failures = 0 }
        return wroteEverything
    }

    /// Writes one day, if it has something waiting to be written, and remembers what was written.
    ///
    /// A day that is on disk and has nothing waiting to be written is let go, unless it is the
    /// day the recorder records on: that one is still being added to.
    @discardableResult
    private func write(day: Date, at now: Date) -> (wrote: Bool, failed: Bool) {
        let series = days[day] ?? [:]
        guard !pendingSeries(on: day).isEmpty else {
            if day != recordedDay {
                // The day is on disk and nothing is waiting to be written, so the recorder
                // does not need to hold it any more.
                days.removeValue(forKey: day)
                written.removeValue(forKey: day)
            }
            return (true, false)
        }
        let record = RhythmDayRecord(day: day, series: series.values.sorted { $0.key < $1.key })
        do {
            try history.save(record)
            written[day] = series
            lastFlush = now
            unreadableDays.remove(day)
            if failedDay == day {
                // The day that could not be written is on disk, so the user does not have to be
                // told about it any more. The success of another day does not clear it.
                lastWriteError = nil
                failedDay = nil
            }
            if day != recordedDay {
                // The day is on disk, so the recorder does not need to hold it any more.
                days.removeValue(forKey: day)
                written.removeValue(forKey: day)
            }
            return (true, false)
        } catch {
            failures += 1
            lastFailure = now
            failedDay = day
            lastWriteError = error.localizedDescription
            AppLog.warn(.rhythm, "could not write the rhythm history for \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
            if failures >= 5 {
                AppLog.error(.rhythm, "the rhythm history stopped being written after \(failures) failures in a row")
            }
            return (false, true)
        }
    }

    /// Books a reading: the burn since this series' last reading, and the reading itself.
    ///
    /// Returns the day that ended, when this reading crossed the midnight. The part of the burn
    /// that fell before the midnight belongs to that day, and the day is written once every
    /// series of the snapshot has booked its part.
    private func apply(_ reading: RhythmReading) -> Date? {
        let day = calendar.startOfDay(for: reading.at)
        // The day the reading belongs to is taken back from the store when the recorder does not
        // hold it, so the part another run of the app recorded is not lost. A day that cannot be
        // read is recorded anyway: the day the recorder is on is never left empty.
        holdWholeDay(day)
        var endedDay: Date?
        if let previous = lastReading[reading.key] {
            let previousDay = calendar.startOfDay(for: previous.at)
            if previousDay != day {
                // This series crossed the midnight. The burn since its last reading may have
                // crossed it too: the part before it belongs to the day that ended and the rest
                // to the day that began. The rollover is decided per series, so every series that
                // crosses the midnight books the part that fell before it.
                let endedBurn = RhythmDifferencer.delta(from: previous, to: reading, day: previousDay, calendar: calendar)
                let begunBurn = RhythmDifferencer.delta(from: previous, to: reading, day: day, calendar: calendar)
                // The day that ended is taken back from the store before anything is booked into
                // it: the recorder may not hold it at all — the app was closed across the
                // midnight — and the write of the file store replaces the whole file, so a day
                // that holds only a fragment would destroy the day that is on disk.
                if !endedBurn.buckets.isEmpty, holdWholeDay(previousDay) {
                    burn(endedBurn, of: reading, on: previousDay)
                }
                if !begunBurn.buckets.isEmpty {
                    burn(begunBurn, of: reading, on: day)
                }
                endedDay = previousDay
            } else {
                burn(from: previous, to: reading, on: day)
            }
        }
        // The day the recorder records on is the newest day a reading belongs to.
        if let current = recordedDay {
            if day > current { recordedDay = day }
        } else {
            recordedDay = day
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
        return endedDay
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

    /// Makes sure the recorder holds the whole of a day before anything is booked into it.
    ///
    /// A day another run of the app started is taken back from the store, the way the day the
    /// recorder starts on is. The write of the file store replaces the whole file, so a day that
    /// holds only a fragment of itself would destroy the day that is on disk.
    ///
    /// Returns whether the day is whole now. A day that cannot be read back is not whole: the
    /// caller does not book a fragment of it over a file it cannot see.
    @discardableResult
    private func holdWholeDay(_ day: Date) -> Bool {
        guard days[day]?.isEmpty ?? true else { return true }
        guard !unreadableDays.contains(day) else { return false }
        guard continueFromStore(on: day) else {
            // The day is not read again and again: the file is the same one every time.
            unreadableDays.insert(day)
            return false
        }
        return true
    }

    /// A day another run of the app started: the recorder continues from what was written, so the
    /// part of the day before the restart is not lost when the day is written again.
    ///
    /// Returns whether the day could be read. A day that cannot be read is not continued: the
    /// recorder does not know what the file holds, so it does not write over it.
    @discardableResult
    private func continueFromStore(on day: Date) -> Bool {
        let stored: RhythmDayRecord?
        do {
            stored = try history.load(day: day)
        } catch {
            AppLog.warn(.rhythm, "could not read the rhythm history for \(RhythmClock.fileName(for: day, calendar: calendar)): \(error.localizedDescription)")
            return false
        }
        guard let stored else { return true }
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
        return true
    }
}

- [ ] **Step 5: Check the log tag is there**

`Sources/OpenUsage/Support/AppLog.swift` already carries `case rhythm` — Task 1 added it when the
store started logging the days it skips. Confirm it is present; add it if it is not.

```swift
    case rhythm
```

- [ ] **Step 6: Run the recorder tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmRecorderTests`

Expected: PASS — 25 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenUsage/Rhythm/RhythmRecorder.swift Sources/OpenUsage/Stores/RhythmSettings.swift Sources/OpenUsage/Support/AppLog.swift Tests/OpenUsageTests/RhythmRecorderTests.swift
git commit -m "feat(rhythm): record how fast each window fills up"
```

---

### Task 3: Hang the recorder on the refresh

The recorder now exists but nothing calls it. Wire it into `WidgetDataStore` and `AppContainer`, and
write the history out when the app quits.

**Files:**
- Modify: `Sources/OpenUsage/Stores/WidgetDataStore.swift` (the `init` and the private `store` method)
- Modify: `Sources/OpenUsage/App/AppContainer.swift` (the `init`)
- Modify: `Sources/OpenUsage/App/OpenUsageApp.swift` (`applicationWillTerminate`)
- Modify: `Tests/OpenUsageTests/TestSupport.swift` (`WidgetDataStore.forTesting`)
- Create: `Tests/OpenUsageTests/RhythmWiringTests.swift`

**Interfaces:**
- Consumes: `RhythmRecorder`, `RhythmSettings`, `FileRhythmStore` from Tasks 1 and 2.
- Produces:
  - `WidgetDataStore.init(..., rhythm: RhythmRecorder? = nil)`
  - `WidgetDataStore.forTesting(..., rhythm: RhythmRecorder? = nil)`
  - `AppContainer.rhythm: RhythmRecorder` and `AppContainer.rhythmSettings: RhythmSettings`

- [ ] **Step 1: Write the failing wiring test**

Create `Tests/OpenUsageTests/RhythmWiringTests.swift`:

```swift
import Foundation
import XCTest
@testable import OpenUsage

/// The wiring between a refresh and the rhythm recorder.
@MainActor
final class RhythmWiringTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Twelve buckets an hour, so 14:00 UTC is the bucket 168 of the day.
    private let afternoonBucket = 168

    private func moment(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: hour, minute: minute))!
    }

    /// A moment in another day, far away from the window of the reading.
    private func anotherDay(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: hour, minute: minute))!
    }

    private func snapshot(
        fraction: Double,
        at now: Date,
        resetsAt: Date? = nil,
        providerID: String = "account-1"
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            displayName: "Claude",
            lines: [.progress(
                label: "Session",
                used: fraction * 100,
                limit: 100,
                format: .percent,
                resetsAt: resetsAt ?? now.addingTimeInterval(3600),
                periodDurationMs: MetricPeriod.sessionMs
            )],
            refreshedAt: now
        )
    }

    private func recorder(_ store: RecordingRhythmStore) -> RhythmRecorder {
        RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
    }

    private func series(_ record: RhythmDayRecord?, _ key: String) -> RhythmSeriesRecord? {
        record?.series.first { $0.key == key }
    }

    func testASuccessfulRefreshFeedsTheRecorder() async throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = recorder(store)
        let clock = TestClock(moment(14, 0))
        let runtime = StubRuntime(
            provider: Provider(id: "account-1", kind: .claude),
            descriptors: [],
            snapshot: snapshot(fraction: 0.2, at: moment(14, 0))
        )
        let dataStore = WidgetDataStore.forTesting(
            [runtime],
            defaults: isolatedDefaults(),
            now: { clock.now },
            rhythm: recorder
        )

        await dataStore.refresh(providerID: runtime.provider.id, force: true)
        recorder.flush(at: clock.now)

        // What landed in the store is what the refresh found.
        XCTAssertEqual(store.saved.count, 1)
        let recorded = try XCTUnwrap(store.saved.first?.series.first)
        XCTAssertEqual(recorded.key, "account-1/Session")
        // The reading is a sample in the bucket of the moment the refresh happened.
        XCTAssertEqual(recorded.samples[afternoonBucket], 1)
        XCTAssertEqual(recorded.samples.reduce(0, +), 1)
        // It burned nothing: it had no predecessor to be differenced against.
        XCTAssertEqual(recorded.points.reduce(0, +), 0, accuracy: 0.0001)
    }

    func testAFailedRefreshFeedsTheRecorderNothing() async throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = recorder(store)
        let clock = TestClock(moment(14, 0))
        let runtime = StubRuntime(
            provider: Provider(id: "account-1", kind: .claude),
            descriptors: [],
            failure: RefreshFailure(message: "Unreachable", kind: .unreachable)
        )
        let dataStore = WidgetDataStore.forTesting(
            [runtime],
            defaults: isolatedDefaults(),
            now: { clock.now },
            rhythm: recorder
        )

        await dataStore.refresh(providerID: runtime.provider.id, force: true)
        recorder.flush(at: clock.now)

        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(recorder.pendingSeries.isEmpty)
    }

    func testAReplacedRuntimeOnTheSameAccountKeepsTheConsumption() async throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = recorder(store)
        let clock = TestClock(moment(14, 0))
        let provider = Provider(id: "account-1", kind: .claude)
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [],
            snapshot: snapshot(fraction: 0.2, at: moment(14, 0), resetsAt: moment(19, 0))
        )
        let dataStore = WidgetDataStore.forTesting(
            [runtime],
            defaults: isolatedDefaults(),
            now: { clock.now },
            rhythm: recorder
        )

        await dataStore.refresh(providerID: provider.id, force: true)

        // The sign-in expired and the account signed in again. It is the same account, so the
        // sign-in carries the same identity and the account behind the slot did not change:
        // what was burned in between is real consumption and belongs in the chart.
        clock.set(moment(14, 5))
        let reading = snapshot(fraction: 0.35, at: moment(14, 5), resetsAt: moment(19, 0))
        let replacement = StubRuntime(provider: provider, descriptors: [], snapshot: reading)
        dataStore.replaceProvider(replacement, snapshot: reading, accountMayHaveChanged: false)
        recorder.flush(at: clock.now)

        let recorded = try XCTUnwrap(series(store.saved.first, "account-1/Session"))
        // Both readings are samples.
        XCTAssertEqual(recorded.samples.reduce(0, +), 2)
        // The 0.15 that was burned between 14:00 and 14:05 is booked: the account did not change.
        XCTAssertEqual(recorded.points.reduce(0, +), 0.15, accuracy: 0.0001)
    }

    func testASlotThatMayHoldAnotherAccountBooksNoJump() async throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = recorder(store)
        let clock = TestClock(moment(14, 0))
        let provider = Provider(id: "account-1", kind: .claude)
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [],
            snapshot: snapshot(fraction: 0.2, at: moment(14, 0), resetsAt: moment(19, 0))
        )
        let dataStore = WidgetDataStore.forTesting(
            [runtime],
            defaults: isolatedDefaults(),
            now: { clock.now },
            rhythm: recorder
        )

        await dataStore.refresh(providerID: provider.id, force: true)

        // A key of another account was pasted into the same slot, so the new runtime measures
        // another account's window. The two windows even end at the same moment — the daily
        // limit of a provider ends at the same calendar boundary for every account — so the
        // recorder cannot tell them apart from the timestamps and is told instead.
        clock.set(moment(14, 5))
        let reading = snapshot(fraction: 0.9, at: moment(14, 5), resetsAt: moment(19, 0))
        let replacement = StubRuntime(provider: provider, descriptors: [], snapshot: reading)
        dataStore.replaceProvider(replacement, snapshot: reading, accountMayHaveChanged: true)
        recorder.flush(at: clock.now)

        let recorded = try XCTUnwrap(series(store.saved.first, "account-1/Session"))
        XCTAssertEqual(recorded.key, "account-1/Session")
        // Both readings are samples.
        XCTAssertEqual(recorded.samples.reduce(0, +), 2)
        // The jump between the old window and the new one is not consumption: nothing burned.
        XCTAssertEqual(recorded.points.reduce(0, +), 0, accuracy: 0.0001)
    }

    func testOneProvidersReplacementDoesNotTouchAnotherProvidersReadings() async throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = recorder(store)
        let clock = TestClock(moment(14, 0))
        let first = Provider(id: "account-1", kind: .claude)
        let second = Provider(id: "account-2", kind: .claude)
        let firstRuntime = StubRuntime(
            provider: first,
            descriptors: [],
            snapshot: snapshot(fraction: 0.2, at: moment(14, 0), resetsAt: moment(19, 0))
        )
        let secondRuntime = StubRuntime(
            provider: second,
            descriptors: [],
            results: [
                .success(snapshot(fraction: 0.1, at: moment(14, 0), resetsAt: moment(19, 0), providerID: "account-2")),
                .success(snapshot(fraction: 0.25, at: moment(14, 10), resetsAt: anotherDay(19, 0), providerID: "account-2"))
            ]
        )
        let dataStore = WidgetDataStore.forTesting(
            [firstRuntime, secondRuntime],
            defaults: isolatedDefaults(),
            now: { clock.now },
            rhythm: recorder
        )

        await dataStore.refresh(providerID: first.id, force: true)
        await dataStore.refresh(providerID: second.id, force: true)

        // The first account is signed in again and now holds another account's key.
        clock.set(moment(14, 5))
        let reading = snapshot(fraction: 0.9, at: moment(14, 5), resetsAt: anotherDay(19, 0))
        dataStore.replaceProvider(
            StubRuntime(provider: first, descriptors: [], snapshot: reading),
            snapshot: reading,
            accountMayHaveChanged: true
        )

        // The second account is not touched by that, so its next reading is still differenced
        // against its own previous one. It measures another window, so a wrongly dropped
        // baseline would lose its consumption instead of booking it.
        clock.set(moment(14, 10))
        await dataStore.refresh(providerID: second.id, force: true)
        recorder.flush(at: clock.now)

        let secondSeries = try XCTUnwrap(series(store.saved.first, "account-2/Session"))
        // The 0.15 the second account burned between 14:00 and 14:10 is booked.
        XCTAssertEqual(secondSeries.points.reduce(0, +), 0.15, accuracy: 0.0001)
        XCTAssertEqual(secondSeries.samples.reduce(0, +), 2)

        let firstSeries = try XCTUnwrap(series(store.saved.first, "account-1/Session"))
        // The first account's jump into the other account's window is not consumption.
        XCTAssertEqual(firstSeries.points.reduce(0, +), 0, accuracy: 0.0001)
    }

    func testTheSameOAuthIdentityMeansTheSameAccount() {
        let saved = AccountCredential.oauth(OAuthTokens(accessToken: "old", extras: [OAuthTokens.identityKey: "work"]))
        let fresh = AccountCredential.oauth(OAuthTokens(accessToken: "new", extras: [OAuthTokens.identityKey: "work"]))

        XCTAssertFalse(AppContainer.accountMayHaveChanged(fresh, saved: saved))
    }

    func testADifferentOAuthIdentityMeansAnotherAccount() {
        let saved = AccountCredential.oauth(OAuthTokens(accessToken: "old", extras: [OAuthTokens.identityKey: "work"]))
        let fresh = AccountCredential.oauth(OAuthTokens(accessToken: "new", extras: [OAuthTokens.identityKey: "other"]))

        XCTAssertTrue(AppContainer.accountMayHaveChanged(fresh, saved: saved))
    }

    func testTheSameAPIKeyMeansTheSameAccount() {
        let saved = AccountCredential.apiKey("key")
        let fresh = AccountCredential.apiKey("key")

        XCTAssertFalse(AppContainer.accountMayHaveChanged(fresh, saved: saved))
    }

    func testADifferentAPIKeyMayBeAnotherAccount() {
        let saved = AccountCredential.apiKey("key")
        let fresh = AccountCredential.apiKey("another key")

        XCTAssertTrue(AppContainer.accountMayHaveChanged(fresh, saved: saved))
    }

    func testASignInWithoutAnIdentityMeansTheSameAccount() {
        let saved = AccountCredential.oauth(OAuthTokens(accessToken: "old"))
        let fresh = AccountCredential.oauth(OAuthTokens(accessToken: "new"))

        XCTAssertFalse(AppContainer.accountMayHaveChanged(fresh, saved: saved))
        XCTAssertFalse(AppContainer.accountMayHaveChanged(fresh, saved: nil))
    }

    func testARefreshThroughTheContainerReachesItsRecorder() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let http = RoutingHTTPClient { _ in
            HTTPResponse.json("""
            {"model_remains":[{"model_name":"general","current_interval_remaining_percent":80,\
            "current_weekly_remaining_percent":100,"remains_time":7200000}],\
            "base_resp":{"status_code":0,"status_msg":"success"}}
            """)
        }
        // The account is added before the container, so the container starts no refresh of its own
        // and the reading this test counts is the one it asks for.
        let account = accounts.add(kind: .minimax, label: "Work", credential: .apiKey("key"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)

        // The tests keep the rhythm in memory: the file store would read and write the developer's
        // own history folder.
        XCTAssertTrue(container.rhythm.store is RecordingRhythmStore)

        await container.dataStore.refresh(providerID: account.cardID, force: true)
        container.rhythm.flush(at: Date())

        let store = try XCTUnwrap(container.rhythm.store as? RecordingRhythmStore)
        XCTAssertEqual(store.saved.count, 1)
        let recorded = try XCTUnwrap(store.saved.first?.series.first)
        XCTAssertEqual(recorded.key, "\(account.cardID)/Session")
        XCTAssertEqual(recorded.samples.reduce(0, +), 1)
    }

    func testAReplacedSignInThroughTheContainerDropsTheOldBaseline() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        // The first read finds a nearly empty window, the second a nearly full one. The jump
        // between them is what a baseline that was not dropped would book as consumption.
        let reads = TestSwitch(0)
        let http = RoutingHTTPClient { _ in
            let remaining = reads.value == 0 ? 80 : 20
            reads.value += 1
            return HTTPResponse.json("""
            {"model_remains":[{"model_name":"general","current_interval_remaining_percent":\(remaining),\
            "current_weekly_remaining_percent":100,"remains_time":7200000}],\
            "base_resp":{"status_code":0,"status_msg":"success"}}
            """)
        }
        let account = accounts.add(kind: .minimax, label: "Work", credential: .apiKey("key"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)

        await container.dataStore.refresh(providerID: account.cardID, force: true)

        // Another account's key is pasted into the same slot. An API key's identity is a hash of
        // the key, so the two identities differ and the account behind the slot may be another one.
        try await container.replaceCredential(.apiKey("another key"), for: account.cardID)
        container.rhythm.flush(at: Date())

        let store = try XCTUnwrap(container.rhythm.store as? RecordingRhythmStore)
        let recorded = try XCTUnwrap(store.saved.first?.series.first { $0.key == "\(account.cardID)/Session" })
        // Both readings are samples.
        XCTAssertEqual(recorded.samples.reduce(0, +), 2)
        // The jump is that other account's state, not consumption: the old baseline is gone, so the
        // new reading starts from nothing.
        XCTAssertEqual(recorded.points.reduce(0, +), 0, accuracy: 0.0001)
    }

    /// The app's cache holds the last snapshot of every provider, so the consumption between it
    /// and the first reading of a new run is not lost — for a provider with a day-long window,
    /// that is a whole night.
    func testTheCachedSnapshotIsTheBaselineOfTheFirstReading() async throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = recorder(store)
        let defaults = isolatedDefaults()
        let clock = TestClock(moment(14, 5))
        let provider = Provider(id: "account-1", kind: .claude)
        // The app was closed since 14:00: its cache holds the reading of that moment.
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        cache.save(["account-1": snapshot(fraction: 0.2, at: moment(14, 0), resetsAt: moment(19, 0))])
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [],
            snapshot: snapshot(fraction: 0.35, at: moment(14, 5), resetsAt: moment(19, 0))
        )
        let dataStore = WidgetDataStore.forTesting(
            [runtime],
            cache: cache,
            defaults: defaults,
            now: { clock.now },
            rhythm: recorder
        )

        await dataStore.refresh(providerID: provider.id, force: true)
        recorder.flush(at: clock.now)

        let recorded = try XCTUnwrap(store.saved.first?.series.first)
        // The 0.15 that was burned while the app was closed is booked.
        XCTAssertEqual(recorded.points.reduce(0, +), 0.15, accuracy: 0.0001)
        // Only the reading of this run is a sample: the cached one was counted by the run that
        // took it.
        XCTAssertEqual(recorded.samples.reduce(0, +), 1)
    }

    func testTheFileStoreKeepsTheDayTheRecorderWrote() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rhythm-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The store and the recorder have to measure the days in the same calendar, or the file
        // name and the bucket index drift a day apart.
        let store = FileRhythmStore(directory: directory, calendar: .current)
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let http = RoutingHTTPClient { _ in
            HTTPResponse.json("""
            {"model_remains":[{"model_name":"general","current_interval_remaining_percent":80,\
            "current_weekly_remaining_percent":100,"remains_time":7200000}],\
            "base_resp":{"status_code":0,"status_msg":"success"}}
            """)
        }
        let account = accounts.add(kind: .minimax, label: "Work", credential: .apiKey("key"))
        let container = AppContainer.forTesting(
            accounts: accounts,
            defaults: defaults,
            http: http,
            rhythmStore: store
        )

        await container.dataStore.refresh(providerID: account.cardID, force: true)
        container.rhythm.flush(at: Date())

        let day = Calendar.current.startOfDay(for: Date())
        let record = try XCTUnwrap(store.load(day: day))
        XCTAssertEqual(record.day, day)
        let recorded = try XCTUnwrap(record.series.first)
        XCTAssertEqual(recorded.key, "\(account.cardID)/Session")
        XCTAssertEqual(recorded.samples.reduce(0, +), 1)
        // The day is a file of its own, named for the day it holds.
        let file = directory.appendingPathComponent(RhythmClock.fileName(for: day, calendar: .current))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
```

`RecordingRhythmStore` already exists in `Tests/OpenUsageTests/RhythmRecorderTests.swift` and takes a
calendar — use it as it is, do not write a second store double.

- [ ] **Step 2: Run the wiring tests to verify they fail**

Run: `script/test_quiet.sh --filter RhythmWiringTests`

Expected: FAIL to compile — `WidgetDataStore.forTesting` has no `rhythm:` argument yet.

- [ ] **Step 3: Take the recorder in `WidgetDataStore`**

In `Sources/OpenUsage/Stores/WidgetDataStore.swift`, add the stored property next to the other
collaborators:

```swift
    /// Records how fast each account's window fills up. Nil when the app does not record it.
    @ObservationIgnored private let rhythm: RhythmRecorder?
```

Add it to `init` — the parameter goes last, after `providerRefreshTimeout`:

```swift
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout,
        rhythm: RhythmRecorder? = nil
    ) {
```

and assign it:

```swift
        self.rhythm = rhythm
```

Then record the reading. The snapshot is put into `snapshots` by the private `store` method, which
only runs on a refresh that succeeded — a failed refresh returns earlier through `recordFailure`,
and a cache hit, a backoff skip and an in-flight skip all return before `store` is reached. Hooking
there means only real readings are recorded, and a failed refresh leaves the hours it covered empty
rather than showing them as no usage.

In `private func store(_ snapshot: ProviderSnapshot, for providerID: String)`:

```swift
    private func store(_ snapshot: ProviderSnapshot, for providerID: String) {
        backoffs[providerID] = nil
        snapshots[providerID] = snapshot
        cache.save(snapshots)
        if let kind = providersByID[providerID]?.provider.kind {
            rhythm?.record(snapshot, kind: kind, at: now())
        }
    }
```

A replaced runtime may break the baseline. `replaceProvider` stores a snapshot taken from a **new**
runtime, and the series key — `"\(cardID)/<metric label>"` — does not change when the credential
does, so the previous reading is still there and the new window's percentage would be differenced
against the old one. That books a jump that never happened as consumption.

The app already knows whether the account behind the slot is still the same one, so it says so
rather than the recorder guessing:

- An **OAuth sign-in** carries the account's identity, and `replaceCredential` refuses one whose
  identity differs from the saved one — so an OAuth sign-in is always the same account.
- An **API key** carries a hash of itself, so the same key is the same account and a different key
  may be somebody else's.

`AppContainer.accountMayHaveChanged(_:saved:)` compares the two identities. It has to be worked
out **before** the new sign-in is saved: afterwards the saved credential is the new one and the
comparison would always say "the same account".

```swift
    static func accountMayHaveChanged(_ credential: AccountCredential, saved: AccountCredential?) -> Bool {
        guard let fresh = credential.identity, let old = saved?.identity else {
            AppLog.info(.rhythm, "the rhythm of a replaced sign-in could not check whether the account behind the slot is the same one")
            return false
        }
        return fresh != old
    }
```

When the two identities cannot be compared — the saved sign-in could not be read, or either of
them carries no identity — the account is still taken for the same one, because dropping the
baseline on every renewal would lose real consumption. The fact that it could not be checked is
said out loud.

And `replaceProvider` takes the answer. It has no default, so that every call site has to give it:
a new one that forgot would quietly mean "the same account".

```swift
    func replaceProvider(_ provider: ProviderRuntime, snapshot: ProviderSnapshot, accountMayHaveChanged: Bool) {
        let id = provider.provider.id
        inFlight.removeValue(forKey: id)?.cancel()
        providersByID[id] = provider
        if accountMayHaveChanged {
            // The account behind this slot may be a different one, so the jump between the old
            // reading and the new one is that account's state, not consumption.
            rhythm?.forgetReadings(for: id)
        }
        store(snapshot, for: id)
    }
```

The recorder drops the old reading and says how many it dropped, so nothing is discarded in
silence:

```swift
    func forgetReadings(for providerID: String) {
        let prefix = "\(providerID)/"
        let keys = lastReading.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        AppLog.info(.rhythm, "the rhythm of \(providerID) starts a new baseline: \(keys.count) readings dropped, the account behind it may be a different one")
        for key in keys {
            lastReading.removeValue(forKey: key)
        }
    }
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

First the folder the history lives in. `Sources/OpenUsage/Rhythm/RhythmStore.swift`:

```swift
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("rhythm", isDirectory: true)
            // The app is not sandboxed, so Application Support is shared by every build of it.
            // The bundle identifier keeps the development build and the installed one apart.
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "default", isDirectory: true)
    }
```

The app is not sandboxed — `script/OpenUsage.local.entitlements.plist` carries only
`com.apple.security.get-task-allow` — so `~/Library/Application Support` is the same folder for the
installed app and for the development build. `UserDefaults` is per bundle id, but this folder is
not, and `save` replaces the whole day's file. Both builds hold the day in memory and write it
every few minutes, so without the bundle identifier in the path they overwrite each other.

In `Sources/OpenUsage/App/AppContainer.swift`, add the two stored properties:

```swift
    let rhythm: RhythmRecorder
    let rhythmSettings: RhythmSettings
```

The recorder has to exist before the data store is built, because the data store takes it. In
`init`, above the `WidgetDataStore` that is built there:

```swift
        let rhythmSettings = RhythmSettings(defaults: defaults)
        let rhythm = RhythmRecorder(
            store: rhythmStore ?? FileRhythmStore(directory: FileRhythmStore.defaultDirectory, calendar: .current),
            settings: rhythmSettings,
            calendar: .current
        )
        self.rhythmSettings = rhythmSettings
        self.rhythm = rhythm
```

`RhythmRecorder.init` takes an explicit calendar and has no default for it — the recorder and the
store have to agree on which day a moment belongs to, or the file name and the bucket index drift
apart.

`init` takes the store as a parameter, so the tests do not touch the disk:

```swift
        telemetryDefaults: UserDefaults,
        rhythmStore: (any RhythmStore)? = nil
```

`RhythmStore` is `Sendable`, so this is fine. `AppContainer.forTesting` in
`Tests/OpenUsageTests/TestSupport.swift` passes an in-memory store — otherwise every one of the
nineteen test files that build a container would record into the developer's own history folder,
because `RhythmSettings.isEnabled` is on by default:

```swift
            rhythmStore: RecordingRhythmStore(calendar: .current)
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

- [ ] **Step 6: Write the history out when the app quits**

The recorder writes the day's buckets before it folds in the newest reading, so the newest reading
is never on disk until the next write. The app therefore has to write it out when it quits, or a
quit loses up to one refresh interval — at the default five-minute interval, the last five minutes
of the day.

`AppContainer.deinit` cannot do this: `AppContainer` is a `@MainActor` class, which makes it
`Sendable`, which makes its `deinit` nonisolated — a nonisolated `deinit` cannot call
`RhythmRecorder.flush(at:)`, a main-actor method.

The app delegate's termination handler can. In
`Sources/OpenUsage/App/OpenUsageApp.swift`:

```swift
    public func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
        container?.rhythm.flush(at: Date())
    }
```

`AppDelegate` is `@MainActor` and `applicationWillTerminate` runs on the main thread, so the call
is on the right actor. `RhythmRecorder.flush(at:)` is `@discardableResult`, so its result can be
ignored here — the recorder has already logged a warning if the write failed.

- [ ] **Step 7: Run the wiring tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmWiringTests`

Expected: PASS — 13 tests, 0 failures.

Run: `script/test_quiet.sh --filter RhythmRecorderTests`

Expected: PASS — the recorder's own suite stays green.

- [ ] **Step 8: Build the app**

Run: `swift build --scratch-path "$HOME/build"`

Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Sources/OpenUsage/Stores/WidgetDataStore.swift Sources/OpenUsage/App/AppContainer.swift Sources/OpenUsage/App/OpenUsageApp.swift Tests/OpenUsageTests/TestSupport.swift Tests/OpenUsageTests/RhythmWiringTests.swift
git commit -m "feat(rhythm): record the readings of every refresh"
```

---

## What Task 2 settled, so you do not have to guess

- **`RhythmRecorder.init(store:settings:calendar:flushInterval:)`** — `calendar` has no default.
  `flushInterval` defaults to five minutes.
- **`RhythmRecorder.flush(at:) -> Bool`** — whether every day it held was written. The app ignores
  the result; the tests use it.
- **`RhythmRecorder.record(_:kind:at:)`** — takes the snapshot, the provider's kind and the moment.
  A snapshot's `providerID` becomes the series key's first half, so the key of a series is
  `"<providerID>/<metric label>"`.
- **The recorder holds a day until that day's write actually landed**, and it can hold more than one
  day at a time. A write that failed is taken out by the next successful write, so nothing is
  dropped. `pendingDays` lists the days that still have something unwritten.
- **`RecordingRhythmStore`** in `Tests/OpenUsageTests/RhythmRecorderTests.swift` — the store double
  the recorder's own tests use. It takes a calendar and has `saved` and `saveAttempts`.

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

    /// The timezone that has daylight saving, so the days that are 23 and 25 hours long can be
    /// checked.
    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
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
        var points = [Double](repeating: 0, count: 288)
        for hour in 0..<24 { points[hour * 12] = Double(hour) }

        let bars = RhythmAnalytics.bars(for: record(6, points: points), zoom: .day, offset: 0, calendar: calendar)

        XCTAssertEqual(bars.count, 24)
        XCTAssertEqual(bars[14].points, 14, accuracy: 0.0001)
        XCTAssertEqual(bars[0].start, calendar.startOfDay(for: day(6)))
    }

    func testZoomingInSplitsTheHoursIntoShorterBars() {
        var points = [Double](repeating: 0, count: 288)
        for index in 168..<180 { points[index] = 1 }  // 14:00 - 15:00, twelve five-minute buckets

        let bars = RhythmAnalytics.bars(for: record(6, points: points), zoom: .sixHours, offset: 12 * 3600, calendar: calendar)

        XCTAssertEqual(bars.count, 24)
        // The window starts at 12:00 and each bar stands for fifteen minutes, so 14:00 is the
        // eighth bar. That bar holds the three five-minute buckets 14:00, 14:05 and 14:10.
        XCTAssertEqual(bars.filter { $0.points > 0 }.count, 4)
        XCTAssertEqual(bars[8].points, 3, accuracy: 0.0001)
        XCTAssertEqual(bars[0].start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!)
    }

    func testTheOffsetMovesTheWindow() {
        var points = [Double](repeating: 0, count: 288)
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

    func testARecordWhoseArraysDoNotMatchStillReads() {
        var points = [Double](repeating: 0, count: 288)
        points[168] = 1
        // A file written by another version can carry two arrays of different lengths.
        let record = RhythmDayRecord(day: day(6), series: [
            RhythmSeriesRecord(
                key: "account-1/Session",
                kind: .claude,
                label: "Session",
                windowMs: MetricPeriod.sessionMs,
                points: points,
                samples: [Int](repeating: 1, count: 100)
            )
        ])

        let bars = RhythmAnalytics.bars(for: record, zoom: .day, offset: 0, calendar: calendar)

        XCTAssertEqual(bars.count, 24)
        XCTAssertEqual(bars[14].points, 1, accuracy: 0.0001)
    }

    func testTheAverageDividesByTheDaysThatWereRead() {
        let busy = record(6, points: [Double](repeating: 0, count: 288))
        let quiet = record(7, points: [Double](repeating: 0, count: 288))
        var one = busy
        one.series[0].points[168] = 10
        var two = quiet
        two.series[0].points[168] = 2

        let bars = RhythmAnalytics.averageBars(for: [one, two], zoom: .day, offset: 0, calendar: calendar)

        // Both days were read in that hour, so the average is (10 + 2) / 2.
        XCTAssertEqual(bars[14].points, 6, accuracy: 0.0001)
        // The samples are the readings behind the average: one per bucket per day, and an hour is
        // twelve buckets, so twelve readings on each of the two days.
        XCTAssertEqual(bars[14].samples, 24)
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

    func testADayThatWasNotReadDoesNotRaiseTheAverage() {
        let busy = record(6, points: [Double](repeating: 0, count: 288))
        var one = busy
        one.series[0].points[168] = 10
        var two = record(7, points: [Double](repeating: 0, count: 288))
        two.series[0].points[168] = 10
        // The second day burned in that hour but has no reading of its own there, so it is not a
        // day that was read and must not count in the average.
        two.series[0].samples = []

        let bars = RhythmAnalytics.averageBars(for: [one, two], zoom: .day, offset: 0, calendar: calendar)

        XCTAssertEqual(bars[14].points, 10, accuracy: 0.0001)
    }

    func testThePeakIsTheRunAroundTheTallestBar() {
        var bars = [RhythmBar](repeating: RhythmBar(index: 0, points: 0, samples: 1, start: Date()), count: 24)
        bars[13].points = 2
        bars[14].points = 9
        bars[15].points = 8
        bars[16].points = 1

        let peak = RhythmAnalytics.peakBars(in: bars)

        // The run stays at or above 60% of the tallest bar. The bar before it (2) is below that,
        // so the peak is the two bars from the tallest one.
        XCTAssertEqual(peak, 14...15)
    }

    func testAChartWithNothingInItHasNoPeak() {
        let bars = [RhythmBar](repeating: RhythmBar(index: 0, points: 0, samples: 0, start: Date()), count: 24)

        XCTAssertNil(RhythmAnalytics.peakBars(in: bars))
    }

    // MARK: - Daylight saving

    /// The slice a bucket falls in, worked out by the analytics' arithmetic, has to be the slice
    /// the clock's own start time gives — on the days that are 23 and 25 hours long as well.
    func testTheSliceArithmeticAgreesWithTheClockOnADaylightSavingDay() {
        // The clocks go back: the day is 25 hours long and has 300 buckets.
        let long = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        XCTAssertEqual(RhythmClock.bucketCount(on: long, calendar: newYork), 300)
        assertSlicesAgree(withTheClock: long, buckets: 300, zoom: .day, offset: 0, calendar: newYork)
        assertSlicesAgree(withTheClock: long, buckets: 300, zoom: .sixHours, offset: 12 * 3600, calendar: newYork)

        // The clocks go forward: the day is 23 hours long and has 276 buckets.
        let short = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        XCTAssertEqual(RhythmClock.bucketCount(on: short, calendar: newYork), 276)
        assertSlicesAgree(withTheClock: short, buckets: 276, zoom: .day, offset: 0, calendar: newYork)
        assertSlicesAgree(withTheClock: short, buckets: 276, zoom: .halfDay, offset: 6 * 3600, calendar: newYork)
    }

    /// The day the clocks go back is 25 hours long. The window is still 24 hours from the
    /// midnight, so the day's last hour falls outside it and is not in the chart, and the axis
    /// shows 01:00 twice.
    func testTheDayTheClocksGoBackStillHasTwentyFourBars() {
        let day = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let record = recordWithAPointInEveryBucket(day: day, buckets: 300)

        let bars = RhythmAnalytics.bars(for: record, zoom: .day, offset: 0, calendar: newYork)

        XCTAssertEqual(bars.count, 24)
        XCTAssertEqual(bars[0].start, newYork.startOfDay(for: day))
        // The first hour of the day is shown twice, because the clocks went back in it.
        XCTAssertEqual(newYork.component(.hour, from: bars[1].start), 1)
        XCTAssertEqual(newYork.component(.hour, from: bars[2].start), 1)
        XCTAssertNotEqual(bars[1].start, bars[2].start)
        // The window is 24 hours long, so it ends at 23:00 — an hour before the day does, because
        // the clocks went back inside it. The hour from 23:00 to the midnight is outside the
        // window, so the last twelve buckets are not in the chart: 288 of the day's 300 buckets
        // are.
        XCTAssertEqual(newYork.component(.hour, from: bars[23].start), 22)
        XCTAssertEqual(bars[23].points, 12, accuracy: 0.0001)
        XCTAssertEqual(bars.reduce(0) { $0 + $1.points }, 288, accuracy: 0.0001)
    }

    /// The day the clocks go forward is 23 hours long. The window is still 24 hours from the
    /// midnight, so its last bar has nothing in it and its label is the next day's midnight.
    func testTheDayTheClocksGoForwardHasAnEmptyLastBar() {
        let day = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let record = recordWithAPointInEveryBucket(day: day, buckets: 276)

        let bars = RhythmAnalytics.bars(for: record, zoom: .day, offset: 0, calendar: newYork)

        XCTAssertEqual(bars.count, 24)
        XCTAssertEqual(bars[0].start, newYork.startOfDay(for: day))
        // The day is an hour shorter than the window, so the last bar is empty.
        XCTAssertEqual(bars[22].points, 12, accuracy: 0.0001)
        XCTAssertEqual(bars[23].points, 0, accuracy: 0.0001)
        XCTAssertEqual(bars.reduce(0) { $0 + $1.points }, 276, accuracy: 0.0001)
        // The empty bar starts at the next day's midnight.
        XCTAssertEqual(bars[23].start, newYork.date(from: DateComponents(year: 2026, month: 3, day: 9))!)
    }

    /// A record with a point and a reading in every bucket of the day.
    private func recordWithAPointInEveryBucket(day: Date, buckets: Int) -> RhythmDayRecord {
        RhythmDayRecord(day: day, series: [
            RhythmSeriesRecord(
                key: "account-1/Session",
                kind: .claude,
                label: "Session",
                windowMs: MetricPeriod.sessionMs,
                points: [Double](repeating: 1, count: buckets),
                samples: [Int](repeating: 1, count: buckets)
            )
        ])
    }

    /// Every bucket of the day has to land in the slice the clock's own start time gives it.
    private func assertSlicesAgree(
        withTheClock day: Date,
        buckets: Int,
        zoom: RhythmZoom,
        offset: TimeInterval,
        calendar: Calendar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowStart = calendar.startOfDay(for: day).addingTimeInterval(offset)
        for index in 0..<buckets {
            var points = [Double](repeating: 0, count: buckets)
            var samples = [Int](repeating: 0, count: buckets)
            points[index] = 1
            samples[index] = 1
            let record = RhythmDayRecord(day: day, series: [
                RhythmSeriesRecord(
                    key: "account-1/Session",
                    kind: .claude,
                    label: "Session",
                    windowMs: MetricPeriod.sessionMs,
                    points: points,
                    samples: samples
                )
            ])

            let bars = RhythmAnalytics.bars(for: record, zoom: zoom, offset: offset, calendar: calendar)

            // The clock's own answer: where the bucket's start falls in the window.
            let bucketStart = RhythmClock.start(of: index, on: day, calendar: calendar)
            let expected = Int((bucketStart.timeIntervalSince(windowStart) / zoom.barDuration).rounded(.down))
            let drawn = bars.firstIndex { $0.points > 0 }
            if expected >= 0, expected < 24 {
                XCTAssertEqual(drawn, expected, "bucket \(index)", file: file, line: line)
                XCTAssertEqual(bars[expected].samples, 1, "bucket \(index)", file: file, line: line)
            } else {
                XCTAssertNil(drawn, "bucket \(index)", file: file, line: line)
            }
        }
    }

    /// The chart says what its bars are counted in, and the unit follows the zoom level.
    func testTheUnitFollowsTheZoomLevel() {
        XCTAssertEqual(RhythmZoom.day.unit, "Percentage Points / Hour")
        XCTAssertEqual(RhythmZoom.halfDay.unit, "Percentage Points / 30 Minutes")
        XCTAssertEqual(RhythmZoom.sixHours.unit, "Percentage Points / 15 Minutes")
        XCTAssertEqual(RhythmZoom.twoHours.unit, "Percentage Points / 5 Minutes")
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
    /// The window points the slice burned. Several series are added together, so the sum can be
    /// more than one.
    var points: Double
    /// The readings that landed in the slice. Zero means no reading landed here, which is not the
    /// same as nothing having been used: a burn is spread over every bucket the interval
    /// covered, while the reading itself lands in the last of them — so a Mac that slept for two
    /// hours leaves two dozen buckets holding a burn and no reading of their own. On an averaged
    /// bar it is the total number of readings behind the average, not the number of days.
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

    /// The name of the time each bar stands for.
    var barDurationLabel: String {
        switch self {
        case .day: "Hour"
        case .halfDay: "30 Minutes"
        case .sixHours: "15 Minutes"
        case .twoHours: "5 Minutes"
        }
    }

    /// The unit of the chart: the share of the window each bar covers. The bars add up the share
    /// of every recorded window, so the unit says how much time each bar stands for.
    var unit: String {
        "Percentage Points / \(barDurationLabel)"
    }
}

/// Turns the recorded buckets into the bars the chart draws.
enum RhythmAnalytics {
    /// The bars of one day at a zoom level, starting at an offset into the day.
    ///
    /// The offset is a time into the day and only makes sense for a window shorter than the day:
    /// it is meaningful up to the day's length minus the window, and the caller clamps it. A whole
    /// day starts at the day's midnight and takes no offset.
    ///
    /// The window is a fixed 24 hours from the day's local midnight, and the 24 bars each stand
    /// for an hour of it. A day that is 25 hours long does not fit in that: the hour past the
    /// window is not in the chart, and the axis shows `01:00` twice. A day that is 23 hours long
    /// has an empty last bar, whose label is the next day's midnight. This is deliberate — the
    /// window means the same thing every day, so the days an average is made of line up — and the
    /// daylight-saving tests pin it.
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
                // A file written by another version can have two arrays of different lengths, so
                // the samples are read defensively: a missing sample counts as none.
                let sampleCount = index < series.samples.count ? series.samples[index] : 0
                // The bucket starts at the day's midnight plus its index in five-minute steps, so
                // the slice it falls in is arithmetic — no calendar call per bucket.
                let seconds = Double(index) * RhythmClock.bucketSeconds - offset
                let slice = Int((seconds / zoom.barDuration).rounded(.down))
                guard slice >= 0, slice < 24 else { continue }
                points[slice] += value
                samples[slice] += sampleCount
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
    /// were read in it, so a day the app was closed does not pull the average down. A day whose
    /// points are in a slice but whose readings are not does not contribute at all: the numerator
    /// and the denominator have to agree.
    ///
    /// An empty input returns no bars at all, where `bars(for:)` always returns 24. That is on
    /// purpose: the view shows its "nothing recorded yet" message when there are no bars.
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
                // Only a day that was read in this slice contributes, on both sides: a day whose
                // points are here but whose readings are not would raise the average.
                guard bar.samples > 0 else { continue }
                totals[bar.index] += bar.points
                readings[bar.index] += 1
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

    /// The bars that make up the peak: the run around the tallest bar that stays at or above 60%
    /// of it. A flat day — every bar the same height — makes the peak the whole chart.
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
}
```

- [ ] **Step 4: Run the analytics tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmAnalyticsTests`

Expected: PASS — 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenUsage/Rhythm/RhythmAnalytics.swift Tests/OpenUsageTests/RhythmAnalyticsTests.swift
git commit -m "feat(rhythm): turn the recorded buckets into chart bars"
```

---

## Notes for the task that comes next (the chart)

- **The number of bars is always 24.** Zooming shortens the time each bar stands for, it does not
  change how many bars there are.
- **`offset` is a time into the day** and only makes sense for a window shorter than the day. A
  whole day starts at the day's midnight and takes no offset — a non-zero offset on `.day` would
  silently drop the hours before the window.
- **A bar's `samples` says whether anything was read there**, which is not the same as nothing
  being used: `samples == 0` means "we do not know", and `samples > 0` with `points == 0` means
  "we looked and nothing was burned".
- **The chart shows the sum of every series** — a Claude session and a MiniMax session each burn
  their own window, and adding their points gives the share of the window the day went through.
  The per-series data stays in the store, so a stacked chart would not need a format change.
- **The peak is the run of bars above 60% of the tallest one**, which is why a single spike and a
  broad hill can both be one peak.

---

### Task 5: The chart and the tab

The views. The chart draws the bars, the context strip draws the whole day with a draggable window,
and the tab puts them together.

**Files:**
- Create: `Sources/OpenUsage/Views/RhythmChart.swift`
- Create: `Sources/OpenUsage/Views/RhythmContextStrip.swift`
- Create: `Sources/OpenUsage/Views/RhythmView.swift`
- Modify: `Sources/OpenUsage/Models/DashboardTab.swift`
- Modify: `Sources/OpenUsage/Views/DashboardContentView.swift`
- Test: `Tests/OpenUsageTests/RhythmChartTests.swift`
- Test: `Tests/OpenUsageTests/RhythmViewTests.swift`

**Interfaces:**
- Consumes: `RhythmBar`, `RhythmZoom`, `RhythmAnalytics` from Task 4; `RhythmRecorder`, `RhythmSettings`,
  `RhythmStore` from Tasks 1–3.
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
        var bars = makeBars()
        bars[14].points = 9
        bars[15].points = 8

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: 14...15, zoom: .day)))

        XCTAssertFalse(try stronglyBluePixels(in: image).isEmpty, "the peak is drawn in the stronger blue")
    }

    func testABurnThatHasNoReadingOfItsOwnIsStillDrawn() throws {
        // The burn between two readings is spread over the buckets it covered, and those buckets
        // hold no reading of their own. They still show.
        var bars = makeBars()
        bars[14].points = 9
        bars[14].samples = 0

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: 14...14, zoom: .day)))

        XCTAssertFalse(try stronglyBluePixels(in: image).isEmpty, "a burn without a reading of its own is drawn")
    }

    func testASliceThatWasReadButNotUsedDrawsABaseline() throws {
        let bars = makeBars()

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: nil, zoom: .day)))

        XCTAssertFalse(try inkPixels(in: image).isEmpty, "a slice that was read and not used draws a baseline")
    }

    func testASliceThatWasNotReadDrawsNothing() throws {
        let bars = makeBars(samples: 0)

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: nil, zoom: .day)))

        XCTAssertTrue(try inkPixels(in: image).isEmpty, "a slice that was not read draws nothing")
    }

    // MARK: - Rendering

    /// Twenty-four bars with distinct indices — the chart identifies a bar by its index, so two
    /// bars with the same one would make the drawing undefined.
    private func makeBars(samples: Int = 1) -> [RhythmBar] {
        (0..<24).map { RhythmBar(index: $0, points: 0, samples: samples, start: Date()) }
    }

    private func render(_ view: some View) -> CGImage? {
        // The white background makes the faint ink visible: without it a half-transparent bar has
        // a half-transparent alpha, and the test cannot tell it from nothing at all.
        let renderer = ImageRenderer(content: view.frame(width: 300, height: 100).background(Color.white))
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

    /// Every pixel that carries any of the chart's ink, however faint. The white background is not
    /// ink: blue minus red is what tells them apart.
    private func inkPixels(in image: CGImage) throws -> [(r: Int, g: Int, b: Int, a: Int)] {
        try pixels(in: image).filter { $0.b > 200 && $0.b - $0.r > 30 }
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
        guard let peak else { return "Usage rhythm, nothing to show" }
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
                windowView(width: geo.size.width, height: geo.size.height)
            }
            .contentShape(Rectangle())
            // The strip sits in the panel's scroll view, where the scroll view's pan competes
            // with the drag. The reorder grips of the same scroll view take the gesture first, so
            // the window moves instead of the panel scrolling.
            .highPriorityGesture(
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

    private func windowView(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.severityColor(.normal).opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.severityColor(.normal).opacity(0.5), lineWidth: 1.5)
            }
            // The mark spans the whole strip, so the window it shows is read at a glance.
            .frame(width: width * (window.upperBound - window.lowerBound), height: height)
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
    private enum Span: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue) Days" }
    }

    /// What reading the history gave.
    private enum ReadOutcome: Sendable {
        case read(records: [RhythmDayRecord], recordedDays: [Date])
        case failed(String)
    }

    @State private var mode: Mode = .day
    @State private var day = Date()
    @State private var span: Span = .month
    @State private var zoom: RhythmZoom = .day
    @State private var offset: TimeInterval = 0
    @State private var isPickingDay = false
    @State private var records: [RhythmDayRecord] = []
    /// The days that have a file at all. A day that has a file but no record is a day the store
    /// could not read, which is not the same as a day nothing was recorded on.
    @State private var recordedDays: Set<Date> = []
    /// Whether the history holds any day at all, which is what tells "nothing yet" apart from
    /// "not on that day".
    @State private var hasHistory = false
    /// What went wrong while reading the history, if anything.
    @State private var readError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            CapsuleSegments(options: Mode.allCases.map { ($0, $0.label) }, selection: $mode)
            chart
            summary
        }
        .task(id: refreshKey) {
            // The history grows while the tab is open, so it reloads on a timer as well as when
            // the day, the mode or the range changes.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: day) { _, _ in
            // The day on show decides how long it is, so a window that fitted yesterday's length
            // can stick out past the end of today's.
            clampOffset()
        }
    }

    /// The charts' data.
    private var bars: [RhythmBar] {
        switch mode {
        case .day:
            guard let record = selectedRecord else { return [] }
            return RhythmAnalytics.bars(for: record, zoom: zoom, offset: offset)
        case .average:
            return RhythmAnalytics.averageBars(for: records, zoom: zoom, offset: offset)
        }
    }

    /// The day on show, when it was recorded.
    private var selectedRecord: RhythmDayRecord? {
        records.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let readError {
                message("The rhythm history could not be read: \(readError)")
            } else if bars.isEmpty {
                message(emptyText)
            } else if hasNoReadings {
                message(mode == .day
                    ? "No readings were taken on this day."
                    : "No readings were taken in this range.")
            } else {
                // What the bars are counted in, so the chart says what it adds up.
                Text(zoom.unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
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
        .cardSurface()
    }

    /// A line of text where the chart would be.
    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
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
                    .onLongPressGesture(minimumDuration: 0.4) { isPickingDay = true }

                Button {
                    moveDay(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.severityColor(.normal))
            case .average:
                Text("Last \(span.rawValue) Days")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                CapsuleSegments(options: Span.allCases.map { ($0, $0.label) }, selection: $span)
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
                Text(axisLabels[step])
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
        VStack(alignment: .leading, spacing: 4) {
            // A write that failed leaves the chart empty with no explanation anywhere else, so the
            // failure is said out loud. The recorder keeps retrying, so the history is not lost.
            if let writeError {
                Text("Writing the rhythm history failed: \(writeError)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // A day the store could not read is left out of the average, and the average is
            // only the average of the days that are in it.
            if !unreadableDays.isEmpty, mode == .average, !bars.isEmpty {
                Text("\(unreadableDays.count) of the \(span.rawValue) days in this range could not be read.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // A read that failed leaves the summary out: the card says the history could not be
            // read, and a peak of the data that is still in memory would contradict that.
            if readError == nil, let peak = RhythmAnalytics.peakBars(in: bars), !bars.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(Theme.severityColor(.normal)).frame(width: 7, height: 7)
                    Text(summaryText(from: bars[peak.lowerBound].start))
                }
                .font(.system(size: 11))
            }
        }
    }

    /// What went wrong the last time the history could not be written, if anything.
    private var writeError: String? {
        container.rhythm.lastWriteError
    }

    /// What the empty chart says. "We do not know" is not the same as "nothing was used".
    private var emptyText: String {
        guard hasHistory else {
            // A recording that is switched off will not build up, so the empty state must not
            // promise that it will.
            guard container.rhythmSettings.isEnabled else {
                return "The rhythm recording is off. Turn it on in Settings to start recording."
            }
            return "Nothing recorded yet. The rhythm builds up from today."
        }
        // A day the store could not read is not a day nothing was recorded on.
        if !unreadableDays.isEmpty {
            return mode == .day
                ? "The history of this day could not be read. The file was left as it is, and nothing was recorded for the day."
                : "None of the days in this range could be read. Their files were left as they are."
        }
        return mode == .day ? "Nothing was recorded on this day." : "Nothing was recorded in this range."
    }

    /// The days of the range that have a file but no record: the store could not read them.
    ///
    /// The store skips such a day with a warning and returns the rest, so the days that are
    /// missing from the records are the ones it refused.
    private var unreadableDays: [Date] {
        let calendar = Calendar.current
        let range = daysToRead
        let first = calendar.startOfDay(for: range.lowerBound)
        let last = calendar.startOfDay(for: range.upperBound)
        let read = Set(records.map { calendar.startOfDay(for: $0.day) })
        return recordedDays
            .filter { $0 >= first && $0 <= last && !read.contains(calendar.startOfDay(for: $0)) }
            .sorted()
    }

    /// Whether the days on show hold no reading at all. The chart would be an empty grid then,
    /// with nothing on it to say why.
    private var hasNoReadings: Bool {
        !bars.isEmpty && bars.allSatisfy { $0.samples == 0 }
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The whole day at hourly resolution, for the strip above the chart.
    private var contextBars: [RhythmBar] {
        switch mode {
        case .day:
            guard let record = selectedRecord else { return [] }
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
        "\(mode.rawValue)-\(day.timeIntervalSince1970)-\(span.rawValue)"
    }

    /// The five labels of the axis.
    private var axisLabels: [String] {
        Self.axisLabels(zoom: zoom, start: bars.first?.start ?? Calendar.current.startOfDay(for: day))
    }

    /// The labels of the axis over a window: five of them, every sixth bar.
    ///
    /// A whole day is the window's own hours, numbered from zero. The window is a fixed
    /// twenty-four hours from the day's midnight, so its hours are the same on a day of
    /// twenty-three or twenty-five hours, and the axis does not mix a nominal end with clock
    /// times. A narrowed window is on the clock: it begins and ends at a time of the day.
    static func axisLabels(zoom: RhythmZoom, start: Date) -> [String] {
        if zoom == .day {
            return (0..<5).map { String($0 * 6) }
        }
        return (0..<5).map { step in
            start.addingTimeInterval(Double(step) * 6 * zoom.barDuration)
                .formatted(date: .omitted, time: .shortened)
        }
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
        offset = Self.clampedOffset(offset, zoom: zoom, dayLength: dayLength)
    }

    /// The offset the chart can show.
    ///
    /// The whole day starts at the day's midnight, so the offset goes back to zero there: on a day
    /// of twenty-five hours an offset of an hour would leave the chart starting at 01:00 while
    /// the axis still counts from zero. A window shorter than the day can only start so far into
    /// it, and it always starts on a bar boundary, so the bars stay aligned with the buckets.
    static func clampedOffset(_ offset: TimeInterval, zoom: RhythmZoom, dayLength: TimeInterval) -> TimeInterval {
        guard zoom != .day else { return 0 }
        let clamped = min(max(offset, 0), max(0, dayLength - zoom.window))
        return (clamped / zoom.barDuration).rounded(.down) * zoom.barDuration
    }

    /// The days the chart needs: the selected day, or the days the chosen range covers.
    private var daysToRead: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // The store compares days, so the range covers whole days: a range that starts in the
        // afternoon would otherwise leave that day's record out.
        switch mode {
        case .day:
            let selected = calendar.startOfDay(for: day)
            return selected...selected
        case .average:
            let start = calendar.date(byAdding: .day, value: -(span.rawValue - 1), to: today) ?? today
            return start...today
        }
    }

    /// Reads the history off the main thread: the file store decodes up to ninety day files, and
    /// the tab reloads every thirty seconds, so the reading does not belong on the main thread.
    private func load() async {
        let store = container.rhythm.store
        let days = daysToRead
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let records = try store.load(days: days)
                let recorded = try store.recordedDays()
                return ReadOutcome.read(records: records, recordedDays: recorded)
            } catch {
                return ReadOutcome.failed(error.localizedDescription)
            }
        }.value
        // The reading may have been overtaken while it was running. A detached read is
        // unstructured: it is not cancelled with the task that started it, so a reading that is
        // no longer the one the view wants must not be applied — the chart would show the days of
        // the previous range under the title of the current one, and a late failure would replace
        // a good chart with an error message. A view that went away applies nothing at all.
        guard !Task.isCancelled, days == daysToRead else { return }
        switch outcome {
        case .read(let loaded, let recorded):
            records = loaded
            recordedDays = Set(recorded)
            hasHistory = !recorded.isEmpty
            readError = nil
        case .failed(let message):
            // A history that cannot be read is not a history that was never written: the user has
            // to be told, and the log has to say what happened.
            AppLog.error(.rhythm, "could not read the rhythm history: \(message)")
            readError = message
        }
    }
}
```

- [ ] **Step 6: Add the tab**

In `Sources/OpenUsage/Models/DashboardTab.swift`, add the case:

```swift
    case rhythm
```

and the label:

```swift
        case .rhythm: "Rhythm"
```

The tab bar in `PopoverTopBar` and the "Default Tab" picker in Settings both build their options
from `DashboardTab.allCases`, so the new case appears in both without another change.

In `Sources/OpenUsage/Views/DashboardContentView.swift`, the rhythm tab has to come **before** the
two guards: the rhythm is recorded from what the provider reports and does not depend on which
metrics the user has shown, so it stays available when every metric is hidden.

```swift
    @ViewBuilder
    private var widgetContent: some View {
        if layout.registry.providers.isEmpty {
            EmptyDashboardView { popover.isAddingAccount = true }
        } else if popover.dashboardTab == .rhythm {
            RhythmView()
        } else if layout.displayGroups.isEmpty {
            Text("Every metric is hidden. Turn them back on in Accounts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        } else {
            switch popover.dashboardTab {
            case .priority:
                PriorityDashboardView()
            case .allUsage:
                WidgetGroupedListView(
                    reorderSpaceName: reorderSpaceName,
                    reorderLift: $reorderLift
                )
            case .rhythm:
                RhythmView()
            }
        }
    }
```

- [ ] **Step 7: Run the chart tests to verify they pass**

Run: `script/test_quiet.sh --filter RhythmChartTests`

Expected: PASS — 4 tests, 0 failures.

If the pixel assertions do not match macOS's system blue, loosen the filters in
`stronglyBluePixels` and `inkPixels` to the blue that actually came out — print the pixels once and
set the thresholds to them. The point of the tests is that the peak is the strong blue, that a
burn without a reading of its own is still drawn, that a slice that was read but not used draws a
baseline, and that a slice that was not read draws nothing at all.

- [ ] **Step 8: Build the app**

Run: `swift build --scratch-path "$HOME/build"`

Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Sources/OpenUsage/Views/RhythmChart.swift Sources/OpenUsage/Views/RhythmContextStrip.swift Sources/OpenUsage/Views/RhythmView.swift Sources/OpenUsage/Models/DashboardTab.swift Sources/OpenUsage/Views/DashboardContentView.swift Tests/OpenUsageTests/RhythmChartTests.swift
git commit -m "feat(rhythm): show the rhythm in a dashboard tab"
```

---

## Notes for the task that comes next (the settings and the docs)

- **`AppContainer.rhythm` is the recorder, and `recorder.store` is the history.** The settings
  screen needs the store to delete the history, and the recorder's settings to switch the
  recording off.
- **`RhythmSettings.retentionDays` is 90.** The store trims the days older than that.

---

### Task 6: The settings, the docs and the green suite

**Files:**
- Modify: `Sources/OpenUsage/Views/SettingsScreen.swift`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Create: `docs/rhythm.md`
- Modify: `docs/dashboard.md`
- Modify: `docs/settings.md`
- Modify: `docs/privacy.md`

**Interfaces:**
- Consumes: `RhythmSettings`, `AppContainer.rhythm` from Tasks 2 and 3.
- Produces: the switch and the delete button in Settings; the fifth divergence section in `AGENTS.md`;
  `docs/rhythm.md`.

- [ ] **Step 1: Add the switch and the delete button**

In `Sources/OpenUsage/Views/SettingsScreen.swift`, the settings screen binds to its stores with
`@Bindable`, not with a hand-made `Binding` — a `Binding`'s closures are not actor-isolated, so
touching a `@MainActor` store inside them does not compile under Swift 6.

At the top of `displayTab`, next to the existing `@Bindable var dataStore = dataStore`:

```swift
        @Bindable var rhythmSettings = container.rhythmSettings
```

Then add the two rows to the `Section("Usage")`:

```swift
            Toggle(isOn: $rhythmSettings.isEnabled) {
                titled("Record Usage Rhythm", info: "Keeps how fast your limits fill up, on this Mac")
            }
            Button("Delete Rhythm History") {
                isConfirmingRhythmDeletion = true
            }
            .disabled(!hasRhythmHistory)
            .confirmationDialog(
                "Delete Rhythm History?",
                isPresented: $isConfirmingRhythmDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete Rhythm History", role: .destructive) { deleteRhythmHistory() }
            }
```

The deletion asks first, the way the other deletions in the app ask. And the state and the two
helpers on the view:

```swift
    /// Whether there is any rhythm history to delete. It is state, not a computed property, so
    /// the button can go back to being disabled after the history is gone.
    @State private var hasRhythmHistory = false
    /// What to tell the user when the history could not be deleted.
    @State private var rhythmErrorMessage: String?
    /// Whether the user is asked to confirm the deletion of the history.
    @State private var isConfirmingRhythmDeletion = false
```

```swift
    /// Whether there is anything to delete. The history is read from the store, not counted from
    /// the settings, so the button is only enabled when there is a file to remove.
    private func refreshRhythmHistoryState() {
        do {
            hasRhythmHistory = !(try container.rhythm.store.recordedDays().isEmpty)
        } catch {
            // A history that cannot be read is not an empty one: say so instead of offering a
            // button that would fail the same way.
            hasRhythmHistory = false
            AppLog.warn(.rhythm, "the rhythm history could not be read: \(error.localizedDescription)")
            rhythmErrorMessage = "The rhythm history could not be read: \(error.localizedDescription)"
        }
    }

    private func deleteRhythmHistory() {
        do {
            // The recorder writes the day it is on again on the next refresh, so the history is
            // deleted through the recorder, which lets go of what it holds as well.
            try container.rhythm.deleteHistory()
            AppLog.notice(.rhythm, "the rhythm history was deleted")
            rhythmErrorMessage = nil
            refreshRhythmHistoryState()
        } catch {
            // Say what happened rather than what was meant: the files are still there, so the
            // button stays as it is. The message of the failed deletion is kept: a state refresh
            // that failed as well must not hide it.
            AppLog.warn(.rhythm, "the rhythm history could not be deleted: \(error.localizedDescription)")
            rhythmErrorMessage = "The rhythm history could not be deleted: \(error.localizedDescription)"
            hasRhythmHistory = true
        }
    }
```

The state has to be read when the screen appears, so the button is only enabled when there is
something to delete. Put it on the Usage section:

```swift
        Section("Usage") {
            ...
        }
        .task { refreshRhythmHistoryState() }
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
`~/Library/Application Support/OpenUsage/rhythm/<bundle id>/`, one file per local day. The app's
bundle identifier is in the path, so a development build and the installed app never write over
each other's history.

What a file holds is the share of the window that was used, the provider it came from, the name of
the metric and a local account id. It never holds a token count, a price, an account name or an
email address. Nothing leaves this Mac: the history is never uploaded, and the app never reads the
logs of other tools.

Only windows of a day or less are recorded. A weekly limit sampled every few minutes is a slow
drift, and its hourly rate says nothing about when you are actually working.

A metric whose unit is money is not recorded. A dollar budget is the rate at which money is
spent, and this app does not chart spending. What the chart carries is the share of each recorded
window — a percentage or a count — and nothing else.

The history is kept in the app's own format, and the app never writes over a file it cannot read.
If a day's file cannot be read — after a change of time zone, for instance, its five-minute
buckets no longer fit the day — that day records nothing, the file is left exactly as it is, and
the chart says the day could not be read.

A burn that crosses the midnight belongs to both days it touches: the part before the midnight to
the day that ended, the rest to the day that began. Nothing of it is lost, and neither day's
figure counts it twice.

## The two views

**This Day** shows one day. The arrows step a day at a time, and a long press on the date opens a
calendar. **Average** shows the last 7, 30 or 90 days averaged, so the shape of a usual week shows
through the noise of one day.

## Zooming in

The chart always has 24 bars. The zoom control changes how much of the day they cover: a day, half
a day, six hours or two hours. Above the chart, the strip of the whole day marks the window the
chart is showing; drag that mark to move the window through the day.

## Reading the chart

A bar's height is how much of the window that slice burned, as a share of the window. The peak is
drawn in the app's blue and the rest in a lighter shade of it. A slice that was read but not used
shows a thin baseline. A slice nothing was read from stays empty: "we do not know" is not "nothing
was used".

The chart adds up the share of every recorded window, including windows of different lengths: two
accounts whose windows each burned 5% make a bar of 10 points. The unit above the chart says how
much time each bar covers, so it follows the zoom level — "Percentage Points / Hour" for a whole
day, "Percentage Points / 5 Minutes" for the narrowest one.

Turn the recording off in **Settings → Display → Usage → Record Usage Rhythm**, and remove what was
already recorded with **Delete Rhythm History**, which asks before it removes anything. The two are
separate: turning the recording off keeps the history, and deleting the history leaves the recording
on. While the recording is on, the current day's file fills up again.

The delete button is greyed out when the settings screen finds no history to remove. It is checked
when the screen is opened, so a history that is recorded afterwards is only removed once the screen
is opened again.
```
# Usage Rhythm

The **Rhythm** tab of the dashboard records how fast each account's limits fill up, and shows when
your busy hours are.

## What is recorded

Every refresh, the app notes how much of each limit's window has been used and when. From those
notes it builds a five-minute history of the last 90 days, kept in
`~/Library/Application Support/OpenUsage/rhythm/<bundle id>/`, one file per local day. The app's
bundle identifier is in the path, so a development build and the installed app never write over
each other's history.

What a file holds is the share of the window that was used, the provider it came from, the name of
the metric and a local account id. It never holds a token count, a price, an account name or an
email address. Nothing leaves this Mac: the history is never uploaded, and the app never reads the
logs of other tools.

Only windows of a day or less are recorded. A weekly limit sampled every few minutes is a slow
drift, and its hourly rate says nothing about when you are actually working.

A metric whose unit is money is not recorded. A dollar budget is the rate at which money is
spent, and this app does not chart spending. What the chart carries is the share of each recorded
window — a percentage or a count — and nothing else.

## The two views

**This Day** shows one day. The arrows step a day at a time, and a long press on the date opens a
calendar. **Average** shows the last 7, 30 or 90 days averaged, so the shape of a usual week shows
through the noise of one day.

## Zooming in

The chart always has 24 bars. The zoom control changes how much of the day they cover: a day, half
a day, six hours or two hours. Above the chart, the strip of the whole day marks the window the
chart is showing; drag that mark to move the window through the day.

## Reading the chart

A bar's height is how much of the window that slice burned, as a share of the window. The peak is
drawn in the app's blue and the rest in a lighter shade of it. A slice that was read but not used
shows a thin baseline. A slice nothing was read from stays empty: "we do not know" is not "nothing
was used".

The chart adds up the share of every recorded window, including windows of different lengths: two
accounts whose windows each burned 5% make a bar of 10 points. The unit above the chart says how
much time each bar covers, so it follows the zoom level — "Percentage Points / Hour" for a whole
day, "Percentage Points / 5 Minutes" for the narrowest one.

Turn the recording off in **Settings → Display → Usage → Record Usage Rhythm**, and remove what was
already recorded with **Delete Rhythm History**, which asks before it removes anything. The two are
separate: turning the recording off keeps the history, and deleting the history leaves the recording
on. While the recording is on, the current day's file fills up again.

The delete button is greyed out when the settings screen finds no history to remove. It is checked
when the screen is opened, so a history that is recorded afterwards is only removed once the screen
is opened again.

- [ ] **Step 3: Point the other pages at it**

`docs/dashboard.md` gains a section:

```markdown
## Rhythm

The third tab, **Rhythm**, records how fast each limit fills up and shows when your busy hours
are. See [Usage Rhythm](rhythm.md).
```

And its opening lines change, because they count the tabs:

```markdown
The panel that opens from the menu bar icon. It has three tabs, Priority, All Usage and Rhythm.
```

```markdown
- With no accounts, every tab shows **Add Account**.
```

`docs/README.md` names the tabs in its one-line summary:

```markdown
- [Dashboard](dashboard.md): the Priority, All Usage and Rhythm tabs, right-click menus, reordering, shortcuts
```

`docs/settings.md` gains a section after **Usage display**:

```markdown
## Usage rhythm

- **Record Usage Rhythm.** Keeps how fast your limits fill up, so the **Rhythm** tab can show when
  your busy hours are. On by default. Turning it off stops the recording and keeps what was already
  recorded.
- **Delete Rhythm History.** Removes the recorded history from this Mac. Stopping the recording and
  deleting the history are two different things, and this is the second one.

See [Usage Rhythm](rhythm.md).
```

`docs/privacy.md` gains a section before **Screen sharing**:

```markdown
## Usage rhythm history

- The **Rhythm** tab keeps a five-minute history of how fast each account's limits fill up, in
  `~/Library/Application Support/OpenUsage/rhythm/`, one file per local day, for the last 90 days.
  The app's bundle identifier is in the path, so a development build and the installed app keep
  separate histories.
- A file holds the share of each window that was used, the provider, the metric name and a local
  account id. It holds no token count, no price, no account name and no email address.
- The history never leaves this Mac. It is not uploaded, and it is not part of the telemetry the
  app sends — see [Anonymous telemetry](#anonymous-telemetry).
- **Settings → Usage → Delete Rhythm History** removes it. Turning **Record Usage Rhythm** off
  stops the recording but keeps the history.
```

`README.md` gains a bullet in **Features**:

```markdown
- **[Usage rhythm](docs/rhythm.md).** A third tab that records how fast your limits fill up and
  shows when your busy hours are.
```

and a link in **Documentation**:

```markdown
- [Usage rhythm](docs/rhythm.md)
```

- [ ] **Step 4: Record the divergence in `AGENTS.md`**

In `AGENTS.md`, insert a fifth section after "### 4. The fork's own menu bar and settings" and
renumber the sync-cadence section to six:

```markdown
### 5. The fork records usage rhythm

Upstream has none of this; the fork keeps it across a sync.

- The **Rhythm** tab records how fast each account's provider-reported window fills up, and shows
  when the peak hours are. It records the share of each window that was used — the provider's own
  reported number against its own limit — sampled on every refresh and differenced between
  readings. No log scanning, no spend estimate, no pricing and no absolute token count anywhere
  in it, which is what section 3's body bans.
- Section 3's heading also says "no trend". The rhythm is a time series, so this is the fork's
  deliberate reading of that heading: the ban is on trends of *spend*, and the rhythm charts the
  provider's own reported window. It is recorded here so that a sync does not quietly drop it.
- The history lives in `~/Library/Application Support/OpenUsage/rhythm/<bundle id>/`, one file per
  local day, and is never uploaded. Section 3 also forbids reading other tools' credentials, files
  and logs; the rhythm reads none of them.
- Keep the recording and the analysis in `Sources/OpenUsage/Rhythm/`, and the views in
  `Sources/OpenUsage/Views/Rhythm*.swift`. A future cloud store is one more `RhythmStore`
  implementation, not a change to the recorder or the chart — and it needs its own stable identity
  for an account, because the account's card id is local to this Mac.
```

- [ ] **Step 5: Run the whole suite**

Run: `script/test_quiet.sh`

Expected: every test passes, 0 failures. The suite has 878 tests before this task.

- [ ] **Step 6: Build and check the app runs**

Run: `script/build_and_run.sh verify`

Expected: the build succeeds, the bundle is signed and verifies, and the app is running.

This replaces the running dev build in `dist/` with the new one, which is how the app is always
run in this repo — the app is a long-lived process, so every change needs a rebuild and a restart.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenUsage/Views/SettingsScreen.swift README.md AGENTS.md docs/rhythm.md docs/dashboard.md docs/settings.md docs/privacy.md
git commit -m "feat(rhythm): add the settings, the docs and the divergence"
```

---

## Notes

- **The switch does not delete anything.** Turning the recording off stops the readings; what was
  already recorded is written out and kept. The button is the one that removes it.
- **`RhythmSettings` is a `@MainActor @Observable` class**, and its `isEnabled` writes itself to
  `UserDefaults` in a `didSet`. The recorder reads it on every refresh, so the switch takes effect
  right away.
- **The store's `delete(before:)` compares days**, so the cutoff is a moment that names the first
  day to keep — tomorrow's midnight keeps nothing.

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
`container.rhythm.store` and `container.rhythmSettings`. `RhythmStore` gained `load(days:)` in Task 1's fix round, and the
protocol has not changed since.

**Known gaps this plan leaves open, and why.** The chart's axis labels and the summary wording are
written against the English locale; a Chinese or German build shows the times in its own format
because they go through `Date.formatted`. The per-provider breakdown of the chart is deliberately
not built — the data is in the store, but the interface does not offer it. The cloud store is a
protocol implementation, not written now.
