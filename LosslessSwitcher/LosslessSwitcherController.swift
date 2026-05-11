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
            syncLiveFormatMonitor()
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

    @Published private(set) var defaultOutputDevice: AudioDevice?
    @Published private(set) var currentSource: DetectedAudioSource?
    @Published private(set) var detectorStatus = "Waiting"
    @Published private(set) var lastSwitchStatus = "Ready"
    @Published private(set) var logEntries: [SwitchLogEntry] = []
    @Published private(set) var cachedTrackCount = 0
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var isLibraryCacheScanInProgress = false

    private enum Defaults {
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let bitDepthPreference = "bitDepthPreference"
        static let menuBarEnabled = "menuBarEnabled"
        static let menuBarOnlyModeEnabled = "menuBarOnlyModeEnabled"
    }

    private let audioManager = CoreAudioDeviceManager()
    private let musicDetector = MusicSourceDetector()
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
    private var lastDeviceRefreshDate = Date.distantPast
    private var lastHistoricalScanDate = Date.distantPast
    private var lastInactiveDetectionDate = Date.distantPast
    private var lastObservedTrackChangeDate = Date.distantPast
    private var isMusicPlaybackActive = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pendingImmediateDetection: DispatchWorkItem?

    private let playbackPollInterval: TimeInterval = 2
    private let inactiveDetectionInterval: TimeInterval = 8
    private let deviceRefreshInterval: TimeInterval = 20
    private let historicalScanInterval: TimeInterval = 20
    private let midTrackDownshiftProtectionDelay: TimeInterval = 8
    private let maximumProbeTrackCount = 200
    private let probeTrackTimeout: TimeInterval = 8

    private struct DetectionSnapshot: Sendable {
        let musicResult: MusicDetectionResult
        let consoleFormat: DetectedAudioFormat?
        let consoleError: String?
        let detectedAt: Date
    }

    private struct LibraryProbeResult: Sendable {
        let scan: MusicLibraryTrackScan
        let metadataStoredCount: Int
        let probedSources: [DetectedAudioSource]
        let fallbackSources: [DetectedAudioSource]
        let failedProbeCount: Int
        let skippedProbeCount: Int
        let probeError: String?
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
        configureMusicNotifications()
        refreshDevices()
        startMonitoring()
        syncLiveFormatMonitor()
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
        pendingImmediateDetection?.cancel()
        workspaceObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        distributedObservers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
        }
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
        lastDeviceRefreshDate = Date()
        do {
            defaultOutputDevice = try audioManager.outputDevices().first(where: \.isDefaultOutput)
        } catch {
            lastSwitchStatus = error.localizedDescription
            appendLog(title: "Device Refresh Failed", detail: error.localizedDescription, isError: true)
        }
    }

    private func showPendingOutputFormat(sampleRate: Double, bitDepth: Int?) {
        guard let device = defaultOutputDevice else {
            return
        }

        defaultOutputDevice = AudioDevice(
            id: device.id,
            name: device.name,
            isDefaultOutput: device.isDefaultOutput,
            currentSampleRate: sampleRate,
            currentBitDepth: bitDepth ?? device.currentBitDepth,
            supportedSampleRates: device.supportedSampleRates
        )
    }

    private func reconcileOutputDeviceSoon() {
        [0.35, 1.0].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshDevices()
            }
        }
    }

    func refreshDevicesIfStale() {
        guard Date().timeIntervalSince(lastDeviceRefreshDate) >= deviceRefreshInterval else {
            return
        }

        refreshDevices()
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
            let targetBitDepth = bitDepthPreference.targetBitDepth
            let changed = try audioManager.apply(
                sampleRate: sampleRate,
                preferredBitDepth: targetBitDepth
            )
            showPendingOutputFormat(sampleRate: sampleRate, bitDepth: targetBitDepth)
            reconcileOutputDeviceSoon()
            lastSwitchStatus = changed
                ? "Switched to \(formatLabel(sampleRate: sampleRate, bitDepth: targetBitDepth))"
                : "Already at \(formatLabel(sampleRate: sampleRate, bitDepth: targetBitDepth))"
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

    func cacheCurrentAlbum() {
        cacheLibraryScope(.currentAlbum)
    }

    func cacheCurrentPlaylist() {
        cacheLibraryScope(.currentPlaylist)
    }

    private func cacheLibraryScope(_ scope: MusicLibraryCacheScope) {
        guard !isLibraryCacheScanInProgress else {
            return
        }

        isLibraryCacheScanInProgress = true
        lastSwitchStatus = "Scanning \(scope.label.lowercased())..."
        appendLog(title: "Song Memory Scan", detail: "Reading current \(scope.label.lowercased()) metadata", isError: false)

        let detector = musicDetector
        detectionQueue.async { [weak self] in
            let result = detector.scanTracks(scope: scope)

            DispatchQueue.main.async { [weak self] in
                self?.finishLibraryCacheScan(result)
            }
        }
    }

    private func finishLibraryCacheScan(_ result: MusicLibraryTrackScanResult) {
        switch result {
        case .success(let scan):
            let cacheableTracks = scan.tracks.filter(\.isSampleRateReliable)
            let metadataStoredCount = formatCache.storeAll(cacheableTracks)
            cachedTrackCount = formatCache.count

            let probeCandidates = scan.tracks.filter { source in
                !source.isSampleRateReliable
                    && !source.persistentID.isEmpty
                    && formatCache.format(for: source) == nil
            }

            guard !probeCandidates.isEmpty else {
                isLibraryCacheScanInProgress = false
                finishLibraryCacheScanWithoutProbe(scan: scan, metadataStoredCount: metadataStoredCount)
                return
            }

            lastSwitchStatus = "Probing \(min(probeCandidates.count, maximumProbeTrackCount)) \(scan.scope.label.lowercased()) tracks..."
            appendLog(
                title: "Stream Probe Started",
                detail: "Briefly playing Apple Music stream tracks to read real CoreAudio sample rates.",
                isError: false
            )
            probeLibraryTracks(scan: scan, metadataStoredCount: metadataStoredCount, candidates: probeCandidates)

        case .inactive(let message):
            isLibraryCacheScanInProgress = false
            lastSwitchStatus = message
            appendLog(title: "Song Memory Scan Skipped", detail: message, isError: true)

        case .failed(let message):
            isLibraryCacheScanInProgress = false
            lastSwitchStatus = message
            appendLog(title: "Song Memory Scan Failed", detail: message, isError: true)
        }
    }

    private func finishLibraryCacheScanWithoutProbe(
        scan: MusicLibraryTrackScan,
        metadataStoredCount: Int
    ) {
        let limitedSuffix = scan.scannedTrackCount < scan.totalTrackCount
            ? " Scanned first \(scan.scannedTrackCount) of \(scan.totalTrackCount)."
            : ""
        let skippedCount = scan.tracks.filter { source in
            !source.isSampleRateReliable && formatCache.format(for: source) == nil
        }.count
        let skippedSuffix = skippedCount > 0
            ? " \(skippedCount) tracks need playback probing."
            : ""

        lastSwitchStatus = "\(scan.scope.label) cache updated: \(metadataStoredCount) new"
        appendLog(
            title: "\(scan.scope.label) Cached",
            detail: "\(scan.name): \(metadataStoredCount) new from metadata.\(skippedSuffix)\(limitedSuffix)",
            isError: false
        )
    }

    private func probeLibraryTracks(
        scan: MusicLibraryTrackScan,
        metadataStoredCount: Int,
        candidates: [DetectedAudioSource]
    ) {
        let detector = musicDetector
        let probeTrackTimeout = probeTrackTimeout
        let maximumProbeTrackCount = maximumProbeTrackCount

        detectionQueue.async { [weak self] in
            let snapshot = detector.capturePlaybackSnapshot()
            let probeTargets = Array(candidates.prefix(maximumProbeTrackCount))
            let skippedProbeCount = max(candidates.count - probeTargets.count, 0)
            let formatProbe = ConsoleAudioFormatStreamProbe()
            let probeStartError = formatProbe.start()
            var probedSources: [DetectedAudioSource] = []
            var fallbackSources: [DetectedAudioSource] = []
            var failedProbeCount = 0
            var probeError = probeStartError
            var hasObservedFormat = false

            defer {
                formatProbe.stop()
                detector.restorePlayback(snapshot)
            }

            for (index, source) in probeTargets.enumerated() {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSwitchStatus = "Probing \(index + 1) of \(probeTargets.count)..."
                }

                formatProbe.reset()
                let startedAt = Date()
                if let error = detector.playTrack(persistentID: source.persistentID) {
                    failedProbeCount += 1
                    NSLog("LosslessSwitcher stream probe failed for \(source.displayTitle): \(error)")
                    continue
                }

                if probeStartError == nil,
                   let format = formatProbe.waitForFormat(after: startedAt, timeout: probeTrackTimeout) {
                    hasObservedFormat = true
                    probedSources.append(source.withConsoleFormat(format))
                } else if probeError == nil, let error = formatProbe.errorMessage {
                    probeError = error
                    failedProbeCount += 1
                } else if probeError == nil,
                          hasObservedFormat,
                          let fallbackSource = Self.metadataFallbackSource(for: source) {
                    fallbackSources.append(fallbackSource)
                } else {
                    failedProbeCount += 1
                }
            }

            let result = LibraryProbeResult(
                scan: scan,
                metadataStoredCount: metadataStoredCount,
                probedSources: probedSources,
                fallbackSources: fallbackSources,
                failedProbeCount: failedProbeCount,
                skippedProbeCount: skippedProbeCount,
                probeError: probeError
            )

            DispatchQueue.main.async { [weak self] in
                self?.finishLibraryProbe(result)
            }
        }
    }

    nonisolated private static func metadataFallbackSource(
        for source: DetectedAudioSource
    ) -> DetectedAudioSource? {
        guard source.sampleRate > 0 else {
            return nil
        }

        return DetectedAudioSource(
            appName: source.appName,
            title: source.title,
            artist: source.artist,
            album: source.album,
            kind: source.kind,
            cloudStatus: source.cloudStatus,
            persistentID: source.persistentID,
            sampleRate: source.sampleRate,
            bitDepth: source.bitDepth,
            bitRate: source.bitRate,
            formatSource: "Music metadata fallback",
            isSampleRateReliable: true,
            sampleRateNote: nil
        )
    }

    private func finishLibraryProbe(_ result: LibraryProbeResult) {
        isLibraryCacheScanInProgress = false

        let probedStoredCount = formatCache.storeAll(result.probedSources)
        let fallbackStoredCount = formatCache.storeAll(result.fallbackSources)
        cachedTrackCount = formatCache.count

        let totalStoredCount = result.metadataStoredCount + probedStoredCount + fallbackStoredCount
        let limitedSuffix = result.scan.scannedTrackCount < result.scan.totalTrackCount
            ? " Scanned first \(result.scan.scannedTrackCount) of \(result.scan.totalTrackCount)."
            : ""
        let skippedSuffix = result.skippedProbeCount > 0
            ? " Skipped \(result.skippedProbeCount) beyond the \(maximumProbeTrackCount)-track probe limit."
            : ""
        let failedSuffix = result.failedProbeCount > 0
            ? " \(result.failedProbeCount) probes did not produce a decoder format."
            : ""
        let errorSuffix = result.probeError.map { " Probe monitor: \($0)" } ?? ""

        lastSwitchStatus = "\(result.scan.scope.label) cache updated: \(totalStoredCount) new"
        appendLog(
            title: "\(result.scan.scope.label) Cached",
            detail: "\(result.scan.name): \(result.metadataStoredCount) metadata, \(probedStoredCount) live, \(fallbackStoredCount) fallback.\(failedSuffix)\(skippedSuffix)\(limitedSuffix)\(errorSuffix)",
            isError: result.failedProbeCount > 0 && totalStoredCount == 0
        )
    }

    func refreshLaunchAtLoginStatus() {
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func startMonitoring() {
        let timer = Timer(
            timeInterval: playbackPollInterval,
            target: self,
            selector: #selector(pollTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func pollTimerFired(_ timer: Timer) {
        refreshDevicesIfStale()
        syncLiveFormatMonitor()

        if !isMusicPlaybackActive {
            let now = Date()
            guard now.timeIntervalSince(lastInactiveDetectionDate) >= inactiveDetectionInterval else {
                return
            }
            lastInactiveDetectionDate = now
        }

        detectMusic(forceSwitch: false)
    }

    private func detectMusic(forceSwitch: Bool) {
        guard !isDetectionInFlight else {
            return
        }

        isDetectionInFlight = true
        let shouldScanHistoricalLogs = shouldScanHistoricalLogs(forceSwitch: forceSwitch)
        let detector = musicDetector

        detectionQueue.async { [weak self] in
            let musicResult = detector.detect()
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

    private func configureMusicNotifications() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let launchObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { notification in
            let bundleIdentifier = Self.notificationApplicationBundleIdentifier(notification)
            guard bundleIdentifier == "com.apple.Music" else {
                return
            }

            Task { @MainActor [weak self] in
                self?.scheduleImmediateDetection(forceSwitch: false)
            }
        }

        let terminateObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { notification in
            let bundleIdentifier = Self.notificationApplicationBundleIdentifier(notification)
            guard bundleIdentifier == "com.apple.Music" else {
                return
            }

            Task { @MainActor [weak self] in
                self?.clearPlaybackState(status: "Music is not running")
                self?.liveFormatMonitor.stop()
            }
        }

        workspaceObservers = [launchObserver, terminateObserver]

        let distributedCenter = DistributedNotificationCenter.default()
        let playerInfoNames = [
            Notification.Name("com.apple.Music.playerInfo"),
            Notification.Name("com.apple.iTunes.playerInfo")
        ]

        distributedObservers = playerInfoNames.map { name in
            distributedCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.scheduleImmediateDetection(forceSwitch: false)
                }
            }
        }
    }

    nonisolated private static func notificationApplicationBundleIdentifier(_ notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func scheduleImmediateDetection(forceSwitch: Bool) {
        pendingImmediateDetection?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.detectMusic(forceSwitch: forceSwitch)
        }
        pendingImmediateDetection = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func syncLiveFormatMonitor() {
        guard isAutoSwitchEnabled, musicDetector.isMusicRunning, isMusicPlaybackActive else {
            liveFormatMonitor.stop()
            return
        }

        liveFormatMonitor.start()
    }

    private func handleLiveFormat(_ format: DetectedAudioFormat) {
        lastLiveFormat = format
        lastLiveFormatDate = format.date

        if let source = currentSource,
           !shouldUseLiveFormat(format, for: source, detectedAt: format.date, wasExistingTrack: true, isFirstObservedTrack: false) {
            return
        }

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
            isMusicPlaybackActive = true
            syncLiveFormatMonitor()
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
            clearPlaybackState(status: status)
            syncLiveFormatMonitor()

        case .failed(let message):
            clearPlaybackState(status: message)
            syncLiveFormatMonitor()
            if message == "Music is not running" {
                return
            } else {
                appendLog(title: "Detector Failed", detail: message, isError: true)
            }
        }
    }

    private func clearPlaybackState(status: String) {
        isMusicPlaybackActive = false
        currentSource = nil
        detectorStatus = status
        lastObservedSourceSignature = nil
        lastObservedTrackIdentity = nil
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
            lastObservedTrackChangeDate = snapshot.detectedAt
            lastAppliedSignature = nil
        }

        if let consoleFormat = snapshot.consoleFormat,
           shouldUseLiveFormat(
            consoleFormat,
            for: source,
            detectedAt: snapshot.detectedAt,
            wasExistingTrack: wasExistingTrack,
            isFirstObservedTrack: isFirstObservedTrack
           ) {
            return source.withConsoleFormat(consoleFormat)
        }

        if let cachedFormat = formatCache.format(for: source) {
            return source.withConsoleFormat(cachedFormat)
        }

        if let liveFormat = recentLiveFormat(at: snapshot.detectedAt),
           shouldUseLiveFormat(
            liveFormat,
            for: source,
            detectedAt: snapshot.detectedAt,
            wasExistingTrack: wasExistingTrack,
            isFirstObservedTrack: isFirstObservedTrack
           ) {
            return source.withConsoleFormat(liveFormat)
        }

        return source
    }

    private func switchTo(source: DetectedAudioSource, force: Bool) {
        let targetBitDepth = targetBitDepth(for: source)
        let context = switchContext(
            sampleRate: source.sampleRate,
            bitDepth: targetBitDepth,
            reliability: source.isSampleRateReliable ? "reliable" : "unreliable",
            force: force
        )
        guard let context else {
            return
        }

        if !force && !source.isSampleRateReliable {
            lastAppliedSignature = context.signature
            let detail = source.sampleRateNote ?? "Music did not expose a reliable stream sample rate"
            lastSwitchStatus = "Waiting for reliable Music rate"
            appendLog(title: "Apple Music Stream", detail: detail, isError: false)
            return
        }

        applySwitch(
            context,
            changedTitle: "Switched",
            matchedTitle: "Matched",
            detail: { "\(source.displayTitle) -> \($0)" }
        )
    }

    private func switchTo(format: DetectedAudioFormat, force: Bool) {
        let targetBitDepth = format.bitDepth ?? bitDepthPreference.targetBitDepth
        guard let context = switchContext(
            sampleRate: format.sampleRate,
            bitDepth: targetBitDepth,
            reliability: "reliable",
            force: force
        ) else {
            return
        }

        applySwitch(
            context,
            changedTitle: "Live Switch",
            matchedTitle: "Live Match",
            detail: { "\($0) from \(format.source)" }
        )
    }

    private typealias SwitchContext = (
        device: AudioDevice,
        sampleRate: Double,
        bitDepth: Int?,
        signature: String
    )

    private func switchContext(
        sampleRate: Double,
        bitDepth: Int?,
        reliability: String,
        force: Bool
    ) -> SwitchContext? {
        guard let defaultOutputDevice else {
            lastSwitchStatus = "No default output device"
            return nil
        }

        let signature = formatSignature(
            device: defaultOutputDevice,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            reliability: reliability
        )
        guard force || signature != lastAppliedSignature else {
            return nil
        }

        return (defaultOutputDevice, sampleRate, bitDepth, signature)
    }

    private func applySwitch(
        _ context: SwitchContext,
        changedTitle: String,
        matchedTitle: String,
        detail: (String) -> String
    ) {
        guard context.device.supports(sampleRate: context.sampleRate) else {
            lastAppliedSignature = context.signature
            lastSwitchStatus = "\(context.device.name) does not support \(sampleRateLabel(context.sampleRate))"
            appendLog(title: "Unsupported Rate", detail: lastSwitchStatus, isError: true)
            return
        }

        do {
            let changed = try audioManager.apply(
                sampleRate: context.sampleRate,
                preferredBitDepth: context.bitDepth
            )
            showPendingOutputFormat(sampleRate: context.sampleRate, bitDepth: context.bitDepth)
            reconcileOutputDeviceSoon()
            lastAppliedSignature = context.signature
            lastSwitchStatus = changed
                ? "Matched \(formatLabel(sampleRate: context.sampleRate, bitDepth: context.bitDepth))"
                : "Already matched \(formatLabel(sampleRate: context.sampleRate, bitDepth: context.bitDepth))"
            appendLog(title: changed ? changedTitle : matchedTitle, detail: detail(lastSwitchStatus), isError: false)
        } catch {
            lastAppliedSignature = context.signature
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

    private func shouldScanHistoricalLogs(forceSwitch: Bool) -> Bool {
        if forceSwitch {
            lastHistoricalScanDate = Date()
            return true
        }

        guard shouldScanHistoricalLogsForFallback else {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(lastHistoricalScanDate) >= historicalScanInterval else {
            return false
        }

        lastHistoricalScanDate = now
        return true
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

    private func shouldUseLiveFormat(
        _ format: DetectedAudioFormat,
        for source: DetectedAudioSource,
        detectedAt: Date,
        wasExistingTrack: Bool,
        isFirstObservedTrack: Bool
    ) -> Bool {
        let maximumAge: TimeInterval = wasExistingTrack || isFirstObservedTrack ? 8 : 3
        guard detectedAt.timeIntervalSince(format.date) <= maximumAge else {
            return false
        }

        if wasExistingTrack,
           source.isSampleRateReliable,
           format.sampleRate + 0.5 < source.sampleRate,
           detectedAt.timeIntervalSince(lastObservedTrackChangeDate) > midTrackDownshiftProtectionDelay {
            return false
        }

        return true
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
