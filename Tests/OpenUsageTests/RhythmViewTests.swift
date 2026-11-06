import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The rhythm tab: it says what it knows and what it does not, it puts the peak of a recorded day
/// on show, and it reads the days the chart is showing.
@MainActor
final class RhythmViewTests: QuietWindowTestCase {
    override func setUp() {
        super.setUp()
        // The texts of a SwiftUI view only reach the accessibility tree when the system is told
        // to look for them.
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    }

    override func tearDown() {
        NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface")
        super.tearDown()
    }

    /// A history with nothing in it must not look like a day nothing was used on.
    func testAnEmptyHistorySaysNothingWasRecordedYet() async throws {
        let container = makeContainer(store: RecordingRhythmStore(calendar: .current))
        let (_, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))

        try await waitUntil {
            texts(in: host).contains("Nothing recorded yet. The rhythm builds up from today.")
        }
    }

    /// A recorded day puts its peak on show, with the hours it runs.
    func testARecordedDayShowsItsPeak() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        try store.save(recordToday())
        let container = makeContainer(store: store)
        let (_, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))

        try await waitUntil {
            texts(in: host).contains { $0.hasPrefix("This day's peak is") }
        }
    }

    /// The range on show decides what is read: each of the three spans asks for its own number of
    /// days.
    func testTheChosenRangeDecidesWhatIsRead() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        let container = makeContainer(store: store)
        let (window, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))
        try await waitUntil { !store.requestedRanges.isEmpty }

        // The average reads the days of its span, and each span reads its own number of days.
        try await clickUntil([CGPoint(x: 255, y: 16), CGPoint(x: 250, y: 8), CGPoint(x: 260, y: 24)], window, host) {
            days(in: lastFinishedRange(in: store)) == 30
        }
        XCTAssertEqual(days(in: lastFinishedRange(in: store)), 30, "the average of a month reads thirty days")

        try await clickUntil([CGPoint(x: 124, y: 60), CGPoint(x: 130, y: 56), CGPoint(x: 120, y:  64)], window, host) {
            days(in: lastFinishedRange(in: store)) == 7
        }
        XCTAssertEqual(days(in: lastFinishedRange(in: store)), 7, "the average of a week reads seven days")

        try await clickUntil([CGPoint(x: 244, y: 60), CGPoint(x: 250, y: 56), CGPoint(x: 240, y: 64)], window, host) {
            days(in: lastFinishedRange(in: store)) == 90
        }
        XCTAssertEqual(days(in: lastFinishedRange(in: store)), 90, "the average of a quarter reads ninety days")
    }

    /// "This Day" reads exactly one day: the day on show, not today.
    func testThisDayReadsExactlyOneDay() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        let container = makeContainer(store: store)
        let (window, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))
        try await waitUntil { !store.requestedRanges.isEmpty }

        let today = Calendar.current.startOfDay(for: Date())
        let first = try XCTUnwrap(store.requestedRanges.first)
        XCTAssertEqual(first.lowerBound, first.upperBound, "This Day reads one day")
        XCTAssertEqual(first.lowerBound, today, "and it is the day on show")

        // The arrow a day back moves the day on show, and the read follows it.
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        try await clickUntil([CGPoint(x: 14, y: 56), CGPoint(x: 14, y: 52), CGPoint(x: 16, y: 60)], window, host) {
            lastFinishedRange(in: store)?.lowerBound == yesterday
        }
        let moved = try XCTUnwrap(lastFinishedRange(in: store))
        XCTAssertEqual(moved.lowerBound, moved.upperBound, "still one day")
        XCTAssertEqual(moved.lowerBound, yesterday, "the day on show, not today")
    }

    /// The axis of a whole day is the window's own hours: it does not mix a nominal end with
    /// clock times, and it does not shift on a day that is 23 or 25 hours long.
    func testTheAxisOfAWholeDayCountsItsHours() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        try store.save(recordToday())
        let container = makeContainer(store: store)
        let (_, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))
        try await waitUntil {
            texts(in: host).contains { $0.hasPrefix("This day's peak is") }
        }

        let shown = texts(in: host)
        for hour in ["0", "6", "12", "18", "24"] {
            XCTAssertTrue(shown.contains(hour), "the axis carries the hour \(hour)")
        }
        XCTAssertFalse(shown.contains("24:00"), "the axis does not carry a hard-written end")
        let midnight = Calendar.current.startOfDay(for: Date()).formatted(date: .omitted, time: .shortened)
        XCTAssertFalse(shown.contains(midnight), "the axis of a whole day carries no clock time")
    }

    /// A narrowed window is on the clock: it ends at the time the window ends at, not at a
    /// nominal end.
    func testANarrowedWindowEndsOnItsOwnClockTime() {
        let start = Calendar.current.startOfDay(for: Date())
        let labels = RhythmView.axisLabels(zoom: .halfDay, start: start)

        XCTAssertEqual(labels.first, start.formatted(date: .omitted, time: .shortened), "the window begins at its own start")
        XCTAssertEqual(
            labels.last,
            start.addingTimeInterval(RhythmZoom.halfDay.window).formatted(date: .omitted, time: .shortened),
            "the window ends at its own end"
        )
        XCTAssertNotEqual(labels.last, labels.first, "a narrowed window does not end where it begins")
    }

    /// A history that cannot be read is not a history that was never written.
    func testAHistoryThatCannotBeReadSaysSo() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        store.setFailingLoad(true)
        let container = makeContainer(store: store)
        let (_, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))

        try await waitUntil {
            texts(in: host).contains { $0.contains("could not be read") }
        }
        XCTAssertFalse(
            texts(in: host).contains("Nothing recorded yet. The rhythm builds up from today."),
            "a history that cannot be read does not look like a history that was never written"
        )
    }

    /// An average of days that hold no reading is not an empty grid without an explanation.
    func testAnAverageOfNothingSaysSo() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        // A day that was recorded but holds no reading at all.
        try store.save(RhythmDayRecord(day: Calendar.current.startOfDay(for: Date()), series: []))
        let container = makeContainer(store: store)
        let (window, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))
        try await waitUntil { !store.requestedRanges.isEmpty }

        try await clickUntil([CGPoint(x: 255, y: 16), CGPoint(x: 250, y: 8), CGPoint(x: 260, y: 24)], window, host) {
            texts(in: host).contains("No readings were taken in this range.")
        }
        XCTAssertTrue(texts(in: host).contains("No readings were taken in this range."), "the average says what it means")
    }

    /// A reading that was overtaken must not be applied: a late failure must not replace a good
    /// chart with an error message.
    func testAReadingThatWasOvertakenIsNotApplied() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        // The first read is slow and fails; the read that follows it is an ordinary one.
        store.setFirstLoadFailing(after: 1)
        let container = makeContainer(store: store)
        let (window, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))

        // The first read is still running.
        try await waitUntil { store.readAttempts >= 1 }

        // The average reads its own days, and that read is quick.
        try await clickUntil([CGPoint(x: 255, y: 16), CGPoint(x: 250, y: 8), CGPoint(x: 260, y: 24)], window, host) {
            days(in: lastFinishedRange(in: store)) == 30
        }

        // The slow read has failed by now. Its failure is not the one the view wants.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(
            texts(in: host).contains { $0.contains("could not be read") },
            "a reading that was overtaken does not replace the chart with an error"
        )
    }

    /// A day that was recorded but holds no reading at all is an empty grid without an
    /// explanation, in the day mode as well as in the average one.
    func testADayOfNothingSaysSo() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        try store.save(RhythmDayRecord(day: Calendar.current.startOfDay(for: Date()), series: []))
        let container = makeContainer(store: store)
        let (_, host) = show(rhythmView(container), in: .titled, size: CGSize(width: PanelMetrics.width, height: 400))

        try await waitUntil {
            texts(in: host).contains("No readings were taken in this range.")
        }
    }

    // MARK: - Helpers

    private func makeContainer(store: RecordingRhythmStore) -> AppContainer {
        let defaults = isolatedDefaults()
        return AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()),
            defaults: defaults,
            rhythmStore: store
        )
    }

    private func rhythmView(_ container: AppContainer) -> some View {
        RhythmView()
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(container.renaming)
    }

    /// A day with one busy hour at nine in the morning.
    private func recordToday() -> RhythmDayRecord {
        let buckets = 24 * 60 * 60 / Int(RhythmClock.bucketSeconds)
        var points = [Double](repeating: 0, count: buckets)
        var samples = [Int](repeating: 0, count: buckets)
        let nineAm = 9 * 60 * 60 / Int(RhythmClock.bucketSeconds)
        points[nineAm] = 0.4
        samples[nineAm] = 1
        return RhythmDayRecord(
            day: Calendar.current.startOfDay(for: Date()),
            series: [
                RhythmSeriesRecord(
                    key: "session",
                    kind: .claude,
                    label: "Session",
                    windowMs: 5 * 60 * 60 * 1000,
                    points: points,
                    samples: samples
                )
            ]
        )
    }

    /// The range of the read that finished last. The reads run in the background, so the order
    /// of the ranges is the order of completion, not the order of the requests.
    private func lastFinishedRange(in store: RecordingRhythmStore) -> ClosedRange<Date>? {
        store.requestedRanges.last
    }

    /// How many days a range covers, counted by their midnights: the day count of the calendar
    /// is not the number of days across a daylight-saving change, where a day is 23 or 25 hours
    /// long.
    private func days(in range: ClosedRange<Date>?) -> Int {
        guard let range else { return 0 }
        let calendar = Calendar.current
        var count = 0
        var day = calendar.startOfDay(for: range.lowerBound)
        let last = calendar.startOfDay(for: range.upperBound)
        while day <= last {
            count += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return count
    }

    /// Clicks the points in order until the view reacts.
    ///
    /// The controls of the tab carry no identifier, so they are found by where they are on the
    /// panel; the search keeps the test from breaking when the layout shifts a little. The first
    /// click of a fresh window can be swallowed as well, which the next point takes care of.
    private func clickUntil(
        _ points: [CGPoint],
        _ window: NSWindow,
        _ host: NSView,
        _ reacted: @MainActor () -> Bool
    ) async throws {
        for point in points {
            click(point, window, host)
            try await Task.sleep(for: .milliseconds(150))
            if reacted() { return }
        }
        XCTFail("the view did not react to the click")
    }

    private func texts(in element: Any) -> [String] {
        guard let node = element as? NSObject else { return [] }
        let text = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue
            ? (node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String) : nil
        return [text].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(texts)
    }
}
