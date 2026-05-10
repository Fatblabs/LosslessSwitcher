import AppKit
import Foundation

enum MusicDetectionResult: Hashable, Sendable {
    case playing(DetectedAudioSource)
    case inactive(String)
    case failed(String)
}

final class MusicSourceDetector: Sendable {
    private let musicBundleIdentifier = "com.apple.Music"

    func detect() -> MusicDetectionResult {
        guard isMusicRunning else {
            return .inactive("Music is not running")
        }

        let script = """
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

        guard let appleScript = NSAppleScript(source: script) else {
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

    func requestAccess() -> MusicDetectionResult {
        detect()
    }

    private var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleIdentifier).isEmpty
    }

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
