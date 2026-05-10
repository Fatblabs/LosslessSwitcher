import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController

    private let columns = [
        GridItem(.adaptive(minimum: 92), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sourceAndOutput
            manualRateSection
            settingsSection
            activitySection
            footer
        }
        .padding(22)
        .frame(
            minWidth: 760,
            maxWidth: .infinity,
            minHeight: 620,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.badge.plus")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("LosslessSwitcher")
                    .font(.title2.weight(.semibold))
                Text(controller.lastSwitchStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("Auto", isOn: $controller.isAutoSwitchEnabled)
                .toggleStyle(.switch)
        }
    }

    private var sourceAndOutput: some View {
        HStack(alignment: .top, spacing: 14) {
            GroupBox("Source") {
                VStack(alignment: .leading, spacing: 10) {
                    if let source = controller.currentSource {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.displayTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Text(source.displayArtist)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Label(
                            formatLabel(sampleRate: source.sampleRate, bitDepth: source.bitDepth),
                            systemImage: "music.note"
                        )
                        .font(.title3.weight(.semibold))

                        Text(source.formatSource)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !source.isSampleRateReliable, let note = source.sampleRateNote {
                            Label(note, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        if let bitRate = source.bitRate {
                            Text("\(bitRate) kbps • \(source.sourceDetail)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if !source.sourceDetail.isEmpty {
                            Text(source.sourceDetail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Label(controller.detectorStatus, systemImage: "music.note.list")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack {
                        Button("Match Now", action: controller.matchCurrentTrackNow)
                        .buttonStyle(.borderedProminent)

                        Button("Open Music", action: controller.openMusic)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 10) {
                    if let device = controller.defaultOutputDevice {
                        Text(device.name)
                            .font(.headline)
                            .lineLimit(1)

                        Label(
                            formatLabel(
                                sampleRate: device.currentSampleRate,
                                bitDepth: device.currentBitDepth
                            ),
                            systemImage: "speaker.wave.2"
                        )
                        .font(.title3.weight(.semibold))

                        Text("\(device.supportedSampleRates.count) reported sample-rate modes")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No output device", systemImage: "speaker.slash")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Bit Depth", selection: $controller.bitDepthPreference) {
                        ForEach(BitDepthPreference.allCases) { preference in
                            Text(preference.label).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var manualRateSection: some View {
        GroupBox("Manual Rate") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(controller.supportedRatesForDefaultDevice, id: \.self) { sampleRate in
                    Button(sampleRateLabel(sampleRate)) {
                        controller.setManualSampleRate(sampleRate)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var settingsSection: some View {
        GroupBox("Settings") {
            SettingsControlsView()
                .padding(.vertical, 4)
        }
    }

    private var activitySection: some View {
        GroupBox("Activity") {
            if controller.logEntries.isEmpty {
                Text("Ready")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.logEntries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.isError ? "exclamationmark.triangle" : "checkmark.circle")
                                    .foregroundStyle(entry.isError ? .orange : .green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(entry.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(entry.date, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 110, maxHeight: 190)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh Devices", action: controller.refreshDevices)
            Button("Request Music Access", action: controller.requestMusicAccess)

            Spacer()

            Text(controller.detectorStatus)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct SettingsControlsView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Toggle("Show Menu Bar Item", isOn: $controller.isMenuBarEnabled)
                Toggle("Menu Bar Only", isOn: $controller.isMenuBarOnlyModeEnabled)
            }

            GridRow {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { controller.isLaunchAtLoginEnabled },
                        set: { controller.setLaunchAtLoginEnabled($0) }
                    )
                )
                Text("\(controller.cachedTrackCount) remembered songs")
                    .foregroundStyle(.secondary)
            }

            GridRow {
                Button("Clear Song Memory", action: controller.clearFormatCache)
                .disabled(controller.cachedTrackCount == 0)

                Text("Cached song formats survive app restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Settings", systemImage: "gearshape")
                .font(.title3.weight(.semibold))

            SettingsControlsView()

            Divider()

            Button("Open Main Window") {
                MainWindowPresenter.showMainWindowSoon()
            }
        }
        .padding(20)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("LosslessSwitcher", systemImage: "waveform.path.badge.plus")
                    .font(.headline)
                Spacer()
                Toggle("Auto", isOn: $controller.isAutoSwitchEnabled)
                    .toggleStyle(.switch)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let source = controller.currentSource {
                    Text(source.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(source.displayArtist) • \(formatLabel(sampleRate: source.sampleRate, bitDepth: source.bitDepth))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !source.isSampleRateReliable {
                        Text("Waiting for CoreAudio decoder format")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(source.formatSource)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(controller.detectorStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let device = controller.defaultOutputDevice {
                Label(
                    "\(device.name) • \(formatLabel(sampleRate: device.currentSampleRate, bitDepth: device.currentBitDepth))",
                    systemImage: "speaker.wave.2"
                )
                .lineLimit(2)
            }

            Picker("Bit Depth", selection: $controller.bitDepthPreference) {
                ForEach(BitDepthPreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Match Now", action: controller.matchCurrentTrackNow)
                .buttonStyle(.borderedProminent)

                Button("Show LosslessSwitcher") {
                    MainWindowPresenter.showMainWindowSoon()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            SettingsControlsView()

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 390)
    }
}

#Preview {
    ContentView()
        .environmentObject(LosslessSwitcherController())
}
