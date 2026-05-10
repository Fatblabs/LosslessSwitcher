import Foundation
import OSLog

struct DetectedAudioFormat: Hashable, Sendable {
    let sampleRate: Double
    let bitDepth: Int?
    let source: String
    let date: Date
}

final class ConsoleAudioFormatDetector: Sendable {
    private let predicate = NSPredicate(
        format: "(subsystem = %@) AND (process = %@)",
        "com.apple.coreaudio",
        "Music"
    )

    func detectRecentFormat(lookback: TimeInterval = 8) throws -> DetectedAudioFormat? {
        let store = try OSLogStore.local()
        let position = store.position(timeIntervalSinceEnd: -lookback)

        return try store
            .getEntries(at: position, matching: predicate)
            .compactMap { ($0 as? OSLogEntryLog).flatMap(ConsoleAudioFormatParser.parse) }
            .sorted { $0.date > $1.date }
            .first
    }
}

nonisolated enum ConsoleAudioFormatParser {
    static func parse(_ entry: OSLogEntryLog) -> DetectedAudioFormat? {
        parse(message: entry.composedMessage, date: entry.date)
    }

    static func parseStreamLine(_ line: String, date: Date = Date()) -> DetectedAudioFormat? {
        parse(message: line, date: date)
    }

    private static func parse(message: String, date: Date) -> DetectedAudioFormat? {
        guard message.contains("ACAppleLosslessDecoder.cpp"),
              message.contains("Input format:"),
              let sampleRateText = message.substring(between: "ch, ", and: " Hz"),
              let sampleRate = Double(sampleRateText.trimmedForNumber) else {
            return nil
        }

        return DetectedAudioFormat(
            sampleRate: sampleRate,
            bitDepth: message
                .substring(between: "from ", and: "-bit source")
                .flatMap { Int($0.trimmedForNumber) },
            source: "CoreAudio decoder",
            date: date
        )
    }
}

private extension String {
    nonisolated func substring(between start: String, and end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            return nil
        }

        return String(self[startRange.upperBound..<endRange.lowerBound])
    }

    nonisolated var trimmedForNumber: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    }
}
