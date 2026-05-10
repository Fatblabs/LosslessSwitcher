import Foundation

nonisolated final class LiveConsoleAudioFormatMonitor: @unchecked Sendable {
    var onFormat: (@Sendable (DetectedAudioFormat) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "LosslessSwitcher.LiveConsoleAudioFormatMonitor", qos: .utility)
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var lastFormatSignature: String?
    private var lastError: String?
    private var isStopping = false

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func startLocked() {
        guard process == nil else {
            return
        }

        isStopping = false
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
            (process == "Music") AND (subsystem == "com.apple.coreaudio") AND (eventMessage CONTAINS[c] "ACAppleLosslessDecoder.cpp") AND (eventMessage CONTAINS[c] "Input format:")
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

                if self?.isStopping == false, process.terminationStatus != 0 {
                    self?.reportError("Live log monitor exited with status \(process.terminationStatus)")
                }

                self?.isStopping = false
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
        } catch {
            reportError(error.localizedDescription)
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
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 10) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)

            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }

            handleLine(line)
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

        reportError(message)
    }

    private func handleLine(_ line: String) {
        guard let format = ConsoleAudioFormatParser.parseStreamLine(line) else {
            return
        }

        let signature = "\(Int(format.sampleRate.rounded()))-\(format.bitDepth ?? 0)-\(format.source)"
        guard signature != lastFormatSignature else {
            return
        }

        lastFormatSignature = signature
        onFormat?(format)
    }

    private func reportError(_ message: String) {
        guard message != lastError else {
            return
        }

        lastError = message
        onError?(message)
    }
}
