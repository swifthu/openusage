import Foundation
import Observation

/// How large the menu bar strip is drawn, as a multiple of its default size. The menu bar has a
/// fixed height, so the range stays inside what fits: at the top the strip is about as tall as the
/// bar allows, at the bottom it is still legible.
@MainActor
@Observable
final class MenuBarSizeSetting {
    static let key = "menuBarScale"
    static let range: ClosedRange<Double> = 0.7...1.3
    static let defaultScale: Double = 1.0

    /// The size the strip is drawn at right now.
    private(set) var scale: Double

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.key)
        self.scale = stored > 0 ? Self.clamp(stored) : Self.defaultScale
    }

    /// Sets the size, clamped to the range the menu bar can show. A stored value outside the range
    /// (an older build, a hand-edited plist) is clamped on the way in and on the way out.
    func set(_ value: Double) {
        let clamped = Self.clamp(value)
        guard clamped != scale else { return }
        scale = clamped
        defaults.set(clamped, forKey: Self.key)
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
