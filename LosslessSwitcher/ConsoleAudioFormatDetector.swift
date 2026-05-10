import Foundation
import OSLog

struct DetectedAudioFormat: Hashable, Sendable {
    let sampleRate: Double
    let bitDepth: Int?
    let source: String
    let date: Date
    let priority: Int
}

final class ConsoleAudioFormatDetector: Sendable {
    func detectRecentFormat(lookback: TimeInterval = 8) throws -> DetectedAudioFormat? {
        let entries = try recentLogEntries(lookback: lookback)
        let formats = parseFormats(from: entries)
        return formats.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }

            return lhs.date > rhs.date
        }
        .first
    }

    private func recentLogEntries(lookback: TimeInterval) throws -> [ConsoleLogEntry] {
        let store = try OSLogStore.local()
        let position = store.position(timeIntervalSinceEnd: -lookback)
        let configs = ConsoleLogType.allCases

        return try configs.flatMap { config in
            try store
                .getEntries(
                    at: position,
                    matching: config.predicate
                )
                .compactMap { entry -> ConsoleLogEntry? in
                    guard let logEntry = entry as? OSLogEntryLog else {
                        return nil
                    }

                    return ConsoleLogEntry(
                        date: logEntry.date,
                        message: logEntry.composedMessage,
                        type: config
                    )
                }
        }
    }

    private func parseFormats(from entries: [ConsoleLogEntry]) -> [DetectedAudioFormat] {
        entries
            .sorted { $0.date > $1.date }
            .compactMap { ConsoleAudioFormatParser.parse($0) }
    }
}

nonisolated enum ConsoleAudioFormatParser {
    static func parse(_ entry: ConsoleLogEntry) -> DetectedAudioFormat? {
        parse(message: entry.message, type: entry.type, date: entry.date)
    }

    static func parseStreamLine(_ line: String, date: Date = Date()) -> DetectedAudioFormat? {
        ConsoleLogType.allCases
            .compactMap { parse(message: line, type: $0, date: date) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }

                return lhs.date > rhs.date
            }
            .first
    }

    private static func parse(message: String, type: ConsoleLogType, date: Date) -> DetectedAudioFormat? {
        switch type {
        case .coreAudio:
            return parseCoreAudio(message: message, date: date)
        case .coreMedia:
            return parseCoreMedia(message: message, date: date)
        case .music:
            return parseMusic(message: message, date: date)
        }
    }

    private static func parseCoreAudio(message: String, date: Date) -> DetectedAudioFormat? {
        guard message.contains("ACAppleLosslessDecoder.cpp"),
              message.contains("Input format:"),
              let sampleRateText = message.substring(between: "ch, ", and: " Hz"),
              let sampleRate = Double(sampleRateText.trimmedForNumber) else {
            return nil
        }

        let bitDepth = message
            .substring(between: "from ", and: "-bit source")
            .flatMap { Int($0.trimmedForNumber) }

        return DetectedAudioFormat(
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            source: "CoreAudio decoder",
            date: date,
            priority: 5
        )
    }

    private static func parseCoreMedia(message: String, date: Date) -> DetectedAudioFormat? {
        guard message.contains("Creating AudioQueue"),
              let sampleRateText = message.substring(after: "sampleRate:"),
              let sampleRate = sampleRateText.firstDouble else {
            return nil
        }

        return DetectedAudioFormat(
            sampleRate: sampleRate,
            bitDepth: 24,
            source: "CoreMedia AudioQueue",
            date: date,
            priority: 4
        )
    }

    private static func parseMusic(message: String, date: Date) -> DetectedAudioFormat? {
        guard message.contains("audioCapabilities:"),
              let sampleRateText = message.substring(between: "asbdSampleRate = ", and: " kHz"),
              let sampleRateKHz = Double(sampleRateText.trimmedForNumber) else {
            return nil
        }

        let bitDepth = message
            .substring(between: "sdBitDepth = ", and: " bit")
            .flatMap { Int($0.trimmedForNumber) }
            ?? (message.contains("sdBitRate =") ? 16 : nil)

        return DetectedAudioFormat(
            sampleRate: sampleRateKHz * 1_000,
            bitDepth: bitDepth,
            source: "Music audio capabilities",
            date: date,
            priority: 3
        )
    }
}

enum ConsoleLogType: CaseIterable, Sendable {
    case music
    case coreAudio
    case coreMedia

    var subsystem: String {
        switch self {
        case .music:
            return "com.apple.Music"
        case .coreAudio:
            return "com.apple.coreaudio"
        case .coreMedia:
            return "com.apple.coremedia"
        }
    }

    var process: String {
        "Music"
    }

    var predicate: NSPredicate {
        NSPredicate(format: "(subsystem = %@) AND (process = %@)", subsystem, process)
    }
}

struct ConsoleLogEntry: Sendable {
    let date: Date
    let message: String
    let type: ConsoleLogType
}

private extension String {
    nonisolated func substring(between start: String, and end: String) -> String? {
        guard let startRange = range(of: start) else {
            return nil
        }

        let searchRange = startRange.upperBound..<endIndex
        guard let endRange = range(of: end, range: searchRange) else {
            return nil
        }

        return String(self[startRange.upperBound..<endRange.lowerBound])
    }

    nonisolated func substring(after marker: String) -> String? {
        guard let markerRange = range(of: marker) else {
            return nil
        }

        return String(self[markerRange.upperBound...])
    }

    nonisolated var trimmedForNumber: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    }

    nonisolated var firstDouble: Double? {
        let scanner = Scanner(string: self)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;"))
        return scanner.scanDouble()
    }
}
