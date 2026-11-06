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

    private func snapshot(fraction: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "account-1",
            displayName: "Claude",
            lines: [.progress(
                label: "Session",
                used: fraction * 100,
                limit: 100,
                format: .percent,
                resetsAt: Date().addingTimeInterval(3600),
                periodDurationMs: MetricPeriod.sessionMs
            )]
        )
    }

    func testASuccessfulRefreshFeedsTheRecorder() async {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(
            store: store,
            settings: RhythmSettings(defaults: isolatedDefaults()),
            calendar: calendar
        )
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
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = RhythmRecorder(
            store: store,
            settings: RhythmSettings(defaults: isolatedDefaults()),
            calendar: calendar
        )
        let runtime = StubRuntime(
            provider: Provider(id: "account-1", kind: .claude),
            descriptors: [],
            failure: RefreshFailure(message: "Unreachable", kind: .unreachable)
        )
        let dataStore = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), rhythm: recorder)

        await dataStore.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertTrue(recorder.pendingSeries.isEmpty)
    }
}
