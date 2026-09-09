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
/// Usage = `100 - remaining_percent`. The `remains_time` field (ms until reset) is not mapped
/// to `resetsAt` because it is a duration, not an absolute epoch — it does not fit `.progress`
/// semantics. `base_resp.status_code != 0` throws `.invalidResponse`.
///
/// Pure (no I/O), so it tests cleanly against sample payloads.
enum MiniMaxUsageMapper {
    /// 5-hour rolling session window in milliseconds (MiniMax's documented 5-hour window).
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    /// 7-day rolling weekly window in milliseconds.
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    /// True when a 2xx body signals the "valid key, but no Token Plan subscription" condition.
    /// MiniMax returns `{"success":false,"code":…,"msg":"…未订阅 Token Plan"}` with no `data`.
    /// Kept for backward compatibility; the new API uses `base_resp.status_code != 0` in `map()`.
    static func isNoSubscription(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        let msg = ((root["msg"] as? String) ?? "").lowercased()
        return msg.contains("token plan") || msg.contains("subscription")
    }

    /// Session + weekly meters from the quota payload.
    /// - Picks the `model_remains` entry with `model_name == "general"`; falls back to the first
    ///   entry if no "general" is present.
    /// - `current_interval_remaining_percent` → Session used = `100 - remaining`.
    /// - `current_weekly_remaining_percent` → Weekly used = `100 - remaining`.
    /// - An empty `model_remains` array returns `.noUsageData`.
    /// - `base_resp.status_code != 0` throws `.invalidResponse`.
    /// - `now` is used to compute `resetsAt` from `remains_time` (ms until reset).
    static func map(_ body: Data, now: @escaping () -> Date = Date.init) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw MiniMaxUsageError.invalidResponse
        }

        if let baseResp = root["base_resp"] as? [String: Any],
           let statusCode = ProviderParse.number(baseResp["status_code"]),
           statusCode != 0 {
            throw MiniMaxUsageError.invalidResponse
        }

        guard let modelRemains = root["model_remains"] as? [[String: Any]] else {
            throw MiniMaxUsageError.invalidResponse
        }

        guard !modelRemains.isEmpty else { return [.noUsageData] }

        // Prefer "general" model; fall back to first entry.
        let entry = modelRemains.first(where: { ($0["model_name"] as? String) == "general" })
            ?? modelRemains[0]

        // Compute resetsAt from remains_time (ms) if present.
        let resetsAt: Date? = {
            guard let ms = ProviderParse.number(entry["remains_time"]) else { return nil }
            return now().addingTimeInterval(ms / 1000)
        }()

        var lines: [MetricLine] = []

        if let remaining = ProviderParse.number(entry["current_interval_remaining_percent"]) {
            let used = ProviderParse.clampPercent(100 - remaining)
            lines.append(.progress(
                label: "Session",
                used: used,
                limit: 100,
                format: .percent,
                resetsAt: resetsAt,
                periodDurationMs: sessionPeriodMs
            ))

            // sessionReset shows the countdown text in the menu bar.
            if let resetsAt {
                let remaining = max(0, resetsAt.timeIntervalSince(now()))
                let text = Formatters.compactDuration(remaining) ?? "—"
                lines.append(.badge(label: "5h Reset", text: text))
            } else {
                lines.append(.badge(label: "5h Reset", text: "—"))
            }
        }

        if let remaining = ProviderParse.number(entry["current_weekly_remaining_percent"]) {
            let used = ProviderParse.clampPercent(100 - remaining)
            lines.append(.progress(
                label: "Weekly",
                used: used,
                limit: 100,
                format: .percent,
                resetsAt: resetsAt,
                periodDurationMs: weeklyPeriodMs
            ))
        }

        guard !lines.isEmpty else { return [.noUsageData] }
        return lines
    }
}

enum MiniMaxUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The key is valid but the account has no active Token Plan subscription.
    case noSubscription

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .noSubscription:
            return "No active MiniMax Token Plan subscription. Subscribe at platform.minimaxi.com to see usage."
        }
    }
}