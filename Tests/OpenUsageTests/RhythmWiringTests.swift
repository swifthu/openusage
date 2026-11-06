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

    private func snapshot(fraction: Double, at now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "account-1",
            displayName: "Claude",
            lines: [.progress(
                label: "Session",
                used: fraction * 100,
                limit: 100,
                format: .percent,
                resetsAt: now.addingTimeInterval(3600),
                periodDurationMs: MetricPeriod.sessionMs
            )]
        )
    }

    private func recorder(_ store: RecordingRhythmStore) -> RhythmRecorder {
        RhythmRecorder(store: store, settings: RhythmSettings(defaults: isolatedDefaults()), calendar: calendar)
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
        let series = try XCTUnwrap(store.saved.first?.series.first)
        XCTAssertEqual(series.key, "account-1/Session")
        // The reading is a sample in the bucket of the moment the refresh happened.
        XCTAssertEqual(series.samples[afternoonBucket], 1)
        XCTAssertEqual(series.samples.reduce(0, +), 1)
        // It burned nothing: it had no predecessor to be differenced against.
        XCTAssertEqual(series.points.reduce(0, +), 0, accuracy: 0.0001)
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

    func testAReplacedRuntimeDoesNotRecordTheJumpAsConsumption() async throws {
        let store = RecordingRhythmStore(calendar: calendar)
        let recorder = recorder(store)
        let clock = TestClock(moment(14, 0))
        let provider = Provider(id: "account-1", kind: .claude)
        let runtime = StubRuntime(
            provider: provider,
            descriptors: [],
            snapshot: snapshot(fraction: 0.2, at: moment(14, 0))
        )
        let dataStore = WidgetDataStore.forTesting(
            [runtime],
            defaults: isolatedDefaults(),
            now: { clock.now },
            rhythm: recorder
        )

        await dataStore.refresh(providerID: provider.id, force: true)

        // The account is signed in again, so the new runtime measures a window that is nearly full.
        clock.set(moment(14, 5))
        let replacement = StubRuntime(
            provider: provider,
            descriptors: [],
            snapshot: snapshot(fraction: 0.9, at: moment(14, 5))
        )
        dataStore.replaceProvider(replacement, snapshot: snapshot(fraction: 0.9, at: moment(14, 5)))
        recorder.flush(at: clock.now)

        let series = try XCTUnwrap(store.saved.first?.series.first)
        XCTAssertEqual(series.key, "account-1/Session")
        // Both readings are samples.
        XCTAssertEqual(series.samples.reduce(0, +), 2)
        // The jump between the old window and the new one is not consumption: nothing burned.
        XCTAssertEqual(series.points.reduce(0, +), 0, accuracy: 0.0001)
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
        let series = try XCTUnwrap(store.saved.first?.series.first)
        XCTAssertEqual(series.key, "\(account.cardID)/Session")
        XCTAssertEqual(series.samples.reduce(0, +), 1)
    }
}
