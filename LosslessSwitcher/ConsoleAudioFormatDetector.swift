import Foundation
import OSLog

struct DetectedAudioFormat: Hashable, Sendable {
    let sampleRate: Double
    let bitDepth: Int?
    let source: String
    let date: Date
}

nonisolated final class ConsoleAudioFormatDetector: @unchecked Sendable {
    private let predicate = NSPredicate(
        format: "(subsystem = %@) AND (process = %@)",
        "com.apple.coreaudio",
        "Music"
    )

    func detectRecentFormat(
        lookback: TimeInterval = 8,
        after minimumDate: Date? = nil
    ) throws -> DetectedAudioFormat? {
        let store = try OSLogStore.local()
        let position = store.position(timeIntervalSinceEnd: -lookback)

        return try store
            .getEntries(at: position, matching: predicate)
            .compactMap { ($0 as? OSLogEntryLog).flatMap(ConsoleAudioFormatParser.parse) }
            .filter { format in
                guard let minimumDate else {
                    return true
                }

                return format.date >= minimumDate
            }
            .sorted { $0.date > $1.date }
            .first
    }
}

nonisolated final class ConsoleAudioFormatStreamProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LosslessSwitcher.ConsoleAudioFormatStreamProbe", qos: .utility)
    private let condition = NSCondition()
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var latestFormat: DetectedAudioFormat?
    private var latestError: String?
    private var isStopping = false

    func start() -> String? {
        queue.sync {
            startLocked()
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    func reset() {
        condition.lock()
        latestFormat = nil
        condition.unlock()
    }

    func waitForFormat(after minimumDate: Date, timeout: TimeInterval) -> DetectedAudioFormat? {
        let deadline = Date().addingTimeInterval(timeout)
        let coreAudioGracePeriod: TimeInterval = 1.2
        var fallbackFormat: DetectedAudioFormat?
        var fallbackDeadline: Date?

        condition.lock()
        defer {
            condition.unlock()
        }

        while Date() < deadline {
            if let latestFormat,
               latestFormat.date >= minimumDate {
                if latestFormat.source == "CoreAudio decoder" {
                    return latestFormat
                }

                fallbackFormat = latestFormat
                fallbackDeadline = Date().addingTimeInterval(coreAudioGracePeriod)
                self.latestFormat = nil
            }

            if let fallbackFormat,
               let fallbackDeadline,
               Date() >= fallbackDeadline {
                return fallbackFormat
            }

            let waitDeadline = [deadline, fallbackDeadline]
                .compactMap { $0 }
                .min() ?? deadline
            condition.wait(until: waitDeadline)
        }

        if let latestFormat,
           latestFormat.date >= minimumDate,
           latestFormat.source == "CoreAudio decoder" {
            return latestFormat
        }

        return fallbackFormat
    }

    var errorMessage: String? {
        condition.lock()
        defer {
            condition.unlock()
        }

        return latestError
    }

    private func startLocked() -> String? {
        guard process == nil else {
            return nil
        }

        isStopping = false
        latestError = nil

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style",
            "compact",
            "--level",
            "info",
            "--predicate",
            """
            (process == "Music") AND (\
            ((subsystem == "com.apple.coreaudio") AND (eventMessage CONTAINS[c] "ACAppleLosslessDecoder.cpp") AND (eventMessage CONTAINS[c] "Input format:")) OR \
            ((subsystem == "com.apple.coremedia") AND (eventMessage CONTAINS[c] "Creating AudioQueue") AND (eventMessage CONTAINS[c] "sampleRate:"))\
            )
            """
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                self?.consumeOutput(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                self?.consumeError(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                self?.process = nil
                self?.outputPipe = nil
                self?.errorPipe = nil
                self?.signalWaiters()

                if self?.isStopping == false, process.terminationStatus != 0 {
                    self?.recordError("Live probe exited with status \(process.terminationStatus)")
                }

                self?.isStopping = false
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            return nil
        } catch {
            recordError(error.localizedDescription)
            return error.localizedDescription
        }
    }

    private func stopLocked() {
        guard process != nil else {
            return
        }

        isStopping = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
        errorPipe = nil
        buffer.removeAll(keepingCapacity: false)
        signalWaiters()
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 10) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)

            guard let line = String(data: lineData, encoding: .utf8),
                  let format = ConsoleAudioFormatParser.parseStreamLine(line) else {
                continue
            }

            condition.lock()
            latestFormat = format
            condition.broadcast()
            condition.unlock()
        }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty,
              let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty,
              !message.localizedCaseInsensitiveContains("filtering the log data") else {
            return
        }

        recordError(message)
    }

    private func recordError(_ message: String) {
        condition.lock()
        latestError = message
        condition.broadcast()
        condition.unlock()
    }

    private func signalWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
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
        if message.contains("ACAppleLosslessDecoder.cpp"),
           message.contains("Input format:"),
           let sampleRateText = message.substring(between: "ch, ", and: " Hz"),
           let sampleRate = Double(sampleRateText.trimmedForNumber) {
            return DetectedAudioFormat(
                sampleRate: sampleRate,
                bitDepth: message
                    .substring(between: "from ", and: "-bit source")
                    .flatMap { Int($0.trimmedForNumber) },
                source: "CoreAudio decoder",
                date: date
            )
        }

        if message.contains("Creating AudioQueue"),
           let sampleRateText = message.substring(after: "sampleRate:")?.trimmedForNumber.leadingNumberToken,
           let sampleRate = Double(sampleRateText),
           sampleRate > 0 {
            return DetectedAudioFormat(
                sampleRate: sampleRate,
                bitDepth: nil,
                source: "CoreMedia AudioQueue",
                date: date
            )
        }

        return nil
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

    nonisolated func substring(after start: String) -> String? {
        guard let startRange = range(of: start) else {
            return nil
        }

        return String(self[startRange.upperBound...])
    }

    nonisolated var leadingNumberToken: String {
        let scalars = unicodeScalars.prefix { scalar in
            CharacterSet.decimalDigits.contains(scalar) || scalar.value == 46
        }

        return String(String.UnicodeScalarView(scalars))
    }
}
