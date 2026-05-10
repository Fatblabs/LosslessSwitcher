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
            set trackItems to tracks of targetPlaylist
            set totalCount to count of trackItems
            set scannedCount to 0
            set scanLimit to 1000
            set snapshots to {}

            repeat with theTrack in trackItems
                if scannedCount is greater than or equal to scanLimit then exit repeat
                set end of snapshots to my losslessSwitcherTrackSnapshot(theTrack)
                set scannedCount to scannedCount + 1
            end repeat

            return {"ok", "currentPlaylist", playlistName, totalCount, scannedCount, snapshots}
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
            set trackItems to tracks of targetPlaylist
            set matchingCount to 0
            set scannedCount to 0
            set scanLimit to 1000
            set snapshots to {}

            repeat with theTrack in trackItems
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
        guard sampleRate > 0 else {
            return nil
        }

        let bitRateValue = descriptor.atIndex(2)?.int32Value ?? 0
        let kind = descriptor.atIndex(6)?.stringValue ?? ""
        let cloudStatus = descriptor.atIndex(7)?.stringValue ?? ""
        let reliability = sampleRateReliability(kind: kind, cloudStatus: cloudStatus)

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

    private func sampleRateReliability(kind: String, cloudStatus: String) -> (isReliable: Bool, note: String?) {
        let combined = "\(kind) \(cloudStatus)".lowercased()
        guard combined.contains("hls") || combined.contains("subscription") else {
            return (true, nil)
        }

        return (
            false,
            "Waiting for CoreAudio's decoder format. Music metadata reports this as \(kind.isEmpty ? "streaming media" : kind)."
        )
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
