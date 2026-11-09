import SwiftUI

/// The rhythm tab: when each account's window fills up, and when the peak hours are.
struct RhythmView: View {
    @Environment(AppContainer.self) var container

    /// Which of the two views is showing.
    enum Mode: String, CaseIterable, Identifiable {
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

    @State var mode: Mode = .day
    @State private var day = Date()
    @State private var span: Span = .month
    @State var zoom: RhythmZoom
    @State var offset: TimeInterval
    @State private var isPickingDay = false
    @State var records: [RhythmDayRecord] = []
    /// The days that have a file at all. A day that has a file but no record is a day the store
    /// could not read, which is not the same as a day nothing was recorded on.
    @State private var recordedDays: Set<Date> = []
    /// Whether the history holds any day at all, which is what tells "nothing yet" apart from
    /// "not on that day".
    @State private var hasHistory = false
    /// What went wrong while reading the history, if anything.
    @State private var readError: String?

    /// The window the chart starts at.
    ///
    /// The tab starts at the whole day. A test starts it at the window it wants to look at: the
    /// zoom control cannot be driven from a test, and a window that holds no reading is a case
    /// worth pinning down.
    init(initialZoom: RhythmZoom = .day, initialOffset: TimeInterval = 0) {
        let dayLength = Calendar.current.dateInterval(of: .day, for: Date())?.duration
            ?? RhythmZoom.day.window
        _zoom = State(initialValue: initialZoom)
        _offset = State(initialValue: Self.clampedOffset(initialOffset, zoom: initialZoom, dayLength: dayLength))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            CapsuleSegments(options: Mode.allCases.map { ($0, $0.label) }, selection: $mode)
            chart
            summary
        }
        .task(id: refreshKey) {
            // The history grows while the tab is open, so it reloads on a timer as well as when
            // the day, the mode or the range changes.
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
    var selectedRecord: RhythmDayRecord? {
        records.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let readError {
                message("The rhythm history could not be read: \(readError)")
            } else if bars.isEmpty {
                message(emptyText)
            } else if hasNoReadings {
                message(mode == .day
                    ? "No readings were taken on this day."
                    : "No readings were taken in this range.")
            } else {
                // What the bars are counted in, so the chart says what it adds up, and which
                // window the dashed line follows.
                HStack(spacing: 8) {
                    Text(zoom.unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    windowPicker
                }
                if zoom != .day {
                    RhythmContextStrip(
                        dayBars: contextBars,
                        window: windowShare,
                        onMove: { share in move(to: share) }
                    )
                }
                RhythmChart(bars: bars, peak: RhythmAnalytics.peakBars(in: bars), zoom: zoom, levels: levelPoints)
                    .frame(height: 96)
                if windowHasNoReadings {
                    Text("No readings were taken in this window.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
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
                Text(axisLabels[step])
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
        VStack(alignment: .leading, spacing: 4) {
            // A write that failed leaves the chart empty with no explanation anywhere else, so the
            // failure is said out loud. The recorder keeps retrying, so the history is not lost.
            if let writeError {
                Text("Writing the rhythm history failed: \(writeError)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // A day the store could not read is left out of the average, and the average is
            // only the average of the days that are in it.
            if !unreadableDays.isEmpty, mode == .average, !bars.isEmpty {
                Text("\(unreadableDays.count) of the \(span.rawValue) days in this range could not be read.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // A read that failed leaves the summary out: the card says the history could not be
            // read, and a peak of the data that is still in memory would contradict that.
            if readError == nil, let peak = RhythmAnalytics.peakBars(in: bars), !bars.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(Theme.severityColor(.normal)).frame(width: 7, height: 7)
                    Text(summaryText(from: bars[peak.lowerBound].start))
                }
                .font(.system(size: 11))
            }
        }
    }

    /// What went wrong the last time the history could not be written, if anything.
    private var writeError: String? {
        container.rhythm.lastWriteError
    }

    /// What the empty chart says. "We do not know" is not the same as "nothing was used".
    private var emptyText: String {
        guard hasHistory else {
            // A recording that is switched off will not build up, so the empty state must not
            // promise that it will.
            guard container.rhythmSettings.isEnabled else {
                return "The rhythm recording is off. Turn it on in Settings to start recording."
            }
            return "Nothing recorded yet. The rhythm builds up from today."
        }
        // A day the store could not read is not a day nothing was recorded on.
        if !unreadableDays.isEmpty {
            return mode == .day
                ? "The history of this day could not be read. The file was left as it is, and nothing was recorded for the day."
                : "None of the days in this range could be read. Their files were left as they are."
        }
        return mode == .day ? "Nothing was recorded on this day." : "Nothing was recorded in this range."
    }

    /// The days of the range that have a file but no record: the store could not read them.
    ///
    /// The store skips such a day with a warning and returns the rest, so the days that are
    /// missing from the records are the ones it refused.
    private var unreadableDays: [Date] {
        let calendar = Calendar.current
        let range = daysToRead
        let first = calendar.startOfDay(for: range.lowerBound)
        let last = calendar.startOfDay(for: range.upperBound)
        let read = Set(records.map { calendar.startOfDay(for: $0.day) })
        return recordedDays
            .filter { $0 >= first && $0 <= last && !read.contains(calendar.startOfDay(for: $0)) }
            .sorted()
    }

    /// Whether the days on show hold no reading at all.
    ///
    /// The window on show does not matter: a window without readings is a window of a day that has
    /// them, and the chart stays on show so the reader can move back to the part that has them.
    /// Only a day that was never read is a day nothing was recorded on.
    private var hasNoReadings: Bool {
        switch mode {
        case .day:
            guard let record = selectedRecord else { return false }
            return !RhythmAnalytics.hasReadings(record)
        case .average:
            return !RhythmAnalytics.hasReadings(in: records)
        }
    }

    /// Whether the window on show holds no reading of its own.
    private var windowHasNoReadings: Bool {
        !bars.isEmpty && bars.allSatisfy { $0.samples == 0 }
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
        "\(mode.rawValue)-\(day.timeIntervalSince1970)-\(span.rawValue)"
    }

    /// The five labels of the axis.
    private var axisLabels: [String] {
        Self.axisLabels(zoom: zoom, start: bars.first?.start ?? Calendar.current.startOfDay(for: day))
    }

    /// The labels of the axis over a window: five of them, every sixth bar.
    ///
    /// A whole day is the window's own hours, numbered from zero. The window is a fixed
    /// twenty-four hours from the day's midnight, so its hours are the same on a day of
    /// twenty-three or twenty-five hours, and the axis does not mix a nominal end with clock
    /// times. A narrowed window is on the clock: it begins and ends at a time of the day.
    static func axisLabels(zoom: RhythmZoom, start: Date) -> [String] {
        if zoom == .day {
            return (0..<5).map { String($0 * 6) }
        }
        return (0..<5).map { step in
            start.addingTimeInterval(Double(step) * 6 * zoom.barDuration)
                .formatted(date: .omitted, time: .shortened)
        }
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
        offset = Self.clampedOffset(offset, zoom: zoom, dayLength: dayLength)
    }

    /// The offset the chart can show.
    ///
    /// The whole day starts at the day's midnight, so the offset goes back to zero there: on a day
    /// of twenty-five hours an offset of an hour would leave the chart starting at 01:00 while
    /// the axis still counts from zero. A window shorter than the day can only start so far into
    /// it, and it always starts on a bar boundary, so the bars stay aligned with the buckets.
    static func clampedOffset(_ offset: TimeInterval, zoom: RhythmZoom, dayLength: TimeInterval) -> TimeInterval {
        guard zoom != .day else { return 0 }
        let clamped = min(max(offset, 0), max(0, dayLength - zoom.window))
        return (clamped / zoom.barDuration).rounded(.down) * zoom.barDuration
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
        // The reading may have been overtaken while it was running. A detached read is
        // unstructured: it is not cancelled with the task that started it, so a reading that is
        // no longer the one the view wants must not be applied — the chart would show the days of
        // the previous range under the title of the current one, and a late failure would replace
        // a good chart with an error message. A view that went away applies nothing at all.
        guard !Task.isCancelled, days == daysToRead else { return }
        switch outcome {
        case .read(let loaded, let recorded):
            records = loaded
            recordedDays = Set(recorded)
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
