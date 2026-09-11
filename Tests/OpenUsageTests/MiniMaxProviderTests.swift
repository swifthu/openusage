import XCTest
@testable import OpenUsage

private let bothLimitsJSON = #"""
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 88,
      "current_weekly_remaining_percent": 70,
      "current_interval_usage_count": 0,
      "current_weekly_usage_count": 0,
      "remains_time": 7200000
    }
  ],
  "base_resp": {
    "status_code": 0,
    "status_msg": "success"
  }
}
"""#

/// Real API shape with non-zero status_code (simulates auth/subscription failure).
private let nonZeroStatusJSON = #"""
{
  "model_remains": [],
  "base_resp": { "status_code": 401, "status_msg": "invalid token" }
}
"""#

private func jsonResponse(_ jsonString: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(jsonString.utf8))
}

@MainActor
final class MiniMaxProviderTests: XCTestCase {
    func testRefreshMapsSessionAndWeekly() async throws {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.url, MiniMaxUsageClient.remainsURL)
                XCTAssertEqual(request.headers["Authorization"], "Bearer minimax-test")
                return jsonResponse(bothLimitsJSON)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testSessionResetWidgetDescriptorExists() {
        let provider = MiniMaxProvider()
        let descriptors = provider.widgetDescriptors
        let sessionReset = descriptors.first(where: { $0.id == "minimax.sessionReset" })
        XCTAssertNotNil(sessionReset)
        XCTAssertEqual(sessionReset?.title, "5h Reset")
        XCTAssertEqual(sessionReset?.metricLabel, "5h Reset")
        // Badge widget (not percent) so it renders a plain string in the menu bar.
        XCTAssertEqual(sessionReset?.sample.kind, .count)
    }

    func testSessionResetWidgetHasSmallDisplaySize() {
        let provider = MiniMaxProvider()
        guard let resetDescriptor = provider.widgetDescriptors.first(where: { $0.id == "minimax.sessionReset" }) else {
            return XCTFail("expected minimax.sessionReset widget")
        }
        XCTAssertEqual(resetDescriptor.sample.displaySize, .small)
    }

    func testSessionResetWidgetHasBarPeriodMs() {
        let provider = MiniMaxProvider()
        guard let resetDescriptor = provider.widgetDescriptors.first(where: { $0.id == "minimax.sessionReset" }) else {
            return XCTFail("expected minimax.sessionReset widget")
        }
        XCTAssertEqual(resetDescriptor.barPeriodMs, MiniMaxUsageMapper.sessionPeriodMs)
    }

    func testRefreshIncludesSessionResetBadgeWithCountdown() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse(bothLimitsJSON)
            }),
            now: { fixedNow }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        guard case .badge(_, let text, _, _, _) = snapshot.line(label: "5h Reset") else {
            return XCTFail("Expected badge line for 5h Reset")
        }
        // bothLimitsJSON has remains_time=7200000ms = 7200s → "2h"
        XCTAssertEqual(text, "2h")
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse("{}")
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshClassifiesAuthFailure() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse("{}", status: 401)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshClassifiesServerFailure() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse("{}", status: 500)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testRefreshClassifiesRateLimit() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse("{}", status: 429)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .rateLimited)
    }

    func testRefreshOnTransportErrorReportsNetwork() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                throw MiniMaxUsageError.connectionFailed
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testRefreshWithoutSubscriptionReportsNotAvailable() async {
        // Real API shape: non-zero status_code triggers .invalidResponse from the mapper,
        // which maps to .decoding category.
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse(nonZeroStatusJSON)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
    }

    func testHasLocalCredentialsReflectsAuthStore() async {
        let keyAuth = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-env"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in jsonResponse("{}") })
        )
        let keyAuthHasCreds = await keyAuth.hasLocalCredentials()
        XCTAssertTrue(keyAuthHasCreds)

        let noAuth = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in jsonResponse("{}") })
        )
        let noAuthHasCreds = await noAuth.hasLocalCredentials()
        XCTAssertFalse(noAuthHasCreds)
    }

    func testProviderIdentityAndLinks() {
        let provider = MiniMaxProvider()
        XCTAssertEqual(provider.provider.id, "minimax")
        XCTAssertEqual(provider.provider.displayName, "MiniMax")
        XCTAssertTrue(provider.provider.links.contains { $0.label == "Dashboard" })
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: files, environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in jsonResponse("{}") })
        )

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "minimax-env")

        try provider.saveAPIKey("minimax-saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "minimax-saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    func testProviderCatalogIncludesMiniMax() {
        let catalog = ProviderCatalog.make()
        let ids = catalog.map(\.provider.id)
        XCTAssertTrue(ids.contains("minimax"))
        // Verify alphabetical position: minimax must come after "grok" and before "ollama".
        guard let minimaxIndex = ids.firstIndex(of: "minimax"),
              let grokIndex = ids.firstIndex(of: "grok"),
              let ollamaIndex = ids.firstIndex(of: "ollama") else {
            return XCTFail("expected catalog to contain minimax, grok, ollama")
        }
        XCTAssertGreaterThan(minimaxIndex, grokIndex)
        XCTAssertLessThan(minimaxIndex, ollamaIndex)
    }

    private func makeAuthStore(key: String) -> MiniMaxAuthStore {
        MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment(["MINIMAX_API_KEY": key]))
    }
}
