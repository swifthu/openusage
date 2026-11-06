import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The rhythm tab: it says what it knows and what it does not, and it puts the peak of a
/// recorded day on show.
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

    private func texts(in element: Any) -> [String] {
        guard let node = element as? NSObject else { return [] }
        let text = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue
            ? (node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String) : nil
        return [text].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(texts)
    }
}
