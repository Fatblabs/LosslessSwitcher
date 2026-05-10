import Foundation

struct CachedTrackFormat: Codable, Hashable, Sendable {
    let key: String
    let title: String
    let artist: String
    let album: String
    let sampleRate: Double
    let bitDepth: Int?
    let source: String
    let updatedAt: Date

    var detectedFormat: DetectedAudioFormat {
        DetectedAudioFormat(
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            source: "Cached format",
            date: Date()
        )
    }
}

final class TrackFormatCache {
    private let maximumEntryCount = 10_000
    private let fileURL: URL
    private var entries: [String: CachedTrackFormat] = [:]

    init() {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("LosslessSwitcher", isDirectory: true)

        fileURL = supportDirectory.appendingPathComponent("track-format-cache.json")
        load()
    }

    var count: Int {
        entries.count
    }

    func format(for source: DetectedAudioSource) -> DetectedAudioFormat? {
        guard let key = source.cacheKey,
              let entry = entries[key] else {
            return nil
        }

        return entry.detectedFormat
    }

    @discardableResult
    func store(_ source: DetectedAudioSource) -> Bool {
        guard let nextEntry = cacheEntry(for: source) else {
            return false
        }

        let changed = upsert(nextEntry)
        if changed {
            pruneIfNeeded()
            save()
        }

        return changed
    }

    @discardableResult
    func storeAll(_ sources: [DetectedAudioSource]) -> Int {
        var changedCount = 0

        for source in sources {
            guard let nextEntry = cacheEntry(for: source) else {
                continue
            }

            if upsert(nextEntry) {
                changedCount += 1
            }
        }

        if changedCount > 0 {
            pruneIfNeeded()
            save()
        }

        return changedCount
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func cacheEntry(for source: DetectedAudioSource) -> CachedTrackFormat? {
        guard source.isSampleRateReliable,
              source.formatSource != "Cached format",
              source.sampleRate > 0,
              let key = source.cacheKey else {
            return nil
        }

        return CachedTrackFormat(
            key: key,
            title: source.displayTitle,
            artist: source.displayArtist,
            album: source.album,
            sampleRate: source.sampleRate,
            bitDepth: source.bitDepth,
            source: source.formatSource,
            updatedAt: Date()
        )
    }

    private func upsert(_ nextEntry: CachedTrackFormat) -> Bool {
        if let existingEntry = entries[nextEntry.key],
           existingEntry.title == nextEntry.title,
           existingEntry.artist == nextEntry.artist,
           existingEntry.album == nextEntry.album,
           abs(existingEntry.sampleRate - nextEntry.sampleRate) < 0.5,
           existingEntry.bitDepth == nextEntry.bitDepth {
            return false
        }

        entries[nextEntry.key] = nextEntry
        return true
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decodedEntries = try? JSONDecoder().decode([String: CachedTrackFormat].self, from: data) else {
            return
        }

        entries = decodedEntries
        pruneIfNeeded()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache writes are an optimization; playback switching should not fail if persistence does.
        }
    }

    private func pruneIfNeeded() {
        guard entries.count > maximumEntryCount else {
            return
        }

        let keysToRemove = entries.values
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(entries.count - maximumEntryCount)
            .map(\.key)

        keysToRemove.forEach { entries.removeValue(forKey: $0) }
    }
}
