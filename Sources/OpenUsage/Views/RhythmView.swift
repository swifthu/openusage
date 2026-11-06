import SwiftUI

/// The rhythm tab: when each account's window fills up, and when the peak hours are.
struct RhythmView: View {
    @Environment(AppContainer.self) private var container

    /// Which of the two views is showing.
    private enum Mode: String, CaseIterable, Identifiable {
        case day
        case average
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: "This Day"
            case .average: "Average"
            }
        }
    }

    /// How many days the average covers.
    private enum Span: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue) Days" }
    }

    /// What reading the history gave.
    private enum ReadOutcome: Sendable {
        case read(records: [RhythmDayRecord], recordedDays: [Date])
        case failed(String)
    }

    @State private var mode: Mode = .day
    @State private var day = Date()
    @State private var span: Span = .month
    @State private var zoom: RhythmZoom = .day
    @State private var offset: TimeInterval = 0
    @State private var isPickingDay = false
    @State private var records: [RhythmDayRecord] = []
    /// Whether the history holds any day at all, which is what tells "nothing yet" apart from
    /// "not on that day".
    @State private var hasHistory = false
    /// What went wrong while reading the history, if anything.
    @State private var readError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            CapsuleSegments(options: Mode.allCases.map { ($0, $0.label) }, selection: $mode)
            chart
            summary
        }
        .task(id: refreshKey) {
            // The history grows while the tab is open, so it reloads on a timer as well as when
            // the day, the mode or the zoom changes.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: day) { _, _ in
            // The day on show decides how long it is, so a window that fitted yesterday's length
            // can stick out past the end of today's.
            clampOffset()
        }
    }

    /// The charts' data.
    private var bars: [RhythmBar] {
        switch mode {
        case .day:
            guard let record = selectedRecord else { return [] }
            return RhythmAnalytics.bars(for: record, zoom: zoom, offset: offset)
        case .average:
            return RhythmAnalytics.averageBars(for: records, zoom: zoom, offset: offset)
        }
    }

    /// The day on show, when it was recorded.
    private var selectedRecord: RhythmDayRecord? {
        records.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let readError {
                message("The rhythm history could not be read: \(readError)")
            } else if bars.isEmpty {
                message(emptyText)
            } else if averageHasNoReadings {
                message("No readings were taken in this range.")
            } else {
                if zoom != .day {
                    RhythmContextStrip(
                        dayBars: contextBars,
                        window: windowShare,
                        onMove: { share in move(to: share) }
                    )
                }
                RhythmChart(bars: bars, peak: RhythmAnalytics.peakBars(in: bars), zoom: zoom)
                    .frame(height: 96)
                axis
                zoomSlider
            }
        }
        .padding(10)
        .cardSurface()
    }

    /// A line of text where the chart would be.
    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    private var header: some View {
        HStack {
            switch mode {
            case .day:
                Button {
                    moveDay(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.severityColor(.normal))

                // A long press opens the calendar: stepping a day at a time is too slow to reach
                // last Tuesday.
                Text(dayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .onLongPressGesture(minimumDuration: 0.4) { isPickingDay = true }

                Button {
                    moveDay(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.severityColor(.normal))
            case .average:
                Text("Last \(span.rawValue) Days")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                CapsuleSegments(options: Span.allCases.map { ($0, $0.label) }, selection: $span)
                    .frame(width: 190)
            }
            Spacer(minLength: 0)
        }
        .popover(isPresented: $isPickingDay) {
            DatePicker("Pick a Day", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
        }
    }

    private var axis: some View {
        HStack {
            ForEach(0..<5) { step in
                Text(axisLabel(at: step))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                if step < 4 { Spacer() }
            }
        }
    }

    private var zoomSlider: some View {
        HStack(spacing: 8) {
            Text("Zoom")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(zoom.rawValue) },
                    set: { zoom = RhythmZoom(rawValue: Int($0.rounded())) ?? .day; clampOffset() }
                ),
                in: 0...Double(RhythmZoom.allCases.count - 1),
                step: 1
            )
            Text(zoom.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var summary: some View {
        Group {
            if let peak = RhythmAnalytics.peakBars(in: bars), !bars.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(Theme.severityColor(.normal)).frame(width: 7, height: 7)
                    Text(summaryText(from: bars[peak.lowerBound].start))
                }
                .font(.system(size: 11))
            }
        }
    }

    /// What the empty chart says. "We do not know" is not the same as "nothing was used".
    private var emptyText: String {
        guard hasHistory else { return "Nothing recorded yet. The rhythm builds up from today." }
        return mode == .day ? "Nothing was recorded on this day." : "Nothing was recorded in this range."
    }

    /// Whether the average is of days that hold no reading at all. The chart would be an empty
    /// grid then, with nothing on it to say why.
    private var averageHasNoReadings: Bool {
        mode == .average && !bars.isEmpty && bars.allSatisfy { $0.samples == 0 }
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The whole day at hourly resolution, for the strip above the chart.
    private var contextBars: [RhythmBar] {
        switch mode {
        case .day:
            guard let record = selectedRecord else { return [] }
            return RhythmAnalytics.bars(for: record, zoom: .day, offset: 0)
        case .average:
            return RhythmAnalytics.averageBars(for: records, zoom: .day, offset: 0)
        }
    }

    /// The length of the day on show, which is not always 24 hours.
    private var dayLength: TimeInterval {
        Calendar.current.dateInterval(of: .day, for: day)?.duration ?? RhythmZoom.day.window
    }

    /// The window the chart is showing, as a share of the day.
    private var windowShare: ClosedRange<Double> {
        let lower = offset / dayLength
        let span = zoom.window / dayLength
        return lower...(lower + span)
    }

    private var refreshKey: String {
        "\(mode.rawValue)-\(day.timeIntervalSince1970)-\(span.rawValue)-\(zoom.rawValue)"
    }

    private func axisLabel(at step: Int) -> String {
        // Five labels over 24 bars: every sixth bar.
        let start = bars.first?.start ?? Calendar.current.startOfDay(for: day)
        guard step < 4 else {
            // The last label is the end of the window. A whole day ends at the next midnight,
            // which would print "00:00" and read exactly like the first label, so it is marked
            // "24:00" instead.
            guard zoom != .day else { return "24:00" }
            return start.addingTimeInterval(zoom.window).formatted(date: .omitted, time: .shortened)
        }
        return start.addingTimeInterval(Double(step) * 6 * zoom.barDuration).formatted(date: .omitted, time: .shortened)
    }

    private func summaryText(from start: Date) -> String {
        let end = start.addingTimeInterval(Double(peakBarCount) * zoom.barDuration)
        let window = "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        return mode == .day ? "This day's peak is \(window)" : "Your peak usually runs \(window)"
    }

    private var peakBarCount: Int {
        guard let peak = RhythmAnalytics.peakBars(in: bars) else { return 0 }
        return peak.count
    }

    private func moveDay(by days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day) else { return }
        day = next
        offset = 0
    }

    private func move(to share: ClosedRange<Double>) {
        offset = share.lowerBound * dayLength
        clampOffset()
    }

    private func clampOffset() {
        offset = min(max(offset, 0), max(0, dayLength - zoom.window))
        // The window always starts on a bar boundary, so the bars stay aligned with the buckets.
        offset = (offset / zoom.barDuration).rounded(.down) * zoom.barDuration
    }

    /// The days the chart needs: the selected day, or the days the chosen range covers.
    private var daysToRead: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // The store compares days, so the range covers whole days: a range that starts in the
        // afternoon would otherwise leave that day's record out.
        switch mode {
        case .day:
            let selected = calendar.startOfDay(for: day)
            return selected...selected
        case .average:
            let start = calendar.date(byAdding: .day, value: -(span.rawValue - 1), to: today) ?? today
            return start...today
        }
    }

    /// Reads the history off the main thread: the file store decodes up to ninety day files, and
    /// the tab reloads every thirty seconds, so the reading does not belong on the main thread.
    private func load() async {
        let store = container.rhythm.store
        let days = daysToRead
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let records = try store.load(days: days)
                let recorded = try store.recordedDays()
                return ReadOutcome.read(records: records, recordedDays: recorded)
            } catch {
                return ReadOutcome.failed(error.localizedDescription)
            }
        }.value
        switch outcome {
        case .read(let loaded, let recorded):
            records = loaded
            hasHistory = !recorded.isEmpty
            readError = nil
        case .failed(let message):
            // A history that cannot be read is not a history that was never written: the user has
            // to be told, and the log has to say what happened.
            AppLog.error(.rhythm, "could not read the rhythm history: \(message)")
            readError = message
        }
    }
}
