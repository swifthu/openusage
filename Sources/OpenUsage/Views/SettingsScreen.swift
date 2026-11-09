import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsScreen: View {
    var openURL: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(UpdaterController.self) private var updater
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(RefreshSetting.key) private var refreshInterval = RefreshSetting.maxInterval
    @AppStorage(DashboardTab.defaultKey) private var defaultTab = DashboardTab.priority
    @AppStorage(PaceMilestone.critical.settingKey) private var criticalAlert = false
    @AppStorage(PaceMilestone.warning.settingKey) private var warningAlert = false
    @AppStorage(PaceMilestone.closeToRunningOut.settingKey) private var closeToRunningOut = false
    @AppStorage(PaceMilestone.useItOrLoseIt.settingKey) private var useItOrLoseIt = false
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.info
    @State private var launchAtLogin = LaunchAtLoginSetting()
    @State private var commandLineTool = CommandLineToolInstaller()
    @State private var notificationsDenied = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// Whether there is any rhythm history to delete. It is state, not a computed property, so
    /// the button can go back to being disabled after the history is gone.
    @State private var hasRhythmHistory = false
    /// What to tell the user when the history could not be deleted.
    @State private var rhythmErrorMessage: String?
    /// Whether the user is asked to confirm the deletion of the history.
    @State private var isConfirmingRhythmDeletion = false

    /// How far a grouped `Form` already sets its cards in from every edge.
    private static let formRowInset: CGFloat = 20

    var body: some View {
        Form {
            switch popover.settingsTab {
            case .general: generalTab
            case .display: displayTab
            case .alerts: alertsTab
            case .advanced: advancedTab
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .contentMargins(.horizontal, PanelMetrics.margin - Self.formRowInset, for: .scrollContent)
        .contentMargins(.top, DashboardContentView.barGap - Self.formRowInset, for: .scrollContent)
        .contentMargins(.bottom, PanelMetrics.margin - Self.formRowInset, for: .scrollContent)
        .scrollPosition($scrollPosition)
        .onChange(of: popover.settingsTab) { scrollPosition.scrollTo(edge: .top) }
        .onChange(of: popover.screen, initial: true) { _, screen in
            if screen == .settings {
                scrollPosition.scrollTo(edge: .top)
                launchAtLogin.refreshStatus()
                commandLineTool.refreshStatus()
                if criticalAlert || warningAlert || closeToRunningOut || useItOrLoseIt { checkNotificationPermission() }
            }
        }
    }

    @ViewBuilder
    private var generalTab: some View {
        Section {
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.update(to: $0) }
            ))
            picker("Default Tab", selection: $defaultTab, options: DashboardTab.allCases.map { ($0, $0.label) })
            LabeledContent("Global Shortcut") {
                KeyboardShortcuts.Recorder(for: .togglePopover)
                    .disabled(popover.screen != .settings)
            }
            refreshIntervalControl
        } footer: {
            if let errorMessage = launchAtLogin.errorMessage {
                SettingsNote(errorMessage)
            }
        }
        .onChange(of: defaultTab) { _, newValue in popover.dashboardTab = newValue }
        updatesSection
    }

    @ViewBuilder
    private var updatesSection: some View {
        @Bindable var updater = updater
        Section("Updates") {
            Toggle("Check Automatically", isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isActive)
            Toggle("Beta Updates", isOn: $updater.betaChannelEnabled)
                .disabled(!updater.isActive)
            HStack {
                Spacer(minLength: 0)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    @ViewBuilder
    private var displayTab: some View {
        @Bindable var dataStore = dataStore
        @Bindable var rhythmSettings = container.rhythmSettings
        Section {
            PriorityIconsPreview()
            picker("Max Items In Menu Bar", selection: $dataStore.menuBarLimit, options: MenuBarLimit.allCases.map { ($0, $0.label) })
            Toggle(isOn: $dataStore.menuBarAlwaysShows) {
                titled("Always Show In Menu Bar", info: "Show icons in the menu bar even if not requiring your attention yet")
            }
            .disabled(dataStore.menuBarLimit == .iconOnly)
            menuBarSizeControl
        } header: {
            Text("Priority")
        }
        Section {
            levelPicker("Warning", info: "When a limit turns into a priority", severity: .warning,
                        selection: $dataStore.priorityLimits.warning, options: PriorityLimits.warningOptions)
            levelPicker("Critical", info: "When a limit turns critically low", severity: .critical,
                        selection: $dataStore.priorityLimits.critical, options: PriorityLimits.criticalOptions)
            Toggle(isOn: $dataStore.showsBurningFast) {
                limitLabel("Burning Fast", info: "Will run out before it resets") {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.severityColor(.warning))
                }
            }
            Toggle(isOn: $dataStore.showsUseItOrLoseIt) {
                limitLabel("Use It or Lose It", info: PaceMilestone.useItOrLoseIt.settingSubtitle) {
                    Image(systemName: "hourglass.tophalf.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.severityColor(.normal))
                }
            }
        }
        Section("Appearance") {
            picker("Theme", selection: $appearance, options: AppearanceSetting.allCases.map { ($0, $0.label) })
                .onChange(of: appearance) { AppearanceSetting.applyCurrent() }
            picker("Time Format", selection: $timeFormat, options: TimeFormatSetting.allCases.map { ($0, $0.label) })
        }
        Section {
            picker("Show Usage As", selection: $dataStore.meterStyle, options: WidgetDisplayMode.allCases.map { ($0, $0.label) })
            picker("Reset Times", selection: $dataStore.resetDisplayMode, options: ResetDisplayMode.allCases.map { ($0, $0.label) })
            Toggle(isOn: $dataStore.showsPaceMarks) {
                titled("Pace Marks", info: "Where usage would be at an even pace")
            }
            Toggle(isOn: $rhythmSettings.isEnabled) {
                titled("Record Usage Rhythm", info: "Keeps how fast your limits fill up, on this Mac")
            }
            Toggle(isOn: $rhythmSettings.tracksSessionWindows) {
                titled("Track 5-Hour Windows", info: "Keeps how much of each 5-hour window is left, so the rhythm chart can draw it")
            }
            Button("Delete Rhythm History") {
                isConfirmingRhythmDeletion = true
            }
            .disabled(!hasRhythmHistory)
            .confirmationDialog(
                "Delete Rhythm History?",
                isPresented: $isConfirmingRhythmDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete Rhythm History", role: .destructive) { deleteRhythmHistory() }
            } message: {
                Text("Every recorded day is deleted from this Mac. The recording stays on, and today's file is written again on the next refresh.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Usage")
        } footer: {
            if let rhythmErrorMessage {
                SettingsNote(rhythmErrorMessage)
            }
        }
        .task { refreshRhythmHistoryState() }
    }

    /// The refresh cadence, adjustable from 30 seconds to 5 minutes. The value lives in
    /// UserDefaults and is read by `RefreshSetting.interval`; the refresh loop re-reads it while it
    /// waits, so a change takes effect within seconds rather than at the end of the running cycle.
    private var refreshIntervalControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Refresh Interval")
                Spacer()
                Text(Self.refreshIntervalLabel(refreshInterval))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: $refreshInterval,
                in: RefreshSetting.minInterval...RefreshSetting.maxInterval,
                step: 15
            )
        }
    }

    private static func refreshIntervalLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }

    /// How large the menu bar strip is drawn, from 70% to 130% of its default. The strip redraws at
    /// the new size as soon as the slider moves.
    private var menuBarSizeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Menu Bar Size")
                Spacer()
                Text("\(Int((container.menuBarSize.scale * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { container.menuBarSize.scale },
                    set: { container.menuBarSize.set($0) }
                ),
                in: MenuBarSizeSetting.range,
                step: 0.05
            )
        }
    }

    private var alertsTab: some View {
        Section {
            notificationToggle(.critical, isOn: $criticalAlert)
            notificationToggle(.warning, isOn: $warningAlert)
            notificationToggle(.closeToRunningOut, isOn: $closeToRunningOut)
            notificationToggle(.useItOrLoseIt, isOn: $useItOrLoseIt)
        } header: {
            Text("Notifications")
        } footer: {
            if notificationsDenied {
                notificationSettingsButton
            }
        }
    }

    var notificationSettingsButton: some View {
        Button {
            openURL(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier!)")!)
            (NSApp.keyWindow as? MenuBarPanel)?.onDismiss?()
        } label: {
            Text("Notifications are off for OpenUsage in \(Text("System Settings").foregroundColor(.accentColor)).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.notice)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var advancedTab: some View {
        @Bindable var hideFromScreenShare = container.hideFromScreenShare
        #if OPENUSAGE_DEVELOPMENT
        DevelopmentDataSettings()
        #endif
        Section {
            Toggle(isOn: $hideFromScreenShare.isEnabled) {
                titled("Privacy Mode", info: "Hide usage and account names from screenshots and recordings")
            }
            Toggle(isOn: Binding(
                get: { container.telemetry.isEnabled },
                set: { container.telemetry.setEnabled($0) }
            )) {
                titled("Help Make OpenUsage Better", info: "Share additional anonymous usage stats that tell the team where to improve.")
            }
        } header: {
            Text("Privacy")
        }
        Section {
            LabeledContent {
                switch commandLineTool.status {
                case .installed:
                    Button("Uninstall") { commandLineTool.uninstall() }
                case .notInstalled, .linkedToAnotherCopy:
                    Button("Install…") { commandLineTool.install() }
                case .conflict:
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            } label: {
                titled("Terminal Helper", info: "Adds a global openusage command that prints the usage the app last fetched.")
            }
        } header: {
            Text("Command Line")
        } footer: {
            if commandLineTool.status == .conflict {
                SettingsNote("\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.")
            } else if let errorMessage = commandLineTool.errorMessage {
                SettingsNote(errorMessage)
            } else if case .linkedToAnotherCopy = commandLineTool.status {
                SettingsNote("\(commandLineTool.destinationPath) points at another copy of OpenUsage. Install points it at this one.")
            }
        }
        Section {
            Picker(selection: $logLevel) {
                ForEach(LogLevelSetting.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                titled("Log Level", info: "How much detail OpenUsage writes to the macOS log. Choose Debug while you reproduce a problem.")
            }
        } header: {
            Text("Debug")
        }
    }

    private func picker<Value: Hashable>(_ label: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        Picker(label, selection: selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func levelPicker(
        _ title: String, info: String, severity: WidgetData.MeterSeverity, selection: Binding<Int>, options: [Int]
    ) -> some View {
        Picker(selection: selection) {
            ForEach(options, id: \.self) { Text("\($0)% left").tag($0) }
        } label: {
            limitLabel(title, info: info) {
                Circle().fill(Theme.severityColor(severity)).frame(width: 8, height: 8)
            }
        }
    }

    /// A Priority limit row's label: its mark, then its title with what it does behind an info icon.
    private func limitLabel(_ title: String, info: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 8) {
            mark().frame(width: 8)
            titled(title, info: info)
        }
    }

    /// A row's title followed by an info icon that shows what the row does on hover.
    private func titled(_ title: String, info: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .hoverTooltip(info)
        }
    }

    private func notificationToggle(_ milestone: PaceMilestone, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            titled(milestone.notificationTitle, info: milestone.settingSubtitle)
        }
        .onChange(of: isOn.wrappedValue) { _, enabled in
            if enabled { checkNotificationPermission() }
        }
    }

    private func checkNotificationPermission() {
        Task { notificationsDenied = await !AppNotifications.shared.requestAuthorization() }
    }

    /// Whether there is anything to delete. The history is read from the store, not counted from
    /// the settings, so the button is only enabled when there is a file to remove.
    private func refreshRhythmHistoryState() {
        do {
            hasRhythmHistory = !(try container.rhythm.store.recordedDays().isEmpty)
        } catch {
            // A history that cannot be read is not an empty one: say so instead of offering a
            // button that would fail the same way.
            hasRhythmHistory = false
            AppLog.warn(.rhythm, "the rhythm history could not be read: \(error.localizedDescription)")
            rhythmErrorMessage = "The rhythm history could not be read: \(error.localizedDescription)"
        }
    }

    private func deleteRhythmHistory() {
        do {
            // The recorder writes the day it is on again on the next refresh, so the history is
            // deleted through the recorder, which lets go of what it holds as well.
            try container.rhythm.deleteHistory()
            AppLog.notice(.rhythm, "the rhythm history was deleted")
            rhythmErrorMessage = nil
            refreshRhythmHistoryState()
        } catch {
            // Say what happened rather than what was meant: the files are still there, so the
            // button stays as it is. The message of the failed deletion is kept: a state refresh
            // that failed as well must not hide it.
            AppLog.warn(.rhythm, "the rhythm history could not be deleted: \(error.localizedDescription)")
            rhythmErrorMessage = "The rhythm history could not be deleted: \(error.localizedDescription)"
            hasRhythmHistory = true
        }
    }
}

/// Sample icons at the number the setting picks, so every choice looks different whatever is running
/// out right now. Shrunk to sit in a row however many it holds.
struct PriorityIconsPreview: View {
    @Environment(WidgetDataStore.self) private var dataStore

    private static let height: CGFloat = 30
    private static let largestScale: CGFloat = 0.85
    private static let samples: [(kind: ProviderKind, badge: String?, label: String, value: String)] = [
        (.claude, "P", "Weekly", "38%"), (.claude, "A1", "Session", "26%"), (.codex, nil, "Weekly", "31%"),
        (.cursor, nil, "Extra", "$310"), (.antigravity, nil, "Gemini", "12%"), (.grok, nil, "Weekly", "9%"),
        (.copilot, nil, "Credits", "7%"),
    ]

    static func sample(limit: MenuBarLimit) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        let shown = samples.prefix(limit.count).enumerated().map { index, sample in
            MenuBarContent.Item(
                id: "sample.\(index)",
                provider: Provider(id: "sample.\(index)", kind: sample.kind, badge: sample.badge),
                label: sample.label,
                shortLabel: sample.label,
                value: sample.value
            )
        }
        return MenuBarContent(items: shown, overflow: samples.count - shown.count)
    }

    static func fittedSize(of strip: NSSize, in width: CGFloat) -> NSSize {
        let scale = min(largestScale, width / strip.width)
        return NSSize(width: strip.width * scale, height: strip.height * scale)
    }

    var body: some View {
        let content = Self.sample(limit: dataStore.menuBarLimit)
        let strip = MenuBarStripRenderer.image(for: content) ?? MenuBarStripRenderer.appIcon()
        GeometryReader { proxy in
            let size = Self.fittedSize(of: strip.size, in: proxy.size.width)
            Image(nsImage: strip)
                .renderingMode(.template)
                .resizable()
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .accessibilityLabel("Menu Bar Preview")
    }
}

private struct SettingsNote: View {
    let text: LocalizedStringKey

    init(_ text: String) {
        self.text = LocalizedStringKey(text)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.notice)
            .fixedSize(horizontal: false, vertical: true)
    }
}
