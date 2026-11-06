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
            )]
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
