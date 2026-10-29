import Foundation

/// Builds metric lines from the MiniMax `/v1/token_plan/remains` payload.
///
/// Real API shape:
/// ```
/// {
///   "model_remains": [
///     { "model_name": "general", "current_interval_remaining_percent": 99,
///       "current_weekly_remaining_percent": 100, "current_interval_usage_count": 0,
///       "current_weekly_usage_count": 0, "remains_time": 7200000 },
///     { "model_name": "video", "current_interval_remaining_percent": 66,
///       "current_weekly_remaining_percent": 95 }
///   ],
///   "base_resp": { "status_code": 0, "status_msg": "success" }
/// }
/// ```
///
/// Usage = `100 - remaining_percent`. `remains_time` (milliseconds until the 5-hour window resets)
/// anchors the Session row's reset instant and the "5h Reset" countdown text.
///
/// Pure (no I/O), so it tests cleanly against sample payloads.
enum MiniMaxUsageMapper {
    /// Shown when the account has no Token Plan, or when the payload carries no reset time to count down.
    static let unknownResetText = "—"

    static let noSubscriptionMessage =
        "No active MiniMax Token Plan subscription. Subscribe at platform.minimaxi.com to see usage."

    /// Session + weekly meters from the quota payload.
    /// - Picks the `model_remains` entry with `model_name == "general"`; falls back to the first
    ///   entry if no "general" is present.
    /// - `current_interval_remaining_percent` → Session used = `100 - remaining`.
    /// - `current_weekly_remaining_percent` → Weekly used = `100 - remaining`.
    /// - An empty `model_remains` array means the provider reported no usage.
    /// - A failure payload (`base_resp.status_code != 0`, or the legacy `success: false`) throws.
    /// - `now` anchors the reset instant read from `remains_time`.
    static func map(_ body: Data, now: Date = Date()) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ProviderError.invalidResponse
        }

        if noSubscription(in: root) {
            throw ProviderError.unavailable(noSubscriptionMessage)
        }
        if let baseResp = root["base_resp"] as? [String: Any],
           let statusCode = ProviderParse.number(baseResp["status_code"]),
           statusCode != 0 {
            throw ProviderError.invalidResponse
        }

        guard let modelRemains = root["model_remains"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        guard !modelRemains.isEmpty else { return [] }

        // Prefer the "general" model; fall back to the first entry.
        let entry = modelRemains.first(where: { ($0["model_name"] as? String) == "general" })
            ?? modelRemains[0]

        let resetsAt: Date? = ProviderParse.number(entry["remains_time"])
            .map { now.addingTimeInterval($0 / 1000) }

        var lines: [MetricLine] = []

        if let remaining = ProviderParse.number(entry["current_interval_remaining_percent"]) {
            let used = ProviderParse.clampPercent(100 - remaining)
            lines.append(.percent("Session", used, resetsAt: resetsAt, periodMs: MetricPeriod.sessionMs))
            lines.append(.badge(label: "5h Reset", text: countdownText(resetsAt, now: now)))
        }

        if let remaining = ProviderParse.number(entry["current_weekly_remaining_percent"]) {
            let used = ProviderParse.clampPercent(100 - remaining)
            // The payload carries no weekly reset instant, so the weekly row carries none either.
            lines.append(.percent("Weekly", used, periodMs: MetricPeriod.weekMs))
        }

        return lines
    }

    /// The time left until the session window resets, as text.
    private static func countdownText(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return unknownResetText }
        return Formatters.compactDuration(resetsAt.timeIntervalSince(now)) ?? unknownResetText
    }

    /// A valid key on an account without a Token Plan: the API answers 200 with a failure payload
    /// instead of an empty quota.
    private static func noSubscription(in root: [String: Any]) -> Bool {
        if (root["success"] as? Bool) == false {
            if mentionsSubscription((root["msg"] as? String) ?? "") { return true }
        }
        if let baseResp = root["base_resp"] as? [String: Any],
           let statusCode = ProviderParse.number(baseResp["status_code"]),
           statusCode != 0 {
            if mentionsSubscription((baseResp["status_msg"] as? String) ?? "") { return true }
        }
        return false
    }

    private static func mentionsSubscription(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("token plan") || message.contains("subscription")
    }
}
