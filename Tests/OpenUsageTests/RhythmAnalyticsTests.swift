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
}
