import Foundation
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

/// The account has no Token Plan: the API answers 200 with a failure payload.
private let noSubscriptionJSON = #"""
{"code":401,"msg":"未订阅 Token Plan","success":false}
"""#

private func jsonResponse(_ jsonString: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(jsonString.utf8))
}

@MainActor
final class MiniMaxProviderTests: XCTestCase {
    func testRefreshMapsSessionAndWeekly() async throws {
        let runtime = makeRuntime(http: RoutingHTTPClient { request in
            XCTAssertEqual(request.url, MiniMaxUsageClient.remainsURL)
            XCTAssertEqual(request.headers["Authorization"], "Bearer minimax-test")
            return jsonResponse(bothLimitsJSON)
        })

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(snapshot.displayName, "MiniMax")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testDescriptorsCoverSessionWeeklyAndReset() {
        let runtime = makeRuntime(http: RoutingHTTPClient { _ in jsonResponse(bothLimitsJSON) })
        let descriptors = runtime.widgetDescriptors

        XCTAssertEqual(descriptors.map(\.metricLabel), ["Session", "Weekly", "5h Reset"])
        XCTAssertEqual(descriptors.map(\.id), [
            "\(runtime.account.cardID).session",
            "\(runtime.account.cardID).weekly",
            "\(runtime.account.cardID).sessionReset"
        ])
        // The reset row is a badge, so it renders as plain text rather than a meter.
        XCTAssertEqual(descriptors.last?.sample.kind, .count)
        XCTAssertEqual(descriptors.last?.title, "5h Reset")
    }

    func testSessionIsPinnedToTheMenuBar() {
        let runtime = makeRuntime(http: RoutingHTTPClient { _ in jsonResponse(bothLimitsJSON) })
        let session = runtime.widgetDescriptors.first { $0.key == "session" }

        XCTAssertEqual(session?.isPinnedByDefault, true)
    }

    func testRefreshIncludesSessionResetBadgeWithCountdown() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeRuntime(
            http: RoutingHTTPClient { _ in jsonResponse(bothLimitsJSON) },
            now: { fixedNow }
        )

        let snapshot = try await runtime.refresh().get()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "5h Reset") else {
            return XCTFail("Expected badge line for 5h Reset")
        }
        // bothLimitsJSON has remains_time=7200000ms = 7200s → "2h"
        XCTAssertEqual(text, "2h")
    }

    func testRejectedKeyReportsAnExpiredSignIn() async throws {
        let runtime = makeRuntime(http: RoutingHTTPClient { _ in jsonResponse("{}", status: 401) })

        do {
            _ = try await runtime.refreshMiniMax(.apiKey("minimax-test"))
            XCTFail("Expected the rejected key to throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .signInExpired(.minimax))
        }
    }

    func testMissingCredentialReportsAnExpiredSignIn() async {
        let account = Account(kind: .minimax, label: "MiniMax")
        let runtime = AccountProviderRuntime(
            account: account,
            vault: InMemoryCredentialVault(),
            http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a credential")
                return jsonResponse("{}")
            }
        )

        let result = await runtime.refresh()

        switch result {
        case .success:
            XCTFail("Expected the refresh to fail without a credential")
        case .failure(let failure):
            XCTAssertEqual(failure.kind, .refused)
        }
    }

    func testAccountWithoutSubscriptionReportsUnavailable() async throws {
        let runtime = makeRuntime(http: RoutingHTTPClient { _ in jsonResponse(noSubscriptionJSON) })

        do {
            _ = try await runtime.refreshMiniMax(.apiKey("minimax-test"))
            XCTFail("Expected the missing subscription to throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unavailable(MiniMaxUsageMapper.noSubscriptionMessage))
        }
    }

    func testLoginForMiniMaxAsksForAnAPIKey() {
        let login = ProviderLoginCatalog.login(for: .minimax)

        XCTAssertTrue(login is APIKeyLogin)
    }

    func testTheProviderMarkIsBundled() {
        // A missing mark is a precondition failure, so the icon has to be in the resource bundle.
        let image = ProviderMarks.image(for: ProviderKind.minimax.rawValue, side: 16, inset: 0.04)

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    private func makeRuntime(
        http: any HTTPClient,
        now: @escaping () -> Date = Date.init
    ) -> AccountProviderRuntime {
        let account = Account(kind: .minimax, label: "MiniMax")
        let vault = InMemoryCredentialVault()
        try? vault.save(.apiKey("minimax-test"), for: account.id)
        return AccountProviderRuntime(account: account, vault: vault, http: http, now: now)
    }
}
