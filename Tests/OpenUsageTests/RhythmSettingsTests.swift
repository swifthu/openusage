import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The rhythm's two rows in Settings: the switch that stops the recording, and the button that
/// removes what was already recorded.
@MainActor
final class RhythmSettingsTests: QuietWindowTestCase {
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

    /// The Usage section shows the recording's switch and the button that removes the history.
    func testTheUsageSectionShowsTheRhythmRows() async throws {
        let (_, host) = showSettings(store: RecordingRhythmStore(calendar: .current))
        try await waitUntil { self.texts(in: host).contains("Record Usage Rhythm") }

        XCTAssertTrue(texts(in: host).contains("Record Usage Rhythm"), "the switch that stops the recording is there")
        XCTAssertNotNil(deleteButton(in: host), "the button that removes the history is there")
    }

    /// The button is only enabled when there is a history to remove.
    func testTheDeleteButtonIsOnlyEnabledWhenThereIsAHistory() async throws {
        let store = RecordingRhythmStore(calendar: .current)
        let (_, host) = showSettings(store: store)
        try await waitUntil { self.deleteButton(in: host) != nil }
        XCTAssertEqual(deleteButton(in: host), false, "no history, so nothing to delete")

        try store.save(recordToday())
        let (_, host2) = showSettings(store: store)
        try await waitUntil { self.deleteButton(in: host2) == true }
        XCTAssertEqual(deleteButton(in: host2), true, "a history is there, so it can be deleted")
    }

    /// The switch is the recording's own switch: clicking it turns the recording off.
    func testTheSwitchTurnsTheRecordingOff() async throws {
        let container = makeContainer(store: RecordingRhythmStore(calendar: .current))
        XCTAssertTrue(container.rhythmSettings.isEnabled, "the recording is on by default")

        let (_, host) = showSettings(container: container)
        try await waitUntil { self.rhythmSwitch(in: host) != nil }
        rhythmSwitch(in: host)?.performClick(nil)

        try await waitUntil { !container.rhythmSettings.isEnabled }
        XCTAssertFalse(container.rhythmSettings.isEnabled, "the switch turned the recording off")
    }

    /// The remaining share of the 5-hour windows is the user's choice: the switch turns it off.
    func testTheSwitchTurnsTheTrackingOfTheFiveHourWindowsOff() async throws {
        let container = makeContainer(store: RecordingRhythmStore(calendar: .current))
        XCTAssertTrue(container.rhythmSettings.tracksSessionWindows, "the tracking is on by default")

        let (_, host) = showSettings(container: container)
        try await waitUntil { self.switchControl(for: "Track 5-Hour Windows", in: host) != nil }
        switchControl(for: "Track 5-Hour Windows", in: host)?.performClick(nil)

        try await waitUntil { !container.rhythmSettings.tracksSessionWindows }
        XCTAssertFalse(container.rhythmSettings.tracksSessionWindows, "the switch turned the tracking off")
    }

    /// Removing the history takes today's own record with it, and the recorder lets go of what it
    /// holds, so the day is not written out again on the next refresh.
    func testRemovingTheHistoryEmptiesItAndLetsTheRecorderLetGo() throws {
        let store = RecordingRhythmStore(calendar: .current)
        try store.save(RhythmDayRecord(day: Calendar.current.startOfDay(for: Date()), series: []))
        let recorder = RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: .current)

        try recorder.deleteHistory()

        XCTAssertEqual(try store.recordedDays(), [], "every recorded day is gone")
        XCTAssertEqual(recorder.heldDays, [], "the recorder holds nothing any more")
    }

    // MARK: - Helpers

    private func makeContainer(store: RecordingRhythmStore) -> AppContainer {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()),
            defaults: defaults,
            rhythmStore: store
        )
        // The rhythm's rows live in the Usage section of the Display tab.
        container.popover.settingsTab = .display
        return container
    }

    private func showSettings(store: RecordingRhythmStore) -> (window: NSWindow, host: NSView) {
        showSettings(container: makeContainer(store: store))
    }

    private func showSettings(container: AppContainer) -> (window: NSWindow, host: NSView) {
        let settings = SettingsScreen()
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(UpdaterController())
        return show(settings, in: .titled, size: CGSize(width: PanelMetrics.width, height: 900))
    }

    private func recordToday() -> RhythmDayRecord {
        RhythmDayRecord(day: Calendar.current.startOfDay(for: Date()), series: [])
    }

    /// The accessibility tree of a view, in the order the rows are on show.
    private func nodes(in element: Any) -> [(role: String, label: String, value: String, enabled: Bool)] {
        guard let node = element as? NSObject else { return [] }
        let role = node.value(forKey: "accessibilityRole") as? String ?? ""
        let label = node.value(forKey: "accessibilityLabel") as? String ?? ""
        let value = node.value(forKey: "accessibilityValue") as? String ?? ""
        let enabled = node.value(forKey: "accessibilityEnabled") as? Bool ?? false
        let children = (node.value(forKey: "accessibilityChildren") as? [Any] ?? [])
        return [(role, label, value, enabled)] + children.flatMap { nodes(in: $0) }
    }

    /// The texts of the accessibility tree.
    private func texts(in element: Any) -> [String] {
        nodes(in: element).compactMap { $0.role == NSAccessibility.Role.staticText.rawValue ? ($0.value.isEmpty ? $0.label : $0.value) : nil }
    }

    /// The "Delete Rhythm History" button. A SwiftUI button is not an AppKit button, so it is read
    /// through the accessibility tree.
    private func deleteButton(in element: Any) -> Bool? {
        nodes(in: element).first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "Delete Rhythm History" }
            .map(\.enabled)
    }

    /// The switch of the "Record Usage Rhythm" row.
    private func rhythmSwitch(in host: NSView) -> NSSwitch? {
        switchControl(for: "Record Usage Rhythm", in: host)
    }

    /// The switch of a row. It is the checkbox that comes right after the row's text in the tree,
    /// and the switches of the tab are in the same order.
    private func switchControl(for label: String, in host: NSView) -> NSSwitch? {
        let tree = nodes(in: host)
        guard let textIndex = tree.firstIndex(where: {
            $0.role == NSAccessibility.Role.staticText.rawValue && ($0.value == label || $0.label == label)
        }) else { return nil }
        let boxesBefore = tree[..<textIndex].filter { $0.role == NSAccessibility.Role.checkBox.rawValue }.count
        var switches: [NSSwitch] = []
        func walk(_ view: NSView) {
            if let control = view as? NSSwitch { switches.append(control) }
            view.subviews.forEach { walk($0) }
        }
        walk(host)
        return switches.indices.contains(boxesBefore) ? switches[boxesBefore] : nil
    }
}
