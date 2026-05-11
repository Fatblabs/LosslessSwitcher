import AudioToolbox
import CoreAudio
import Foundation

enum CoreAudioDeviceError: LocalizedError {
    case propertyUnavailable(String)
    case commandFailed(String, OSStatus)
    case unsupportedSampleRate(Double, String)
    case outputDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .propertyUnavailable(let property):
            return "\(property) is not available."
        case .commandFailed(let command, let status):
            return "\(command) failed (\(status.audioErrorDescription))."
        case .unsupportedSampleRate(let sampleRate, let deviceName):
            return "\(deviceName) does not report support for \(sampleRateLabel(sampleRate))."
        case .outputDeviceUnavailable:
            return "No default output device is available."
        }
    }
}

final class CoreAudioDeviceManager {
    func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceID
            ),
            "Read default output device"
        )

        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioDeviceError.outputDeviceUnavailable
        }

        return deviceID
    }

    func outputDevices() throws -> [AudioDevice] {
        let defaultDeviceID = try? defaultOutputDeviceID()
        let deviceIDs = try allDeviceIDs()
        var devices: [AudioDevice] = []

        for deviceID in deviceIDs {
            if let device = audioDevice(for: deviceID, defaultDeviceID: defaultDeviceID) {
                devices.append(device)
            }
        }

        return devices.sorted {
            if $0.isDefaultOutput != $1.isDefaultOutput {
                return $0.isDefaultOutput
            }

            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func defaultOutputDevice() throws -> AudioDevice {
        let defaultID = try defaultOutputDeviceID()
        guard let device = audioDevice(for: defaultID, defaultDeviceID: defaultID) else {
            throw CoreAudioDeviceError.outputDeviceUnavailable
        }

        return device
    }

    func apply(sampleRate: Double, preferredBitDepth: Int?) throws -> Bool {
        let device = try defaultOutputDevice()
        guard device.supports(sampleRate: sampleRate) else {
            throw CoreAudioDeviceError.unsupportedSampleRate(sampleRate, device.name)
        }

        var changed = false
        if abs(device.currentSampleRate - sampleRate) > 0.5 {
            try setNominalSampleRate(sampleRate, for: device.id)
            changed = true
        }

        if let preferredBitDepth {
            let formatChanged = try setBestOutputPhysicalFormat(
                sampleRate: sampleRate,
                preferredBitDepth: preferredBitDepth,
                for: device.id
            )
            changed = changed || formatChanged
        }

        return changed
    }

    func setNominalSampleRate(_ sampleRate: Double, for deviceID: AudioObjectID) throws {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)

        guard AudioObjectHasProperty(deviceID, &address) else {
            throw CoreAudioDeviceError.propertyUnavailable("Nominal sample rate")
        }

        var settable = DarwinBoolean(false)
        try check(AudioObjectIsPropertySettable(deviceID, &address, &settable), "Check sample-rate access")
        guard settable.boolValue else {
            throw CoreAudioDeviceError.propertyUnavailable("Nominal sample rate is read-only")
        }

        var target = Float64(sampleRate)
        try check(
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                &target
            ),
            "Set nominal sample rate"
        )
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func allDeviceIDs() throws -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)

        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            "Read device list size"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var deviceIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceIDs
            ),
            "Read device list"
        )

        return deviceIDs
    }

    private func audioDevice(
        for deviceID: AudioObjectID,
        defaultDeviceID: AudioObjectID?
    ) -> AudioDevice? {
        let streamIDs = (try? outputStreamIDs(for: deviceID)) ?? []
        guard !streamIDs.isEmpty else {
            return nil
        }

        let name = (try? stringProperty(
            objectID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        )) ?? "Unknown Output"
        let currentRate = (try? nominalSampleRate(for: deviceID)) ?? 0
        let currentBitDepth = currentOutputBitDepth(for: streamIDs)
        let sampleRates = (try? availableNominalSampleRates(for: deviceID)) ?? []

        return AudioDevice(
            id: deviceID,
            name: name,
            isDefaultOutput: deviceID == defaultDeviceID,
            currentSampleRate: currentRate,
            currentBitDepth: currentBitDepth,
            supportedSampleRates: sampleRates
        )
    }

    private func outputStreamIDs(for deviceID: AudioObjectID) throws -> [AudioObjectID] {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)

        guard AudioObjectHasProperty(deviceID, &address) else {
            return []
        }

        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            "Read output stream list size"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else {
            return []
        }

        var streamIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &streamIDs),
            "Read output stream list"
        )

        return streamIDs
    }

    private func nominalSampleRate(for deviceID: AudioObjectID) throws -> Double {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)

        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate),
            "Read nominal sample rate"
        )

        return Double(sampleRate)
    }

    private func availableNominalSampleRates(for deviceID: AudioObjectID) throws -> [AudioSampleRateRange] {
        var address = propertyAddress(kAudioDevicePropertyAvailableNominalSampleRates)

        guard AudioObjectHasProperty(deviceID, &address) else {
            return []
        }

        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            "Read supported sample-rate size"
        )

        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.stride
        guard count > 0 else {
            return []
        }

        var ranges = Array(repeating: AudioValueRange(), count: count)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &ranges),
            "Read supported sample rates"
        )

        return ranges
            .map { AudioSampleRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum) }
            .sorted { $0.minimum < $1.minimum }
    }

    private func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> String {
        var address = propertyAddress(selector, scope: scope)

        guard AudioObjectHasProperty(objectID, &address) else {
            throw CoreAudioDeviceError.propertyUnavailable("String property")
        }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        try check(status, "Read audio object string")

        return value?.takeRetainedValue() as String? ?? ""
    }

    private func currentOutputBitDepth(for streamIDs: [AudioObjectID]) -> Int? {
        for streamID in streamIDs {
            if let format = try? physicalFormat(for: streamID), format.mBitsPerChannel > 0 {
                return Int(format.mBitsPerChannel)
            }
        }

        return nil
    }

    private func physicalFormat(for streamID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(kAudioStreamPropertyPhysicalFormat)

        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &format),
            "Read stream physical format"
        )

        return format
    }

    private func availablePhysicalFormats(for streamID: AudioObjectID) throws -> [AudioStreamRangedDescription] {
        var address = propertyAddress(kAudioStreamPropertyAvailablePhysicalFormats)

        guard AudioObjectHasProperty(streamID, &address) else {
            return []
        }

        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize),
            "Read stream format list size"
        )

        let count = Int(dataSize) / MemoryLayout<AudioStreamRangedDescription>.stride
        guard count > 0 else {
            return []
        }

        var descriptions = Array(repeating: AudioStreamRangedDescription(), count: count)
        try check(
            AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &descriptions),
            "Read stream format list"
        )

        return descriptions
    }

    private func setBestOutputPhysicalFormat(
        sampleRate: Double,
        preferredBitDepth: Int,
        for deviceID: AudioObjectID
    ) throws -> Bool {
        var changed = false

        for streamID in try outputStreamIDs(for: deviceID) {
            var address = propertyAddress(kAudioStreamPropertyPhysicalFormat)

            guard AudioObjectHasProperty(streamID, &address) else {
                continue
            }

            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(streamID, &address, &settable) == noErr,
                  settable.boolValue else {
                continue
            }

            let current = try? physicalFormat(for: streamID)
            guard let selected = bestPhysicalFormat(
                from: try availablePhysicalFormats(for: streamID),
                sampleRate: sampleRate,
                preferredBitDepth: preferredBitDepth,
                currentFormat: current
            ) else {
                continue
            }

            var target = selected.mFormat
            target.mSampleRate = sampleRate

            if let current,
               abs(current.mSampleRate - target.mSampleRate) < 0.5,
               current.mBitsPerChannel == target.mBitsPerChannel,
               current.mFormatID == target.mFormatID,
               current.mFormatFlags == target.mFormatFlags {
                continue
            }

            try check(
                AudioObjectSetPropertyData(
                    streamID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                    &target
                ),
                "Set stream physical format"
            )
            changed = true
        }

        return changed
    }

    private func bestPhysicalFormat(
        from descriptions: [AudioStreamRangedDescription],
        sampleRate: Double,
        preferredBitDepth: Int,
        currentFormat: AudioStreamBasicDescription?
    ) -> AudioStreamRangedDescription? {
        let candidates = descriptions.filter { description in
            let format = description.mFormat
            let rateMatches = description.mSampleRateRange.contains(sampleRate)
                || abs(format.mSampleRate - sampleRate) < 0.5

            return rateMatches
                && format.mFormatID == kAudioFormatLinearPCM
                && format.mBitsPerChannel > 0
        }

        return candidates.max { lhs, rhs in
            score(
                lhs,
                sampleRate: sampleRate,
                preferredBitDepth: preferredBitDepth,
                currentFormat: currentFormat
            ) < score(
                rhs,
                sampleRate: sampleRate,
                preferredBitDepth: preferredBitDepth,
                currentFormat: currentFormat
            )
        }
    }

    private func score(
        _ description: AudioStreamRangedDescription,
        sampleRate: Double,
        preferredBitDepth: Int,
        currentFormat: AudioStreamBasicDescription?
    ) -> Int {
        let format = description.mFormat
        var score = 0

        if abs(format.mSampleRate - sampleRate) < 0.5 {
            score += 10_000
        }

        let bits = Int(format.mBitsPerChannel)
        if bits == preferredBitDepth {
            score += 5_000
        } else if bits > preferredBitDepth {
            score += 3_000 - min(bits - preferredBitDepth, 256)
        } else {
            score += max(0, 1_000 - (preferredBitDepth - bits))
        }

        if (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 {
            score += 500
        }

        if let currentFormat {
            if format.mChannelsPerFrame == currentFormat.mChannelsPerFrame {
                score += 250
            }

            if format.mFormatFlags == currentFormat.mFormatFlags {
                score += 100
            }
        }

        return score
    }

    private func check(_ status: OSStatus, _ command: String) throws {
        guard status == noErr else {
            throw CoreAudioDeviceError.commandFailed(command, status)
        }
    }
}

private extension AudioValueRange {
    func contains(_ value: Double) -> Bool {
        value >= mMinimum - 0.5 && value <= mMaximum + 0.5
    }
}

private extension OSStatus {
    var audioErrorDescription: String {
        let bigEndian = UInt32(bitPattern: self).bigEndian
        let text = [
            UInt8((bigEndian >> 24) & 0xff),
            UInt8((bigEndian >> 16) & 0xff),
            UInt8((bigEndian >> 8) & 0xff),
            UInt8(bigEndian & 0xff)
        ]

        if text.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(bytes: text, encoding: .macOSRoman) ?? "\(self)")'"
        }

        return "\(self)"
    }
}
