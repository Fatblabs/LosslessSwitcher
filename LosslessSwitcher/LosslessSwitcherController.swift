import AudioToolbox
import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class LosslessSwitcherController: NSObject, ObservableObject {
    @Published var isAutoSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoSwitchEnabled, forKey: Defaults.autoSwitchEnabled)
            if isAutoSwitchEnabled {
                matchCurrentTrackNow()
            }
        }
    }

    @Published var bitDepthPreference: BitDepthPreference {
        didSet {
            UserDefaults.standard.set(bitDepthPreference.rawValue, forKey: Defaults.bitDepthPreference)
            if isAutoSwitchEnabled {
                lastAppliedSignature = nil
                matchCurrentTrackNow()
            }
        }
    }

    @Published var isMenuBarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMenuBarEnabled, forKey: Defaults.menuBarEnabled)
            if !isMenuBarEnabled, isMenuBarOnlyModeEnabled {
                isMenuBarOnlyModeEnabled = false
            }
        }
    }

    @Published var isMenuBarOnlyModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMenuBarOnlyModeEnabled, forKey: Defaults.menuBarOnlyModeEnabled)
            if isMenuBarOnlyModeEnabled, !isMenuBarEnabled {
                isMenuBarEnabled = true
            }
            MainWindowPresenter.applyUserPreferences()
        }
    }

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultOutputDevice: AudioDevice?
    @Published private(set) var currentSource: DetectedAudioSource?
    @Published private(set) var detectorStatus = "Waiting"
    @Published private(set) var lastSwitchStatus = "Ready"
    @Published private(set) var logEntries: [SwitchLogEntry] = []
    @Published private(set) var cachedTrackCount = 0
    @Published private(set) var isLaunchAtLoginEnabled = false

    private enum Defaults {
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let bitDepthPreference = "bitDepthPreference"
        static let menuBarEnabled = "menuBarEnabled"
        static let menuBarOnlyModeEnabled = "menuBarOnlyModeEnabled"
    }

    private let audioManager = CoreAudioDeviceManager()
    private let formatCache = TrackFormatCache()
    private let liveFormatMonitor = LiveConsoleAudioFormatMonitor()
    private let detectionQueue = DispatchQueue(label: "LosslessSwitcher.MusicDetection", qos: .userInitiated)
    private var timer: Timer?
    private var isDetectionInFlight = false
    private var lastAppliedSignature: String?
    private var lastObservedSourceSignature: String?
    private var lastObservedTrackIdentity: String?
    private var lastConsoleError: String?
    private var lastLiveFormat: DetectedAudioFormat?
    private var lastLiveFormatDate: Date?
    private var lastLiveFormatLogSignature: String?

    private struct DetectionSnapshot: Sendable {
        let musicResult: MusicDetectionResult
        let consoleFormat: DetectedAudioFormat?
        let consoleError: String?
        let detectedAt: Date
    }

    override init() {
        let defaults = UserDefaults.standard
        isAutoSwitchEnabled = Self.boolDefault(
            Defaults.autoSwitchEnabled,
            defaultValue: true,
            defaults: defaults
        )
        let bitDepthRawValue = defaults.object(forKey: Defaults.bitDepthPreference) as? Int
            ?? BitDepthPreference.twentyFour.rawValue
        bitDepthPreference = BitDepthPreference(rawValue: bitDepthRawValue) ?? .twentyFour
        isMenuBarEnabled = Self.boolDefault(
            Defaults.menuBarEnabled,
            defaultValue: true,
            defaults: defaults
        )
        isMenuBarOnlyModeEnabled = Self.boolDefault(
            Defaults.menuBarOnlyModeEnabled,
            defaultValue: false,
            defaults: defaults
        )

        super.init()

        cachedTrackCount = formatCache.count
        refreshLaunchAtLoginStatus()
        configureLiveFormatMonitor()
        refreshDevices()
        startMonitoring()
        liveFormatMonitor.start()
    }

    private static func boolDefault(
        _ key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    deinit {
        timer?.invalidate()
        liveFormatMonitor.stop()
    }

    var supportedRatesForDefaultDevice: [Double] {
        guard let defaultOutputDevice else {
            return []
        }

        let preferredRates: [Double] = [
            44_100,
            48_000,
            88_200,
            96_000,
            176_400,
            192_000,
            352_800,
            384_000,
            705_600,
            768_000
        ]

        let exactRates = defaultOutputDevice.supportedSampleRates
            .filter(\.isFixed)
            .map(\.minimum)

        let standardRates = preferredRates.filter { defaultOutputDevice.supports(sampleRate: $0) }
        return Array(Set(exactRates + standardRates)).sorted()
    }

    func refreshDevices() {
        do {
            devices = try audioManager.outputDevices()
            defaultOutputDevice = devices.first(where: \.isDefaultOutput)
        } catch {
            lastSwitchStatus = error.localizedDescription
            appendLog(title: "Device Refresh Failed", detail: error.localizedDescription, isError: true)
        }
    }

    func requestMusicAccess() {
        detectorStatus = "Requesting Music access..."
        detectMusic(forceSwitch: true)
    }

    func matchCurrentTrackNow() {
        detectorStatus = "Checking Music..."
        detectMusic(forceSwitch: true)
    }

    func openMusic() {
        let musicURL = URL(fileURLWithPath: "/System/Applications/Music.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: musicURL, configuration: configuration) { [weak self] _, error in
            let errorMessage = error?.localizedDescription
            DispatchQueue.main.async { [weak self, errorMessage] in
                if let errorMessage {
                    self?.appendLog(title: "Open Music Failed", detail: errorMessage, isError: true)
                } else {
                    self?.detectorStatus = "Music opened"
                    self?.detectMusic(forceSwitch: true)
                }
            }
        }
    }

    func setManualSampleRate(_ sampleRate: Double) {
        do {
            let changed = try audioManager.apply(
                sampleRate: sampleRate,
                preferredBitDepth: bitDepthPreference.targetBitDepth
            )
            refreshDevices()
            lastSwitchStatus = changed
                ? "Switched to \(formatLabel(sampleRate: sampleRate, bitDepth: bitDepthPreference.targetBitDepth))"
                : "Already at \(formatLabel(sampleRate: sampleRate, bitDepth: bitDepthPreference.targetBitDepth))"
            appendLog(title: "Manual Switch", detail: lastSwitchStatus, isError: false)
            lastAppliedSignature = nil
        } catch {
            lastSwitchStatus = error.localizedDescription
            appendLog(title: "Manual Switch Failed", detail: error.localizedDescription, isError: true)
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }

            refreshLaunchAtLoginStatus()
            appendLog(
                title: "Settings Updated",
                detail: enabled ? "Launch at login enabled" : "Launch at login disabled",
                isError: false
            )
        } catch {
            refreshLaunchAtLoginStatus()
            appendLog(title: "Login Item Failed", detail: error.localizedDescription, isError: true)
        }
    }

    func clearFormatCache() {
        formatCache.clear()
        cachedTrackCount = formatCache.count
        appendLog(title: "Song Memory Cleared", detail: "Removed all cached song formats", isError: false)
    }

    func refreshLaunchAtLoginStatus() {
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func startMonitoring() {
        let timer = Timer(
            timeInterval: 0.75,
            target: self,
            selector: #selector(pollTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func pollTimerFired(_ timer: Timer) {
        refreshDevices()
        detectMusic(forceSwitch: false)
    }

    private func detectMusic(forceSwitch: Bool) {
        guard !isDetectionInFlight else {
            return
        }

        isDetectionInFlight = true
        let shouldScanHistoricalLogs = forceSwitch || shouldScanHistoricalLogsForFallback

        detectionQueue.async { [weak self] in
            let musicResult = MusicSourceDetector().detect()
            var consoleFormat: DetectedAudioFormat?
            var consoleError: String?

            if case .playing = musicResult, shouldScanHistoricalLogs {
                do {
                    consoleFormat = try ConsoleAudioFormatDetector().detectRecentFormat()
                } catch {
                    consoleError = error.localizedDescription
                }
            }

            let snapshot = DetectionSnapshot(
                musicResult: musicResult,
                consoleFormat: consoleFormat,
                consoleError: consoleError,
                detectedAt: Date()
            )

            DispatchQueue.main.async { [weak self] in
                self?.finishDetection(snapshot, forceSwitch: forceSwitch)
            }
        }
    }

    private func configureLiveFormatMonitor() {
        liveFormatMonitor.onFormat = { [weak self] format in
            DispatchQueue.main.async {
                self?.handleLiveFormat(format)
            }
        }

        liveFormatMonitor.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.recordConsoleError(message)
            }
        }
    }

    private func handleLiveFormat(_ format: DetectedAudioFormat) {
        lastLiveFormat = format
        lastLiveFormatDate = format.date
        maybeLogLiveFormat(format)

        if let source = currentSource {
            let resolvedSource = source.withConsoleFormat(format)
            currentSource = resolvedSource
            detectorStatus = "\(resolvedSource.appName) \(formatLabel(sampleRate: resolvedSource.sampleRate, bitDepth: resolvedSource.bitDepth))"
        } else {
            detectorStatus = "Music \(formatLabel(sampleRate: format.sampleRate, bitDepth: format.bitDepth))"
        }

        guard isAutoSwitchEnabled else {
            return
        }

        switchTo(format: format, force: false)
    }

    private func finishDetection(_ snapshot: DetectionSnapshot, forceSwitch: Bool) {
        isDetectionInFlight = false
        handle(snapshot, forceSwitch: forceSwitch)
    }

    private func handle(_ snapshot: DetectionSnapshot, forceSwitch: Bool) {
        switch snapshot.musicResult {
        case .playing(let source):
            let resolvedSource = sourceWithBestAvailableFormat(from: source, snapshot: snapshot)
            currentSource = resolvedSource
            detectorStatus = "\(resolvedSource.appName) \(formatLabel(sampleRate: resolvedSource.sampleRate, bitDepth: resolvedSource.bitDepth))"
            recordConsoleError(snapshot.consoleError)
            maybeLogNewSource(resolvedSource)
            rememberFormatIfPossible(resolvedSource)

            if isAutoSwitchEnabled {
                switchTo(source: resolvedSource, force: forceSwitch)
            }

        case .inactive(let status):
            currentSource = nil
            detectorStatus = status
            lastObservedSourceSignature = nil
            lastObservedTrackIdentity = nil

        case .failed(let message):
            currentSource = nil
            lastObservedSourceSignature = nil
            lastObservedTrackIdentity = nil
            if message == "Music is not running" {
                detectorStatus = message
            } else {
                detectorStatus = message
                appendLog(title: "Detector Failed", detail: message, isError: true)
            }
        }
    }

    private func sourceWithBestAvailableFormat(
        from source: DetectedAudioSource,
        snapshot: DetectionSnapshot
    ) -> DetectedAudioSource {
        let trackIdentity = identity(for: source)
        let wasExistingTrack = lastObservedTrackIdentity == trackIdentity
        let isFirstObservedTrack = lastObservedTrackIdentity == nil

        if !wasExistingTrack {
            lastObservedTrackIdentity = trackIdentity
            lastAppliedSignature = nil
        }

        if let consoleFormat = snapshot.consoleFormat ?? recentLiveFormat(at: snapshot.detectedAt) {
            let maximumAge: TimeInterval = wasExistingTrack || isFirstObservedTrack ? 8 : 3
            if snapshot.detectedAt.timeIntervalSince(consoleFormat.date) <= maximumAge {
                return source.withConsoleFormat(consoleFormat)
            }
        }

        if let cachedFormat = formatCache.format(for: source) {
            return source.withConsoleFormat(cachedFormat)
        }

        return source
    }

    private func switchTo(source: DetectedAudioSource, force: Bool) {
        guard let defaultOutputDevice else {
            lastSwitchStatus = "No default output device"
            return
        }

        let targetBitDepth = targetBitDepth(for: source)
        let reliability = source.isSampleRateReliable ? "reliable" : "unreliable"
        let signature = formatSignature(
            device: defaultOutputDevice,
            sampleRate: source.sampleRate,
            bitDepth: targetBitDepth,
            reliability: reliability
        )
        guard force || signature != lastAppliedSignature else {
            return
        }

        if !force && !source.isSampleRateReliable {
            lastAppliedSignature = signature
            let detail = source.sampleRateNote ?? "Music did not expose a reliable stream sample rate"
            lastSwitchStatus = "Waiting for reliable Music rate"
            appendLog(title: "Apple Music Stream", detail: detail, isError: false)
            return
        }

        guard defaultOutputDevice.supports(sampleRate: source.sampleRate) else {
            lastAppliedSignature = signature
            let detail = "\(defaultOutputDevice.name) does not support \(sampleRateLabel(source.sampleRate))"
            lastSwitchStatus = detail
            appendLog(title: "Unsupported Rate", detail: detail, isError: true)
            return
        }

        do {
            let changed = try audioManager.apply(
                sampleRate: source.sampleRate,
                preferredBitDepth: targetBitDepth
            )
            refreshDevices()
            lastAppliedSignature = signature
            lastSwitchStatus = changed
                ? "Matched \(formatLabel(sampleRate: source.sampleRate, bitDepth: targetBitDepth))"
                : "Already matched \(formatLabel(sampleRate: source.sampleRate, bitDepth: targetBitDepth))"
            appendLog(
                title: changed ? "Switched" : "Matched",
                detail: "\(source.displayTitle) -> \(lastSwitchStatus)",
                isError: false
            )
        } catch {
            lastAppliedSignature = signature
            lastSwitchStatus = error.localizedDescription
            appendLog(title: "Switch Failed", detail: error.localizedDescription, isError: true)
        }
    }

    private func switchTo(format: DetectedAudioFormat, force: Bool) {
        guard let defaultOutputDevice else {
            lastSwitchStatus = "No default output device"
            return
        }

        let targetBitDepth = format.bitDepth ?? bitDepthPreference.targetBitDepth
        let signature = formatSignature(
            device: defaultOutputDevice,
            sampleRate: format.sampleRate,
            bitDepth: targetBitDepth,
            reliability: "reliable"
        )
        guard force || signature != lastAppliedSignature else {
            return
        }

        guard defaultOutputDevice.supports(sampleRate: format.sampleRate) else {
            lastAppliedSignature = signature
            let detail = "\(defaultOutputDevice.name) does not support \(sampleRateLabel(format.sampleRate))"
            lastSwitchStatus = detail
            appendLog(title: "Unsupported Rate", detail: detail, isError: true)
            return
        }

        do {
            let changed = try audioManager.apply(
                sampleRate: format.sampleRate,
                preferredBitDepth: targetBitDepth
            )
            refreshDevices()
            lastAppliedSignature = signature
            lastSwitchStatus = changed
                ? "Matched \(formatLabel(sampleRate: format.sampleRate, bitDepth: targetBitDepth))"
                : "Already matched \(formatLabel(sampleRate: format.sampleRate, bitDepth: targetBitDepth))"
            appendLog(
                title: changed ? "Live Switch" : "Live Match",
                detail: "\(lastSwitchStatus) from \(format.source)",
                isError: false
            )
        } catch {
            lastAppliedSignature = signature
            lastSwitchStatus = error.localizedDescription
            appendLog(title: "Switch Failed", detail: error.localizedDescription, isError: true)
        }
    }

    private func maybeLogNewSource(_ source: DetectedAudioSource) {
        let signature = "\(source.title)-\(source.artist)-\(Int(source.sampleRate.rounded()))-\(source.bitDepth ?? 0)-\(source.formatSource)"
        guard signature != lastObservedSourceSignature else {
            return
        }

        lastObservedSourceSignature = signature
        appendLog(
            title: "Detected",
            detail: "\(source.displayTitle) at \(formatLabel(sampleRate: source.sampleRate, bitDepth: source.bitDepth)) from \(source.formatSource)",
            isError: false
        )
    }

    private func targetBitDepth(for source: DetectedAudioSource) -> Int? {
        source.bitDepth ?? bitDepthPreference.targetBitDepth
    }

    private var shouldScanHistoricalLogsForFallback: Bool {
        guard let lastLiveFormatDate else {
            return true
        }

        return Date().timeIntervalSince(lastLiveFormatDate) > 8
    }

    private func recentLiveFormat(at date: Date) -> DetectedAudioFormat? {
        guard let lastLiveFormat,
              date.timeIntervalSince(lastLiveFormat.date) <= 8 else {
            return nil
        }

        return lastLiveFormat
    }

    private func identity(for source: DetectedAudioSource) -> String {
        source.cacheKey ?? "\(source.title)-\(source.artist)-\(source.album)"
    }

    private func formatSignature(
        device: AudioDevice,
        sampleRate: Double,
        bitDepth: Int?,
        reliability: String
    ) -> String {
        "\(device.id)-\(Int(sampleRate.rounded()))-\(bitDepth ?? 0)-\(reliability)"
    }

    private func maybeLogLiveFormat(_ format: DetectedAudioFormat) {
        let signature = "\(Int(format.sampleRate.rounded()))-\(format.bitDepth ?? 0)-\(format.source)"
        guard signature != lastLiveFormatLogSignature else {
            return
        }

        lastLiveFormatLogSignature = signature
        appendLog(
            title: "Live Format",
            detail: "\(formatLabel(sampleRate: format.sampleRate, bitDepth: format.bitDepth)) from \(format.source)",
            isError: false
        )
    }

    private func rememberFormatIfPossible(_ source: DetectedAudioSource) {
        let previousCount = formatCache.count
        let didChange = formatCache.store(source)
        cachedTrackCount = formatCache.count

        if didChange, formatCache.count > previousCount {
            appendLog(
                title: "Remembered Song",
                detail: "\(source.displayTitle) -> \(formatLabel(sampleRate: source.sampleRate, bitDepth: source.bitDepth))",
                isError: false
            )
        }
    }

    private func recordConsoleError(_ message: String?) {
        guard let message, message != lastConsoleError else {
            return
        }

        lastConsoleError = message
        appendLog(title: "Console Log Access Failed", detail: message, isError: true)
    }

    private func appendLog(title: String, detail: String, isError: Bool) {
        if logEntries.first?.title == title,
           logEntries.first?.detail == detail,
           logEntries.first?.isError == isError {
            return
        }

        logEntries.insert(
            SwitchLogEntry(date: Date(), title: title, detail: detail, isError: isError),
            at: 0
        )

        if logEntries.count > 12 {
            logEntries.removeLast(logEntries.count - 12)
        }
    }
}
