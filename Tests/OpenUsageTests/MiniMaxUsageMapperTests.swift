import XCTest
@testable import OpenUsage

// MARK: - Fixtures

/// Real API shape: general model with both interval and weekly remaining percentages.
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
    },
    {
      "model_name": "video",
      "current_interval_remaining_percent": 66,
      "current_weekly_remaining_percent": 95
    }
  ],
  "base_resp": {
    "status_code": 0,
    "status_msg": "success"
  }
}
"""#

/// Real API shape: general model with only interval (no weekly).
private let sessionOnlyJSON = #"""
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 88
    }
  ],
  "base_resp": {
    "status_code": 0,
    "status_msg": "success"
  }
}
"""#

/// Real API shape: empty model_remains array.
private let emptyModelRemainsJSON = #"""
{
  "model_remains": [],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
"""#

/// Real API shape: non-zero status_code → failure signal.
private let nonZeroStatusJSON = #"""
{
  "model_remains": [
    { "model_name": "general", "current_interval_remaining_percent": 88 }
  ],
  "base_resp": { "status_code": 401, "status_msg": "invalid token" }
}
"""#

/// The account has no Token Plan: the API answers 200 with a failure payload.
private let noSubscriptionJSON = #"""
{"code":401,"msg":"未订阅 Token Plan","success":false}
"""#

private func data(_ json: String) -> Data { Data(json.utf8) }

// MARK: - Tests

final class MiniMaxUsageMapperTests: XCTestCase {
    func testMapsSessionAndWeeklyPercentages() throws {
        // remaining=88 → used=12; remaining=70 → used=30
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON))

        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertEqual(session.used, 12, accuracy: 0.001)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        XCTAssertEqual(session.periodDurationMs, MetricPeriod.sessionMs)

        let weekly = try XCTUnwrap(progress(lines, "Weekly"))
        XCTAssertEqual(weekly.used, 30, accuracy: 0.001)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.format, .percent)
        XCTAssertEqual(weekly.periodDurationMs, MetricPeriod.weekMs)
    }

    func testMapsSessionOnlyWhenWeeklyAbsent() throws {
        let lines = try MiniMaxUsageMapper.map(data(sessionOnlyJSON))
        XCTAssertNotNil(progress(lines, "Session"))
        XCTAssertNil(progress(lines, "Weekly"))
    }

    func testEmptyModelRemainsReportsNoLines() throws {
        let lines = try MiniMaxUsageMapper.map(data(emptyModelRemainsJSON))
        XCTAssertTrue(lines.isEmpty)
    }

    func testClampsAboveRangePercentage() throws {
        // remaining=-50 → used=150, clamped to 100
        let body = data(#"""
        {
          "model_remains": [
            { "model_name": "general", "current_interval_remaining_percent": -50 }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """#)
        let lines = try MiniMaxUsageMapper.map(body)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Session")).used, 100, accuracy: 0.001)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(data("not json"))) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testDetectsFailureWhenStatusCodeIsNonZero() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(data(nonZeroStatusJSON))) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testNoSubscriptionIsReportedAsUnavailable() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(data(noSubscriptionJSON))) { error in
            XCTAssertEqual(error as? ProviderError, .unavailable(MiniMaxUsageMapper.noSubscriptionMessage))
        }
    }

    func testIsFailureFalseForUsableBodies() {
        // status_code == 0 should NOT throw.
        XCTAssertNoThrow(try MiniMaxUsageMapper.map(data(bothLimitsJSON)))
        XCTAssertNoThrow(try MiniMaxUsageMapper.map(data(sessionOnlyJSON)))
    }

    func testPicksGeneralModelWhenPresent() throws {
        let body = data(#"""
        {
          "model_remains": [
            { "model_name": "video", "current_interval_remaining_percent": 34,
              "current_weekly_remaining_percent": 5 },
            { "model_name": "general", "current_interval_remaining_percent": 88,
              "current_weekly_remaining_percent": 70 }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """#)
        let lines = try MiniMaxUsageMapper.map(body)
        // general: remaining=88 → used=12; remaining=70 → used=30
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Session")).used, 12, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).used, 30, accuracy: 0.001)
    }

    func testPicksFirstModelWhenNoGeneral() throws {
        let body = data(#"""
        {
          "model_remains": [
            { "model_name": "video", "current_interval_remaining_percent": 34,
              "current_weekly_remaining_percent": 5 }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """#)
        let lines = try MiniMaxUsageMapper.map(body)
        // video: remaining=34 → used=66; remaining=5 → used=95
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Session")).used, 66, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).used, 95, accuracy: 0.001)
    }

    func testResetsAtComputedFromRemainsTime() throws {
        // bothLimitsJSON has remains_time: 7200000 (2 hours in ms)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: fixedNow)

        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertNotNil(session.resetsAt)
        // remains_time=7200000ms = 7200s, so resetsAt = fixedNow + 7200
        XCTAssertEqual(session.resetsAt, fixedNow.addingTimeInterval(7200))

        // The payload reports no weekly reset instant, so the weekly row carries none.
        let weekly = try XCTUnwrap(progress(lines, "Weekly"))
        XCTAssertNil(weekly.resetsAt)
    }

    func testResetsAtHonorsNowParameter() throws {
        let now1 = Date(timeIntervalSince1970: 1_000_000_000)
        let now2 = Date(timeIntervalSince1970: 2_000_000_000)
        let lines1 = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: now1)
        let lines2 = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: now2)

        let session1 = try XCTUnwrap(progress(lines1, "Session"))
        let session2 = try XCTUnwrap(progress(lines2, "Session"))

        XCTAssertEqual(session1.resetsAt, now1.addingTimeInterval(7200))
        XCTAssertEqual(session2.resetsAt, now2.addingTimeInterval(7200))
    }

    func testResetsAtNilWhenNoRemainsTime() throws {
        // sessionOnlyJSON has no remains_time field
        let lines = try MiniMaxUsageMapper.map(data(sessionOnlyJSON))
        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertNil(session.resetsAt)
    }

    func testSessionResetBadgeWithCountdown() throws {
        // bothLimitsJSON has remains_time: 7200000 (2 hours in ms)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: fixedNow)

        XCTAssertEqual(try XCTUnwrap(badge(lines, "5h Reset")), "2h")
    }

    func testSessionResetBadgeTextWithoutRemainsTime() throws {
        // sessionOnlyJSON has no remains_time field → badge text is the unknown marker
        let lines = try MiniMaxUsageMapper.map(data(sessionOnlyJSON))
        XCTAssertEqual(try XCTUnwrap(badge(lines, "5h Reset")), MiniMaxUsageMapper.unknownResetText)
    }

    func testSessionResetBadgeCarriesTheWindowItCountsDownIn() throws {
        // The badge carries the reset instant and the window length, so the menu bar can draw the
        // countdown as a bar draining towards the reset.
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: fixedNow)

        guard case .badge(_, _, let resetsAt, let periodDurationMs) = lines.first(where: { $0.label == "5h Reset" }) else {
            return XCTFail("expected a 5h Reset badge")
        }
        XCTAssertEqual(resetsAt, fixedNow.addingTimeInterval(2 * 60 * 60))
        XCTAssertEqual(periodDurationMs, MetricPeriod.sessionMs)
    }

    func testSessionResetBadgeWithoutRemainsTimeHasNoWindow() throws {
        let lines = try MiniMaxUsageMapper.map(data(sessionOnlyJSON))

        guard case .badge(_, _, let resetsAt, let periodDurationMs) = lines.first(where: { $0.label == "5h Reset" }) else {
            return XCTFail("expected a 5h Reset badge")
        }
        XCTAssertNil(resetsAt)
        XCTAssertNil(periodDurationMs)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt, periodDurationMs)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }
}
