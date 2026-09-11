import Foundation

/// Optional override for the menu-bar strip's font size. When `nil`, the strip uses its default
/// (12pt bold for a single metric, 9pt semibold for multiple). Set to `.small` on a metric that
/// should appear visually subordinate (e.g. a reset countdown under a primary percentage).
enum MenuBarDisplaySize: String, Sendable, Equatable, Codable {
    /// Standard strip text size for the metric that carries the primary value (e.g. a percentage).
    case standard
    /// Visually subordinate text for secondary metrics (e.g. a reset countdown). Renders smaller.
    case small
}
