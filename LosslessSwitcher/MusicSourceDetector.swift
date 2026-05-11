import AppKit
import Foundation

enum MusicDetectionResult: Hashable, Sendable {
    case playing(DetectedAudioSource)
    case inactive(String)
    case failed(String)
}

final class MusicSourceDetector: @unchecked Sendable {
    private let musicBundleIdentifier = "com.apple.Music"
    private lazy var detectorScript = NSAppleScript(source: Self.detectorScriptSource)
    private lazy var currentViewScanScript = NSAppleScript(source: Self.currentViewScanScriptSource)
    private lazy var albumScanScript = NSAppleScript(source: Self.albumScanScriptSource)
    private lazy var playlistScanScript = NSAppleScript(source: Self.playlistScanScriptSource)

    func detect() -> MusicDetectionResult {
        guard isMusicRunning else {
            return .inactive("Music is not running")
        }

        guard let appleScript = detectorScript else {
            return .failed("Unable to prepare Music detector")
        }

        var errorInfo: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return scriptFailureResult(from: errorInfo)
        }

        guard descriptor.descriptorType == typeAEList else {
            return .failed("Music returned an unexpected response")
        }

        let playerState = descriptor.atIndex(1)?.stringValue ?? "unknown"
        guard playerState == "playing" else {
            return .inactive("Music is \(playerState)")
        }

        let sampleRate = Double(descriptor.atIndex(2)?.int32Value ?? 0)
        guard sampleRate > 0 else {
            return .inactive("Music did not report a sample rate")
        }

        let bitRateValue = descriptor.atIndex(3)?.int32Value ?? 0
        let kind = descriptor.atIndex(7)?.stringValue ?? ""
        let cloudStatus = descriptor.atIndex(8)?.stringValue ?? ""
        let reliability = sampleRateReliability(kind: kind, cloudStatus: cloudStatus)
        let source = DetectedAudioSource(
            appName: "Music",
            title: descriptor.atIndex(4)?.stringValue ?? "",
            artist: descriptor.atIndex(5)?.stringValue ?? "",
            album: descriptor.atIndex(6)?.stringValue ?? "",
            kind: kind,
            cloudStatus: cloudStatus,
            persistentID: descriptor.atIndex(9)?.stringValue ?? "",
            sampleRate: sampleRate,
            bitDepth: nil,
            bitRate: bitRateValue > 0 ? Int(bitRateValue) : nil,
            formatSource: "Music metadata",
            isSampleRateReliable: reliability.isReliable,
            sampleRateNote: reliability.note
        )

