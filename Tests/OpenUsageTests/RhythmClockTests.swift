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
