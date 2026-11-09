import SwiftUI

/// The window the chart's dashed line follows: which 5-hour window it is, where its readings are
/// and how they are drawn.
///
/// The line follows one window at a time. Every account has its own 5-hour window, and the picker
/// chooses which of them the line is about; the choice is kept, so the chart shows the same
/// window the last time.
extension RhythmView {
    /// The 5-hour windows the history on show holds.
    var sessionWindows: [RhythmSessionWindow] {
        switch mode {
        case .day:
            return selectedRecord.map { RhythmAnalytics.sessionWindows(in: [$0]) } ?? []
        case .average:
            return RhythmAnalytics.sessionWindows(in: records)
        }
    }

    /// The window the dashed line follows: the one that was chosen, or the first one on offer.
    ///
    /// A window that is not in the history any more — an account that was removed — is not
    /// followed, and the first one on offer takes its place.
    var followedWindow: RhythmSessionWindow? {
        let windows = sessionWindows
        guard !windows.isEmpty else { return nil }
        if let key = container.rhythmSettings.trackedSessionKey,
           let match = windows.first(where: { $0.key == key }) {
            return match
        }
        return windows.first
    }

    /// The picker that chooses the window the dashed line follows.
    @ViewBuilder
    var windowPicker: some View {
        if !sessionWindows.isEmpty {
            Picker(selection: followedWindowBinding) {
                ForEach(sessionWindows) { window in
                    Text(window.name).tag(Optional(window.key))
                }
            } label: {
                Text("Window")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("The window the line follows")
        }
    }

    var followedWindowBinding: Binding<String?> {
        Binding(
            get: { followedWindow?.key },
            set: { container.rhythmSettings.trackedSessionKey = $0 }
        )
    }

    /// The remaining share of the followed window, over the window on show.
    var levelPoints: [RhythmLevelPoint] {
        guard let window = followedWindow else { return [] }
        switch mode {
        case .day:
            guard let record = selectedRecord else { return [] }
            return RhythmAnalytics.levelPoints(
                for: record, seriesKey: window.key, zoom: zoom, offset: offset
            )
        case .average:
            return RhythmAnalytics.averageLevelPoints(
                for: records, seriesKey: window.key, zoom: zoom, offset: offset
            )
        }
    }
}
