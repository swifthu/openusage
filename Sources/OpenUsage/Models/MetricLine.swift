import Foundation

enum ProgressFormat: Hashable, Sendable, Codable {
    case percent
    case dollars
    case currency(code: String)
    case count(suffix: String)

    var metricKind: MetricKind {
        switch self {
        case .percent:
            return .percent
        case .dollars, .currency:
            return .dollars
        case .count:
            return .count
        }
    }

    /// Whether the metric counts money. The share of a money budget is the rate at which money is
    /// spent, which this fork does not chart.
    var isMoney: Bool {
        switch self {
        case .dollars, .currency:
            return true
        case .percent, .count:
            return false
        }
    }

    var currencyCode: String? {
        guard case .currency(let code) = self else { return nil }
        return code
    }
}

enum MetricLine: Hashable, Sendable, Codable {
    case values(label: String, values: [MetricValue], expiriesAt: [Date] = [])
    case progress(
        label: String,
        used: Double,
        limit: Double,
        format: ProgressFormat,
        resetsAt: Date? = nil,
        periodDurationMs: Int? = nil
    )
    case badge(
        label: String,
        text: String,
        /// The instant the countdown ends, for a badge that counts down to a window reset.
        resetsAt: Date? = nil,
        /// The length of that window in milliseconds, so the countdown can be drawn as a bar.
        periodDurationMs: Int? = nil
    )

    var label: String {
        switch self {
        case .progress(let label, _, _, _, _, _),
             .values(let label, _, _),
             .badge(let label, _, _, _):
            return label
        }
    }
}