        return .playing(source)
    }

    func scanTracks(scope: MusicLibraryCacheScope) -> MusicLibraryTrackScanResult {
        guard isMusicRunning else {
            return .inactive("Music is not running")
        }

        let script: NSAppleScript?
        switch scope {
        case .currentView:
            script = currentViewScanScript
        case .currentAlbum:
            script = albumScanScript
        case .currentPlaylist:
            script = playlistScanScript
        }

        guard let script else {
            return .failed("Unable to prepare Music library scan")
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return scriptFailureResult(from: errorInfo).libraryScanResult
        }

        return parseTrackScan(descriptor, requestedScope: scope)
    }

    func capturePlaybackSnapshot() -> MusicPlaybackSnapshot? {
        guard isMusicRunning,
              let script = NSAppleScript(source: Self.playbackSnapshotScriptSource) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, descriptor.descriptorType == typeAEList else {
            return nil
        }

        return MusicPlaybackSnapshot(
            playerState: descriptor.atIndex(1)?.stringValue ?? "stopped",
            persistentID: descriptor.atIndex(2)?.stringValue ?? "",
            playerPosition: descriptor.atIndex(3)?.doubleValue ?? 0
        )
    }

    func playTrack(
        persistentID: String,
        confirmationTimeout: TimeInterval,
        settleDuration: TimeInterval
    ) -> String? {
        guard isMusicRunning else {
            return "Music is not running"
        }

        let escapedPersistentID = persistentID.escapedForAppleScriptString
        guard !escapedPersistentID.isEmpty,
              let script = NSAppleScript(
                source: Self.playTrackScriptSource(
                    persistentID: escapedPersistentID,
                    confirmationTimeout: confirmationTimeout,
                    settleDuration: settleDuration
                )
              ) else {
            return "Track is missing a persistent ID"
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        return errorInfo.flatMap(scriptErrorMessage)
    }

    func restorePlayback(_ snapshot: MusicPlaybackSnapshot?) {
        guard isMusicRunning else {
            return
        }

        guard let snapshot else {
            stopPlayback()
            return
        }

        guard let script = NSAppleScript(source: Self.restorePlaybackScriptSource(snapshot: snapshot)) else {
            stopPlayback()
            return
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
    }

    private func stopPlayback() {
        guard let script = NSAppleScript(source: Self.stopPlaybackScriptSource) else {
            return
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
    }

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleIdentifier).isEmpty
    }

    private static let detectorScriptSource = """
        tell application "Music"
            set playerState to player state as text
            if playerState is not "playing" then
                return {playerState, 0, 0, "", "", "", "", "", ""}
            end if

            set theTrack to current track
            set trackSampleRate to 0
            set trackBitRate to 0
            set trackName to ""
            set trackArtist to ""
            set trackAlbum to ""
            set trackKind to ""
            set trackCloudStatus to ""
            set trackPersistentID to ""

            try
                set trackSampleRate to sample rate of theTrack
            end try
            try
                set trackBitRate to bit rate of theTrack
            end try
            try
                set trackName to name of theTrack
            end try
            try
                set trackArtist to artist of theTrack
            end try
            try
                set trackAlbum to album of theTrack
            end try
            try
                set trackKind to kind of theTrack
            end try
            try
                set trackCloudStatus to cloud status of theTrack as text
            end try
            try
                set trackPersistentID to persistent ID of theTrack
            end try

            return {playerState, trackSampleRate, trackBitRate, trackName, trackArtist, trackAlbum, trackKind, trackCloudStatus, trackPersistentID}
        end tell
        """

    private static let playbackSnapshotScriptSource = """
        tell application "Music"
            set playerStateText to player state as text
            set trackPersistentID to ""
            set trackPosition to 0

            try
                set trackPersistentID to persistent ID of current track
            end try
            try
                set trackPosition to player position
            end try

            return {playerStateText, trackPersistentID, trackPosition}
        end tell
        """

    private static let stopPlaybackScriptSource = """
        tell application "Music"
            stop
        end tell
        """

    private static func playTrackScriptSource(
        persistentID: String,
        confirmationTimeout: TimeInterval,
        settleDuration: TimeInterval
    ) -> String {
        let timeout = String(format: "%.2f", confirmationTimeout)
        let settle = String(format: "%.2f", settleDuration)

        return """
        tell application "Music"
            set targetTrack to missing value

            try
                set targetTrack to first track of view of front browser window whose persistent ID is "\(persistentID)"
            end try
            if targetTrack is missing value then
                try
                    set targetTrack to first track of current playlist whose persistent ID is "\(persistentID)"
                end try
            end if
            if targetTrack is missing value then
                try
                    set targetTrack to first track of library playlist 1 whose persistent ID is "\(persistentID)"
                end try
            end if
            if targetTrack is missing value then error "Track is no longer available in Music"

            try
                stop
            end try
            delay 0.05
            play targetTrack once true
            set startedAt to current date
            set matchedAt to missing value
            repeat while ((current date) - startedAt) < \(timeout)
                try
                    if persistent ID of current track is "\(persistentID)" and (player state as text) is "playing" then
                        if matchedAt is missing value then set matchedAt to current date
                        if player position is greater than 0.12 then return "ok"
                        if ((current date) - matchedAt) >= \(settle) then return "ok"
                    else
                        set matchedAt to missing value
                    end if
                end try
                delay 0.05
            end repeat

            error "Music did not start the requested probe track"
        end tell
        """
    }

    private static func restorePlaybackScriptSource(snapshot: MusicPlaybackSnapshot) -> String {
        let persistentID = snapshot.persistentID.escapedForAppleScriptString
        let playerState = snapshot.playerState.escapedForAppleScriptString
        let playerPosition = max(snapshot.playerPosition, 0)

        return """
        tell application "Music"
            try
                stop
            end try
            delay 0.08

            if "\(persistentID)" is not "" then
                try
                    set targetTrack to first track of current playlist whose persistent ID is "\(persistentID)"
                    play targetTrack
                on error
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is "\(persistentID)"
                        play targetTrack
                    end try
                end try

                try
                    set player position to \(playerPosition)
                end try
            end if

            if "\(playerState)" is "paused" then
                pause
            else if "\(playerState)" is "stopped" then
                stop
            end if
        end tell
        """
    }

    private static let trackSnapshotHandlerSource = """
        on losslessSwitcherTrackSnapshot(theTrack)
            tell application "Music"
                set trackSampleRate to 0
                set trackBitRate to 0
                set trackName to ""
                set trackArtist to ""
                set trackAlbum to ""
                set trackKind to ""
                set trackCloudStatus to ""
                set trackPersistentID to ""

                try
                    set trackSampleRate to sample rate of theTrack
                end try
                try
                    set trackBitRate to bit rate of theTrack
                end try
                try
                    set trackName to name of theTrack
                end try
                try
                    set trackArtist to artist of theTrack
                end try
                try
                    set trackAlbum to album of theTrack
                end try
                try
                    set trackKind to kind of theTrack
                end try
                try
                    set trackCloudStatus to cloud status of theTrack as text
                end try
                try
                    set trackPersistentID to persistent ID of theTrack
                end try

                return {trackSampleRate, trackBitRate, trackName, trackArtist, trackAlbum, trackKind, trackCloudStatus, trackPersistentID}
            end tell
        end losslessSwitcherTrackSnapshot
        """

    private static let playlistScanScriptSource = trackSnapshotHandlerSource + """

        tell application "Music"
            try
                set targetPlaylist to current playlist
            on error
                set targetPlaylist to view of front browser window
            end try
            set playlistName to name of targetPlaylist
            set totalCount to count of tracks of targetPlaylist
            set scannedCount to 0
            set scanLimit to 1000
            set snapshots to {}

            repeat with trackIndex from 1 to totalCount
                if scannedCount is greater than or equal to scanLimit then exit repeat
                set theTrack to track trackIndex of targetPlaylist
                set end of snapshots to my losslessSwitcherTrackSnapshot(theTrack)
                set scannedCount to scannedCount + 1
            end repeat

            return {"ok", "currentPlaylist", playlistName, totalCount, scannedCount, snapshots}
        end tell
        """

    private static let currentViewScanScriptSource = trackSnapshotHandlerSource + """

        on losslessSwitcherAlbumMetadata(theTrack)
            tell application "Music"
                set trackAlbum to ""
                set trackArtist to ""
                set trackAlbumArtist to ""
                try
                    set trackAlbum to album of theTrack
                end try
                try
                    set trackArtist to artist of theTrack
                end try
                try
                    set trackAlbumArtist to album artist of theTrack
                end try
                if trackAlbumArtist is "" then set trackAlbumArtist to trackArtist

                return {trackAlbum, trackArtist, trackAlbumArtist}
            end tell
        end losslessSwitcherAlbumMetadata

        tell application "Music"
            set targetPlaylist to missing value
            try
                set targetPlaylist to view of front browser window
            on error
                try
                    set targetPlaylist to current playlist
                on error
                    return {"error", "Open or play an album or playlist in Music first", "", 0, 0, {}}
                end try
            end try

            set seedTrack to missing value
            try
                set seedTrack to item 1 of selection of front browser window
            on error
                try
                    set seedTrack to current track
                on error
                    try
                        set seedTrack to track 1 of targetPlaylist
                    end try
                end try
            end try

            set playlistName to name of targetPlaylist
            set playlistIdentity to ""
            try
                set playlistIdentity to playlistIdentity & ((class of targetPlaylist) as text)
            end try
            try
                set playlistIdentity to playlistIdentity & " " & ((special kind of targetPlaylist) as text)
            end try
            set playlistLooksLibrary to false
            if playlistIdentity contains "library" or playlistIdentity contains "Library" then set playlistLooksLibrary to true
            if playlistIdentity contains "Purchased" then set playlistLooksLibrary to true

            set targetAlbum to ""
            set targetAlbumArtist to ""
            set targetTrackCount to 0
            if seedTrack is not missing value then
                set seedMetadata to my losslessSwitcherAlbumMetadata(seedTrack)
                set targetAlbum to item 1 of seedMetadata
                set targetAlbumArtist to item 3 of seedMetadata
                try
                    set targetTrackCount to track count of seedTrack
                end try
            end if

            set totalCount to count of tracks of targetPlaylist
            set scanLimit to 1000
            set playlistScannedCount to 0
            set albumScannedCount to 0
            set albumMatchingCount to 0
            set playlistSnapshots to {}
            set albumSnapshots to {}

            repeat with trackIndex from 1 to totalCount
                set theTrack to track trackIndex of targetPlaylist

                if not playlistLooksLibrary and playlistScannedCount is less than scanLimit then
                    set end of playlistSnapshots to my losslessSwitcherTrackSnapshot(theTrack)
                    set playlistScannedCount to playlistScannedCount + 1
                end if

                if targetAlbum is not "" then
                    set trackMetadata to my losslessSwitcherAlbumMetadata(theTrack)
                    set trackAlbum to item 1 of trackMetadata
                    set trackArtist to item 2 of trackMetadata
                    set trackAlbumArtist to item 3 of trackMetadata

                    if trackAlbum is targetAlbum then
                        if targetAlbumArtist is "" or trackAlbumArtist is targetAlbumArtist or trackArtist is targetAlbumArtist then
                            set albumMatchingCount to albumMatchingCount + 1
                            if albumScannedCount is less than scanLimit then
                                set end of albumSnapshots to my losslessSwitcherTrackSnapshot(theTrack)
                                set albumScannedCount to albumScannedCount + 1
                            end if
                        end if
                    end if
                end if
            end repeat

            set shouldCacheAlbum to false
            if targetAlbum is not "" and albumMatchingCount is greater than 0 then
                if totalCount is albumMatchingCount then set shouldCacheAlbum to true
                if targetTrackCount is greater than 0 and totalCount is less than or equal to targetTrackCount then set shouldCacheAlbum to true
                if playlistLooksLibrary then set shouldCacheAlbum to true
            end if

            if shouldCacheAlbum then
                return {"ok", "currentAlbum", targetAlbum, albumMatchingCount, albumScannedCount, albumSnapshots}
            end if

            return {"ok", "currentPlaylist", playlistName, totalCount, playlistScannedCount, playlistSnapshots}
        end tell
        """

    private static let albumScanScriptSource = trackSnapshotHandlerSource + """

        tell application "Music"
            try
                set seedTrack to current track
            on error
                try
                    set seedTrack to item 1 of selection of front browser window
                on error
                    return {"error", "Select or play a track from the album first", "", 0, 0, {}}
                end try
            end try

            set targetAlbum to ""
            set targetAlbumArtist to ""
            try
                set targetAlbum to album of seedTrack
            end try
            try
                set targetAlbumArtist to album artist of seedTrack
            end try
            if targetAlbumArtist is "" then
                try
                    set targetAlbumArtist to artist of seedTrack
                end try
            end if
            if targetAlbum is "" then
                return {"error", "Current track has no album metadata", "", 0, 0, {}}
            end if

            try
                set targetPlaylist to current playlist
            on error
                set targetPlaylist to view of front browser window
            end try
            set totalCount to count of tracks of targetPlaylist
            set matchingCount to 0
            set scannedCount to 0
            set scanLimit to 1000
            set snapshots to {}

            repeat with trackIndex from 1 to totalCount
                set theTrack to track trackIndex of targetPlaylist
                set trackAlbum to ""
                set trackArtist to ""
                set trackAlbumArtist to ""

                try
                    set trackAlbum to album of theTrack
                end try
                if trackAlbum is targetAlbum then
                    try
                        set trackArtist to artist of theTrack
                    end try
                    try
                        set trackAlbumArtist to album artist of theTrack
                    end try
                    if trackAlbumArtist is "" then set trackAlbumArtist to trackArtist

                    if targetAlbumArtist is "" or trackAlbumArtist is targetAlbumArtist or trackArtist is targetAlbumArtist then
                        set matchingCount to matchingCount + 1
                        if scannedCount is less than scanLimit then
                            set end of snapshots to my losslessSwitcherTrackSnapshot(theTrack)
                            set scannedCount to scannedCount + 1
                        end if
                    end if
                end if
            end repeat

            return {"ok", "currentAlbum", targetAlbum, matchingCount, scannedCount, snapshots}
        end tell
        """

    private func scriptFailureResult(from errorInfo: NSDictionary) -> MusicDetectionResult {
        let number = errorInfo[NSAppleScript.errorNumber] as? NSNumber
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Music automation failed"

        if number?.intValue == -1743 {
            return .failed("Music automation is not allowed. Enable LosslessSwitcher in System Settings > Privacy & Security > Automation.")
        }

        if number?.intValue == -600
            || message.localizedCaseInsensitiveContains("application isn't running")
            || message.localizedCaseInsensitiveContains("application is not running")
            || message.localizedCaseInsensitiveContains("isn't running")
            || message.localizedCaseInsensitiveContains("is not running") {
            return .inactive("Music is not ready")
        }

        return .failed(message)
    }

    private func parseTrackScan(
        _ descriptor: NSAppleEventDescriptor,
        requestedScope: MusicLibraryCacheScope
    ) -> MusicLibraryTrackScanResult {
        guard descriptor.descriptorType == typeAEList else {
            return .failed("Music returned an unexpected library scan response")
        }

        let status = descriptor.atIndex(1)?.stringValue ?? "error"
        guard status == "ok" else {
            return .failed(descriptor.atIndex(2)?.stringValue ?? "Music could not scan tracks")
        }

        let rawScope = descriptor.atIndex(2)?.stringValue ?? requestedScope.rawValue
        let scope = MusicLibraryCacheScope(rawValue: rawScope) ?? requestedScope
        let name = descriptor.atIndex(3)?.stringValue ?? scope.label
        let totalCount = Int(descriptor.atIndex(4)?.int32Value ?? 0)
        let scannedCount = Int(descriptor.atIndex(5)?.int32Value ?? 0)
        guard let trackList = descriptor.atIndex(6), trackList.descriptorType == typeAEList else {
            return .failed("Music returned no track list")
        }

        let itemCount = max(trackList.numberOfItems, 0)
        let tracks = itemCount == 0
            ? []
            : (1...itemCount).compactMap { index in
                source(fromTrackDescriptor: trackList.atIndex(index))
            }

        return .success(
            MusicLibraryTrackScan(
                scope: scope,
                name: name,
                totalTrackCount: totalCount,
                scannedTrackCount: scannedCount,
                tracks: tracks
            )
        )
    }

    private func source(fromTrackDescriptor descriptor: NSAppleEventDescriptor?) -> DetectedAudioSource? {
        guard let descriptor, descriptor.descriptorType == typeAEList else {
            return nil
        }

        let sampleRate = Double(descriptor.atIndex(1)?.int32Value ?? 0)
        let bitRateValue = descriptor.atIndex(2)?.int32Value ?? 0
        let kind = descriptor.atIndex(6)?.stringValue ?? ""
        let cloudStatus = descriptor.atIndex(7)?.stringValue ?? ""
        let reliability = sampleRateReliability(sampleRate: sampleRate, kind: kind, cloudStatus: cloudStatus)

        return DetectedAudioSource(
            appName: "Music",
            title: descriptor.atIndex(3)?.stringValue ?? "",
            artist: descriptor.atIndex(4)?.stringValue ?? "",
            album: descriptor.atIndex(5)?.stringValue ?? "",
            kind: kind,
            cloudStatus: cloudStatus,
            persistentID: descriptor.atIndex(8)?.stringValue ?? "",
            sampleRate: sampleRate,
            bitDepth: nil,
            bitRate: bitRateValue > 0 ? Int(bitRateValue) : nil,
            formatSource: "Music library metadata",
            isSampleRateReliable: reliability.isReliable,
            sampleRateNote: reliability.note
        )
    }

    private func sampleRateReliability(
        sampleRate: Double? = nil,
        kind: String,
        cloudStatus: String
    ) -> (isReliable: Bool, note: String?) {
        if let sampleRate, sampleRate <= 0 {
            return (
                false,
                "Music library metadata does not expose this track's sample rate before playback."
            )
        }

        let combined = "\(kind) \(cloudStatus)".lowercased()
        guard combined.contains("hls") || combined.contains("subscription") else {
            return (true, nil)
        }

        return (
            false,
            "Waiting for CoreAudio's decoder format. Music metadata reports this as \(kind.isEmpty ? "streaming media" : kind)."
        )
    }

    private func scriptErrorMessage(from errorInfo: NSDictionary) -> String {
        errorInfo[NSAppleScript.errorMessage] as? String ?? "Music automation failed"
    }
}

private extension MusicDetectionResult {
    var libraryScanResult: MusicLibraryTrackScanResult {
        switch self {
        case .inactive(let message):
            return .inactive(message)
        case .failed(let message):
            return .failed(message)
        case .playing:
            return .failed("Music returned an unexpected playback result")
        }
    }
}

private extension String {
    var escapedForAppleScriptString: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
