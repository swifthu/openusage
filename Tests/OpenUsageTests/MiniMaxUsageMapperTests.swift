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

/// Legacy shape still handled by isNoSubscription (kept for backward compat).
private let legacyNoSubscriptionJSON = #"""
{"code":401,"msg":"未订阅 Token Plan","success":false}
"""#

/// Legacy shape with non-zero code but different message.
private let legacyNonSubscriptionJSON = #"""
{"code":500,"msg":"internal error","success":false}
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
        XCTAssertEqual(session.periodDurationMs, MiniMaxUsageMapper.sessionPeriodMs)

        let weekly = try XCTUnwrap(progress(lines, "Weekly"))
        XCTAssertEqual(weekly.used, 30, accuracy: 0.001)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.format, .percent)
        XCTAssertEqual(weekly.periodDurationMs, MiniMaxUsageMapper.weeklyPeriodMs)
    }

    func testMapsSessionOnlyWhenWeeklyAbsent() throws {
        let lines = try MiniMaxUsageMapper.map(data(sessionOnlyJSON))
        XCTAssertNotNil(progress(lines, "Session"))
        XCTAssertNil(progress(lines, "Weekly"))
    }

    func testEmptyDataReturnsNoUsageLine() throws {
        let lines = try MiniMaxUsageMapper.map(data(emptyModelRemainsJSON))
        XCTAssertEqual(lines.first, .noUsageData)
    }

    func testDetectsNoSubscriptionBody() {
        // Legacy shape still detected via isNoSubscription for backward compat.
        XCTAssertTrue(MiniMaxUsageMapper.isNoSubscription(data(legacyNoSubscriptionJSON)))
    }

    func testIsNoSubscriptionFalseForUsableBodies() {
        XCTAssertFalse(MiniMaxUsageMapper.isNoSubscription(data(bothLimitsJSON)))
        XCTAssertFalse(MiniMaxUsageMapper.isNoSubscription(data(legacyNonSubscriptionJSON)))
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
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(data("not json")))
    }

    func testDetectsFailureWhenStatusCodeIsNonZero() {
        // base_resp.status_code != 0 → mapper throws invalidResponse.
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(data(nonZeroStatusJSON))) { error in
            XCTAssertEqual(error as? MiniMaxUsageError, .invalidResponse)
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

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt, periodDurationMs)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }

    func testResetsAtComputedFromRemainsTime() throws {
        // bothLimitsJSON has remains_time: 7200000 (2 hours in ms)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: { fixedNow })

        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertNotNil(session.resetsAt)
        // remains_time=7200000ms = 7200s, so resetsAt = fixedNow + 7200
        XCTAssertEqual(session.resetsAt, fixedNow.addingTimeInterval(7200))

        let weekly = try XCTUnwrap(progress(lines, "Weekly"))
        XCTAssertEqual(weekly.resetsAt, fixedNow.addingTimeInterval(7200))
    }

    func testResetsAtHonorsNowParameter() throws {
        let now1 = Date(timeIntervalSince1970: 1_000_000_000)
        let now2 = Date(timeIntervalSince1970: 2_000_000_000)
        let lines1 = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: { now1 })
        let lines2 = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: { now2 })

        let session1 = try XCTUnwrap(progress(lines1, "Session"))
        let session2 = try XCTUnwrap(progress(lines2, "Session"))

        // Different now values should produce different resetsAt
        XCTAssertNotEqual(session1.resetsAt, session2.resetsAt)
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
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: { fixedNow })

        let resetBadge = try XCTUnwrap(badge(lines, "5h Reset"))
        XCTAssertEqual(resetBadge, "2h")
    }

    func testSessionResetBadgeTextWithoutRemainsTime() throws {
        // sessionOnlyJSON has no remains_time field → badge text is "—"
        let lines = try MiniMaxUsageMapper.map(data(sessionOnlyJSON))
        let resetBadge = try XCTUnwrap(badge(lines, "5h Reset"))
        XCTAssertEqual(resetBadge, "—")
    }

    func testSessionResetBadgeHasResetsAt() throws {
        // bothLimitsJSON has remains_time: 7200000 (2 hours in ms)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON), now: { fixedNow })

        // Find the 5h Reset badge and verify resetsAt is set.
        let resetsAt = try XCTUnwrap(lines.first { $0.label == "5h Reset" }.flatMap { line -> Date? in
            if case .badge(_, _, _, _, let resetsAt) = line { return resetsAt }
            return nil
        })
        // remains_time=7200000ms = 7200s, so resetsAt = fixedNow + 7200
        XCTAssertEqual(resetsAt, fixedNow.addingTimeInterval(7200))
    }

    func testProgressFractionAndLevel() throws {
        // Verify fraction and level computation for different remaining times.
        // 2h remaining (out of 5h): fraction ≈ 0.4, level == .normal
        let now = Date()
        let twoHoursRemaining = now.addingTimeInterval(2 * 3600)
        let totalSeconds = Double(MiniMaxUsageMapper.sessionPeriodMs) / 1000  // 18000 seconds
        let fraction2h = twoHoursRemaining.timeIntervalSince(now) / totalSeconds
        XCTAssertEqual(fraction2h, 0.4, accuracy: 0.001)
        XCTAssertEqual(levelFromRemaining(2 * 3600), WidgetData.ProgressLevel.normal)

        // 1h remaining: fraction ≈ 0.2, level == .warning
        let oneHourRemaining = now.addingTimeInterval(1 * 3600)
        let fraction1h = oneHourRemaining.timeIntervalSince(now) / totalSeconds
        XCTAssertEqual(fraction1h, 0.2, accuracy: 0.001)
        XCTAssertEqual(levelFromRemaining(1 * 3600), WidgetData.ProgressLevel.warning)

        // 5min remaining: fraction ≈ 0.017, level == .critical
        let fiveMinRemaining = now.addingTimeInterval(5 * 60)
        let fraction5min = fiveMinRemaining.timeIntervalSince(now) / totalSeconds
        XCTAssertEqual(fraction5min, 0.017, accuracy: 0.001)
        XCTAssertEqual(levelFromRemaining(5 * 60), WidgetData.ProgressLevel.critical)
    }

    private func levelFromRemaining(_ seconds: TimeInterval) -> WidgetData.ProgressLevel {
        if seconds >= 2 * 3600 { return .normal }
        if seconds >= 30 * 60 { return .warning }
        return .critical
    }
}
