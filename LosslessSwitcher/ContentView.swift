import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController

    private let rateColumns = [
        GridItem(.adaptive(minimum: 104), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .top, spacing: 14) {
                    nowPlayingPanel
                    outputPanel
                }

                manualRatesPanel

                HStack(alignment: .top, spacing: 14) {
                    preferencesPanel
                    activityPanel
                }

                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AppBackdrop())
        .frame(
            minWidth: 860,
            maxWidth: .infinity,
            minHeight: 680,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppGlyph(systemImage: "waveform.path.badge.plus", tint: .cyan)

            VStack(alignment: .leading, spacing: 4) {
                Text("LosslessSwitcher")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text(controller.lastSwitchStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 18)

            StatusPill(
                controller.isAutoSwitchEnabled ? "Auto Match" : "Manual",
                systemImage: controller.isAutoSwitchEnabled ? "bolt.fill" : "hand.raised",
                tint: controller.isAutoSwitchEnabled ? .green : .orange
            )

            Toggle("Auto", isOn: $controller.isAutoSwitchEnabled)
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
        }
        .padding(16)
        .panelBackground(tint: .cyan)
    }

    private var nowPlayingPanel: some View {
        PremiumPanel("Source", systemImage: "music.note", tint: .cyan) {
            if let source = controller.currentSource {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.displayTitle)
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(sourceLine(for: source))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    FormatReadout(
                        sampleRate: source.sampleRate,
                        bitDepth: source.bitDepth,
                        scale: .large
                    )

                    SourceProvenanceView(source: source)

                    HStack(spacing: 10) {
                        Button {
                            controller.matchCurrentTrackNow()
                        } label: {
                            Label("Match Now", systemImage: "target")
                        }
                        .buttonStyle(AppButtonStyle(prominent: true, tint: .cyan))

                        Button {
                            controller.openMusic()
                        } label: {
                            Label("Open Music", systemImage: "music.note.list")
                        }
                        .buttonStyle(AppButtonStyle(tint: .mint))
                    }
                }
            } else {
                EmptyStateView(
                    title: controller.detectorStatus,
                    detail: "Apple Music",
                    systemImage: "music.note.list",
                    tint: .cyan
                )

                HStack(spacing: 10) {
                    Button {
                        controller.matchCurrentTrackNow()
                    } label: {
                        Label("Match Now", systemImage: "target")
                    }
                    .buttonStyle(AppButtonStyle(prominent: true, tint: .cyan))

                    Button {
                        controller.openMusic()
                    } label: {
                        Label("Open Music", systemImage: "music.note.list")
                    }
                    .buttonStyle(AppButtonStyle(tint: .mint))
                }
            }
        }
    }

    private var outputPanel: some View {
        PremiumPanel("Output", systemImage: "speaker.wave.2", tint: .green) {
            if let device = controller.defaultOutputDevice {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(device.name)
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Spacer()

                        StatusPill(
                            outputStatusTitle(for: device),
                            systemImage: outputStatusIcon(for: device),
                            tint: outputStatusTint(for: device)
                        )
                    }

                    FormatReadout(
                        sampleRate: device.currentSampleRate,
                        bitDepth: device.currentBitDepth,
                        scale: .medium
                    )

                    Divider().opacity(0.45)

                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Bit Depth", selection: $controller.bitDepthPreference) {
                            ForEach(BitDepthPreference.allCases) { preference in
                                Text(preference.label).tag(preference)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 8) {
                            Label(
                                "\(device.supportedSampleRates.count) modes",
                                systemImage: "slider.horizontal.3"
                            )
                            Label(
                                highResolutionLabel(for: device),
                                systemImage: "sparkles"
                            )
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            } else {
                EmptyStateView(
                    title: "No output device",
                    detail: controller.detectorStatus,
                    systemImage: "speaker.slash",
                    tint: .orange
                )
            }
        }
    }

    private var manualRatesPanel: some View {
        PremiumPanel("Manual Rates", systemImage: "dial.low", tint: .indigo) {
            if controller.supportedRatesForDefaultDevice.isEmpty {
                EmptyStateView(
                    title: "No reported rate modes",
                    detail: "Default output",
                    systemImage: "slider.horizontal.below.square.filled.and.square",
                    tint: .indigo
                )
            } else {
                LazyVGrid(columns: rateColumns, alignment: .leading, spacing: 10) {
                    ForEach(controller.supportedRatesForDefaultDevice, id: \.self) { sampleRate in
                        Button {
                            controller.setManualSampleRate(sampleRate)
                        } label: {
                            RateChip(
                                title: sampleRateLabel(sampleRate),
                                isActive: isCurrentOutputRate(sampleRate)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var preferencesPanel: some View {
        PremiumPanel("Preferences", systemImage: "switch.2", tint: .mint) {
            SettingsControlsView()
        }
    }

    private var activityPanel: some View {
        PremiumPanel("Activity", systemImage: "waveform.path.ecg", tint: .orange) {
            if controller.logEntries.isEmpty {
                EmptyStateView(
                    title: "Ready",
                    detail: controller.detectorStatus,
                    systemImage: "checkmark.circle",
                    tint: .green
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(controller.logEntries) { entry in
                            ActivityRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 130, maxHeight: 210)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                controller.refreshDevices()
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(AppButtonStyle(tint: .green))

            Button {
                controller.requestMusicAccess()
            } label: {
                Label("Request Music Access", systemImage: "lock.open")
            }
            .buttonStyle(AppButtonStyle(tint: .orange))

            Spacer(minLength: 18)

            Text(controller.detectorStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func sourceLine(for source: DetectedAudioSource) -> String {
        [source.displayArtist, source.album]
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    private func isCurrentOutputRate(_ sampleRate: Double) -> Bool {
        guard let device = controller.defaultOutputDevice else {
            return false
        }

        return abs(device.currentSampleRate - sampleRate) < 1
    }

    private func outputStatusTitle(for device: AudioDevice) -> String {
        guard let source = controller.currentSource else {
            return "Standby"
        }

        return abs(device.currentSampleRate - source.sampleRate) < 1 ? "Matched" : "Different"
    }

    private func outputStatusIcon(for device: AudioDevice) -> String {
        outputStatusTitle(for: device) == "Matched" ? "checkmark" : "arrow.triangle.2.circlepath"
    }

    private func outputStatusTint(for device: AudioDevice) -> Color {
        outputStatusTitle(for: device) == "Matched" ? .green : .orange
    }

    private func highResolutionLabel(for device: AudioDevice) -> String {
        device.supportedSampleRates.contains { $0.maximum >= 96_000 } ? "Hi-res ready" : "Standard range"
    }
}

struct SettingsControlsView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            SettingToggleRow(
                title: "Menu Bar Item",
                systemImage: "menubar.rectangle",
                tint: .cyan,
                isOn: $controller.isMenuBarEnabled
            )

            SettingToggleRow(
                title: "Menu Bar Only",
                systemImage: "dock.rectangle",
                tint: .indigo,
                isOn: $controller.isMenuBarOnlyModeEnabled
            )

            SettingToggleRow(
                title: "Launch at Login",
                systemImage: "power",
                tint: .green,
                isOn: Binding(
                    get: { controller.isLaunchAtLoginEnabled },
                    set: { controller.setLaunchAtLoginEnabled($0) }
                )
            )

            CacheControlRow(count: controller.cachedTrackCount) {
                controller.clearFormatCache()
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AppGlyph(systemImage: "gearshape", tint: .mint, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("\(controller.cachedTrackCount) remembered songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            SettingsControlsView()

            Divider().opacity(0.5)

            Button {
                MainWindowPresenter.showMainWindowSoon()
            } label: {
                Label("Open Main Window", systemImage: "macwindow")
            }
            .buttonStyle(AppButtonStyle(prominent: true, tint: .mint))
        }
        .padding(20)
        .frame(width: 460)
        .background(AppBackdrop())
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var controller: LosslessSwitcherController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppGlyph(systemImage: "waveform.path.badge.plus", tint: .cyan, size: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("LosslessSwitcher")
                        .font(.headline)
                    Text(controller.lastSwitchStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("Auto", isOn: $controller.isAutoSwitchEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider().opacity(0.5)

            CompactSourceView(source: controller.currentSource, status: controller.detectorStatus)

            if let device = controller.defaultOutputDevice {
                CompactOutputView(device: device)
            }

            Picker("Bit Depth", selection: $controller.bitDepthPreference) {
                ForEach(BitDepthPreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button {
                    controller.matchCurrentTrackNow()
                } label: {
                    Label("Match", systemImage: "target")
                }
                .buttonStyle(AppButtonStyle(prominent: true, tint: .cyan))

                Button {
                    MainWindowPresenter.showMainWindowSoon()
                } label: {
                    Label("Show", systemImage: "macwindow")
                }
                .buttonStyle(AppButtonStyle(tint: .mint))
            }

            Divider().opacity(0.5)

            SettingsControlsView(compact: true)

            Divider().opacity(0.5)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(AppButtonStyle(tint: .red))
        }
        .padding(14)
        .frame(width: 390)
        .background(AppBackdrop())
    }
}

private struct AppBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.cyan.opacity(0.12),
                    Color.green.opacity(0.07),
                    Color.indigo.opacity(0.08),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.28)
        }
        .ignoresSafeArea()
    }
}

private struct PremiumPanel<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let content: Content

    init(
        _ title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panelBackground(tint: tint)
    }
}

private struct AppGlyph: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.24),
                            tint.opacity(0.08),
                            Color.primary.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct FormatReadout: View {
    enum Scale {
        case large
        case medium
    }

    let sampleRate: Double
    let bitDepth: Int?
    let scale: Scale

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(sampleRateLabel(sampleRate))
                .font(.system(size: scale == .large ? 38 : 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(bitDepthText)
                .font(.system(size: scale == .large ? 15 : 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private var bitDepthText: String {
        guard let bitDepth else {
            return "bit depth preserved"
        }

        return "\(bitDepth)-bit"
    }
}

private struct SourceProvenanceView: View {
    let source: DetectedAudioSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusPill(
                source.isSampleRateReliable ? source.formatSource : "Resolving format",
                systemImage: source.isSampleRateReliable ? "checkmark.seal" : "timer",
                tint: source.isSampleRateReliable ? .green : .orange
            )

            if !source.isSampleRateReliable, let note = source.sampleRateNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let bitRate = source.bitRate {
                Text("\(bitRate) kbps / \(source.sourceDetail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !source.sourceDetail.isEmpty {
                Text(source.sourceDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.24), lineWidth: 1)
            }
    }
}

private struct RateChip: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .green : .secondary)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.green.opacity(0.14) : Color.primary.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.green.opacity(0.35) : Color.primary.opacity(0.08))
        }
    }
}

private struct SettingToggleRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CacheControlRow: View {
    let count: Int
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Song Memory")
                    .font(.subheadline.weight(.medium))
                Text("\(count) remembered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: clear) {
                Label("Clear", systemImage: "trash")
            }
            .disabled(count == 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ActivityRow: View {
    let entry: SwitchLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(entry.isError ? .orange : .green)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            Text(entry.date, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyStateView: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            AppGlyph(systemImage: systemImage, tint: tint, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactSourceView: View {
    let source: DetectedAudioSource?
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let source {
                Text(source.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text("\(source.displayArtist) / \(formatLabel(sampleRate: source.sampleRate, bitDepth: source.bitDepth))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                StatusPill(
                    source.isSampleRateReliable ? source.formatSource : "Resolving",
                    systemImage: source.isSampleRateReliable ? "checkmark.seal" : "timer",
                    tint: source.isSampleRateReliable ? .green : .orange
                )
            } else {
                Text(status)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct CompactOutputView: View {
    let device: AudioDevice

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(formatLabel(sampleRate: device.currentSampleRate, bitDepth: device.currentBitDepth))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AppButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : tint)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(0.11))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(prominent ? 0.15 : 0.25), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private extension View {
    func panelBackground(tint: Color) -> some View {
        background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.35),
                            Color.primary.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: tint.opacity(0.08), radius: 18, x: 0, y: 8)
    }
}

#Preview {
    ContentView()
        .environmentObject(LosslessSwitcherController())
}
