import AudioToolbox
import Foundation

struct AudioSampleRateRange: Hashable, Identifiable, Sendable {
    let minimum: Double
    let maximum: Double

    var id: String {
        "\(Int(minimum.rounded()))-\(Int(maximum.rounded()))"
    }

    var isFixed: Bool {
        abs(minimum - maximum) < 0.5
    }

    func contains(_ sampleRate: Double) -> Bool {
        sampleRate >= minimum - 0.5 && sampleRate <= maximum + 0.5
    }

    var displayName: String {
        if isFixed {
            return sampleRateLabel(minimum)
        }

        return "\(sampleRateLabel(minimum))-\(sampleRateLabel(maximum))"
    }
}

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let isDefaultOutput: Bool
    let currentSampleRate: Double
    let currentBitDepth: Int?
    let supportedSampleRates: [AudioSampleRateRange]

    func supports(sampleRate: Double) -> Bool {
        supportedSampleRates.contains { $0.contains(sampleRate) }
    }
}

struct DetectedAudioSource: Hashable, Sendable {
    let appName: String
    let title: String
    let artist: String
    let album: String
    let kind: String
    let cloudStatus: String
    let persistentID: String
    let sampleRate: Double
    let bitDepth: Int?
    let bitRate: Int?
    let formatSource: String
    let isSampleRateReliable: Bool
    let sampleRateNote: String?

    var displayTitle: String {
        title.isEmpty ? "Unknown Track" : title
    }

    var displayArtist: String {
        artist.isEmpty ? appName : artist
    }

    var sourceDetail: String {
        [kind, cloudStatus]
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    var cacheKey: String? {
        if !persistentID.isEmpty {
            return "persistent:\(persistentID)"
        }

        let fallbackParts = [title, artist, album]
            .map(\.normalizedCacheToken)
        guard !fallbackParts[0].isEmpty, !fallbackParts[1].isEmpty else {
            return nil
        }

        return "metadata:\(fallbackParts.joined(separator: "|"))"
    }

    func withConsoleFormat(_ format: DetectedAudioFormat) -> DetectedAudioSource {
        DetectedAudioSource(
            appName: appName,
            title: title,
            artist: artist,
            album: album,
            kind: kind,
            cloudStatus: cloudStatus,
            persistentID: persistentID,
            sampleRate: format.sampleRate,
            bitDepth: format.bitDepth,
            bitRate: bitRate,
            formatSource: format.source,
            isSampleRateReliable: true,
            sampleRateNote: nil
        )
    }
}

enum BitDepthPreference: Int, CaseIterable, Identifiable, Sendable {
    case preserve = 0
    case sixteen = 16
    case twentyFour = 24
    case thirtyTwo = 32

    var id: Int {
        rawValue
    }

    var label: String {
        switch self {
        case .preserve:
            return "Preserve"
        case .sixteen:
            return "16-bit"
        case .twentyFour:
            return "24-bit"
        case .thirtyTwo:
            return "32-bit"
        }
    }

    var targetBitDepth: Int? {
        self == .preserve ? nil : rawValue
    }
}

struct SwitchLogEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let date: Date
    let title: String
    let detail: String
    let isError: Bool
}

func sampleRateLabel(_ sampleRate: Double) -> String {
    let khz = sampleRate / 1_000
    if abs(khz.rounded() - khz) < 0.01 {
        return "\(Int(khz.rounded())) kHz"
    }

    return String(format: "%.1f kHz", khz)
}

func formatLabel(sampleRate: Double, bitDepth: Int?) -> String {
    if let bitDepth {
        return "\(sampleRateLabel(sampleRate)) / \(bitDepth)-bit"
    }

    return sampleRateLabel(sampleRate)
}

private extension String {
    var normalizedCacheToken: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
