import SwiftUI

/// The whole day as a strip of small bars, with the window the chart is showing marked on it.
/// The mark is the handle: dragging it moves the window through the day.
struct RhythmContextStrip: View {
    /// The whole day, one bar per hour.
    let dayBars: [RhythmBar]
    /// The window the chart is showing, as a share of the day from 0 to 1.
    let window: ClosedRange<Double>
    /// Called while the window is dragged.
    let onMove: (ClosedRange<Double>) -> Void

    private static let shape = RoundedRectangle(cornerRadius: 1, style: .continuous)

    /// The tallest bar, which sets the scale the others are drawn against.
    private var scale: Double {
        max(dayBars.map(\.points).max() ?? 0, 0.0001)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                dayBarsView(height: geo.size.height)
                windowView(width: geo.size.width, height: geo.size.height)
            }
            .contentShape(Rectangle())
            // The strip sits in the panel's scroll view, where the scroll view's pan competes
            // with the drag. The reorder grips of the same scroll view take the gesture first, so
            // the window moves instead of the panel scrolling.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // The mark moves to where the pointer is, not by how far the pointer
                        // travelled: the strip is small, and a relative drag would drift.
                        let width = max(geo.size.width, 1)
                        let span = window.upperBound - window.lowerBound
                        let centre = Double(value.location.x / width)
                        let lower = max(0, min(1 - span, centre - span / 2))
                        onMove(lower...(lower + span))
                    }
            )
        }
        .frame(height: 18)
    }

    private func dayBarsView(height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(dayBars) { bar in
                Group {
                    if bar.samples == 0 && bar.points <= 0 {
                        Color.clear
                    } else {
                        Self.shape.fill(Theme.severityColor(.normal).opacity(0.25))
                            .frame(height: max(1, height * CGFloat(bar.points / scale)))
                    }
                }
            }
        }
    }

    private func windowView(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.severityColor(.normal).opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.severityColor(.normal).opacity(0.5), lineWidth: 1.5)
            }
            // The mark spans the whole strip, so the window it shows is read at a glance.
            .frame(width: width * (window.upperBound - window.lowerBound), height: height)
            .offset(x: width * window.lowerBound)
    }
}
