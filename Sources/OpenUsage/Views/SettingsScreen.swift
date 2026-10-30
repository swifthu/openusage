import SwiftUI

struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(UpdaterController.self) private var updater
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(RefreshSetting.key) private var refreshInterval = RefreshSetting.maxInterval
    @AppStorage(PaceMilestone.underTenPercent.settingKey) private var underTenPercent = false
    @AppStorage(PaceMilestone.healthyToClose.settingKey) private var healthyToClose = false
    @AppStorage(PaceMilestone.closeToRunningOut.settingKey) private var closeToRunningOut = false
    @State private var launchAtLogin = LaunchAtLoginSetting()
    @State private var commandLineTool = CommandLineToolInstaller()
    @State private var notificationsDenied = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        PopoverScrollView {
            Form {
                Section {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.update(to: $0) }
                    ))
                    LabeledContent("Global Shortcut") {
                        ShortcutRecorderField(name: .togglePopover, isVisible: popover.screen == .settings)
                    }
                    refreshIntervalControl
                    menuBarSizeControl
                } header: {
                    Text("General")
                } footer: {
                    if let errorMessage = launchAtLogin.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.notice)
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearanceSetting.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: appearance) { AppearanceSetting.applyCurrent() }
                    Picker("Time Format", selection: $timeFormat) {
                        ForEach(TimeFormatSetting.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                usageDisplaySection
                notificationsSection
                privacySection
                commandLineSection
                updatesSection
            }
            .inlineGroupedForm()
        }
        .scrollPosition($scrollPosition)
        .onChange(of: popover.screen) { _, screen in
            if screen == .settings {
                scrollPosition.scrollTo(edge: .top)
                launchAtLogin.refreshStatus()
                commandLineTool.refreshStatus()
                if underTenPercent || healthyToClose || closeToRunningOut { checkNotificationPermission() }
            }
        }
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

    private var usageDisplaySection: some View {
        @Bindable var dataStore = dataStore
        return Section("Usage Display") {
            Picker("Show Usage As", selection: $dataStore.meterStyle) {
                ForEach(WidgetDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Reset Times", selection: $dataStore.resetDisplayMode) {
                ForEach(ResetDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            notificationToggle("Under 10% Remaining", isOn: $underTenPercent)
            notificationToggle("Healthy Pace Changes", isOn: $healthyToClose)
            notificationToggle("Near-Limit Pace Changes", isOn: $closeToRunningOut)
        } header: {
            Text("Notifications")
        } footer: {
            if notificationsDenied {
                Text("Notifications are off for OpenUsage in [System Settings](x-apple.systempreferences:com.apple.Notifications-Settings.extension).")
                    .font(.footnote)
                    .foregroundStyle(Theme.notice)
            }
        }
    }

    private var privacySection: some View {
        @Bindable var hideFromScreenShare = container.hideFromScreenShare
        return Section {
            Toggle("Hide From Screen Share", isOn: $hideFromScreenShare.isEnabled)
            Toggle("Help Make OpenUsage Better", isOn: Binding(
                get: { container.telemetry.isEnabled },
                set: { container.telemetry.setEnabled($0) }
            ))
        } header: {
            Text("Privacy")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("While your screen is shared or recorded, the menu bar shows the app icon instead of your usage.")
                Text("Share additional anonymous usage stats that tell the team where to improve.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var commandLineSection: some View {
        Section {
            LabeledContent("Terminal Helper") {
                switch commandLineTool.status {
                case .installed:
                    Button("Uninstall") { commandLineTool.uninstall() }
                case .notInstalled, .linkedToAnotherCopy:
                    Button("Install…") { commandLineTool.install() }
                case .conflict:
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Command Line")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Adds a global `openusage` command that prints the usage the app last fetched.")
                    .foregroundStyle(.secondary)
                if commandLineTool.status == .conflict {
                    Text("\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.")
                        .foregroundStyle(Theme.notice)
                } else if let errorMessage = commandLineTool.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(Theme.notice)
                } else if case .linkedToAnotherCopy = commandLineTool.status {
                    Text("\(commandLineTool.destinationPath) points at another copy of OpenUsage. Install points it at this one.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        @Bindable var updater = updater
        if updater.isActive {
            Section("Updates") {
                Toggle("Check Automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Beta Updates", isOn: $updater.betaChannelEnabled)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private func notificationToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .onChange(of: isOn.wrappedValue) { _, enabled in
                if enabled { checkNotificationPermission() }
            }
    }

    private func checkNotificationPermission() {
        Task { notificationsDenied = await !AppNotifications.shared.requestAuthorization().value }
    }
}
