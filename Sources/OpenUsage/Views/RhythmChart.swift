import SwiftUI

/// The rhythm chart: one bar per slice of the visible window. The peak is drawn in the app's
/// blue and the rest in a lighter shade of it. A slice nothing was read from stays empty, so
/// "we do not know" never looks like "nothing was used".
///
/// The remaining share of the followed 5-hour window is drawn over the bars as a dashed line. The
/// two are counted in different things — a bar is a rate, the line is a share — so the chart has
/// an axis for each: the bars are read on the left, the line on the right.
struct RhythmChart: View {
    let bars: [RhythmBar]
    /// The bars that make up the peak.
    let peak: ClosedRange<Int>?
    /// The zoom the chart is at, which decides what each bar's unit of time is.
    let zoom: RhythmZoom
    /// The remaining share of the followed window at each of its readings. Empty when no window is
    /// followed, and then the chart has no right-hand axis either.
    var levels: [RhythmLevelPoint] = []

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)

    /// The tallest bar, which sets the scale the others are drawn against.
    private var scale: Double {
        max(bars.map(\.points).max() ?? 0, 0.0001)
    }

    var body: some View {
        HStack(spacing: 4) {
            leftAxis
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(bars) { bar in
                            column(bar, maxHeight: geo.size.height)
                        }
                    }
                    levelLine(in: geo.size)
                }
            }
            if !levels.isEmpty {
                rightAxis
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The scale of the bars: the zero at the bottom and the tallest bar at the top.
    private var leftAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(topLabel)
            Spacer(minLength: 0)
            Text("0")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .frame(width: 20, alignment: .trailing)
    }

    /// The scale of the line: the share that was left, from all of it to none of it.
    private var rightAxis: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("100%")
            Spacer(minLength: 0)
            Text("50%")
                .frame(maxHeight: .infinity, alignment: .center)
            Spacer(minLength: 0)
            Text("0%")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .frame(width: 28, alignment: .leading)
    }

    /// The tallest bar's own value, so the left axis says what the bars are drawn against.
    private var topLabel: String {
        let tallest = bars.map(\.points).max() ?? 0
        guard tallest > 0 else { return "0" }
        // A tenth is enough to say what the bars are drawn against, and a whole number is left
        // without its decimals.
        let rounded = (tallest * 10).rounded() / 10
        return rounded.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func column(_ bar: RhythmBar, maxHeight: CGFloat) -> some View {
        Group {
            if bar.samples == 0 && bar.points <= 0 {
                // Nothing was read and nothing was burned: we do not know.
                Color.clear
            } else if bar.points <= 0 {
                // Read, but nothing was used: a baseline, not an empty column.
                Rectangle()
                    .fill(Theme.severityColor(.normal).opacity(0.3))
                    .frame(height: 1)
            } else {
                // A bucket can hold consumption without holding a reading of its own: the burn
                // between two readings is spread over the buckets it covered.
                Self.shape
                    .fill(fill(bar))
                    .frame(height: max(2, maxHeight * CGFloat(bar.points / scale)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// The remaining share of the followed window, drawn as a dashed line over the bars.
    ///
    /// The line joins the readings in the order they came, so a window that resets shows as a
    /// line that climbs back up: the share that was left before the reset and the share after it
    /// are two different runs of the same window.
    private func levelLine(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            guard !levels.isEmpty else { return }
            let points = levels.map { point in
                CGPoint(
                    x: point.position * canvasSize.width,
                    y: (1 - point.remaining) * canvasSize.height
                )
            }
            if points.count == 1 {
                // One reading is a dot, not a line.
                context.fill(
                    Path(ellipseIn: CGRect(x: points[0].x - 1.5, y: points[0].y - 1.5, width: 3, height: 3)),
                    with: .color(Theme.severityColor(.normal))
                )
                return
            }
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(Theme.severityColor(.normal)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3])
            )
        }
        .allowsHitTesting(false)
    }

    private func fill(_ bar: RhythmBar) -> Color {
        let blue = Theme.severityColor(.normal)
        guard let peak, peak.contains(bar.index) else { return blue.opacity(0.35) }
        return blue
    }

    private var accessibilityText: String {
        guard let peak else { return "Usage rhythm, nothing to show" }
        let first = bars[peak.lowerBound].start
        let last = bars[peak.upperBound].start.addingTimeInterval(zoom.barDuration)
        let peakText = "Usage rhythm. The peak runs from \(first.formatted(date: .omitted, time: .shortened)) to \(last.formatted(date: .omitted, time: .shortened))."
        guard !levels.isEmpty else { return peakText }
        return peakText + " The dashed line is the share the followed window still had left."
    }
}
