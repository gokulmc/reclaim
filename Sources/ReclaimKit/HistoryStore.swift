import Foundation

/// Which engine produced a `HistoryEntry`. Added in M3a alongside the dev-tool cache
/// subsystem; absent (`nil`) on every entry recorded before this milestone, since a Docker
/// clean was the only kind of run that could ever be appended.
public enum HistorySource: String, Codable, Equatable {
    case docker
    case caches
}

/// One recorded run, appended after every real (non-dry-run) `clean`.
///
/// Schema evolution (M3a, non-breaking): `backend` became optional and `source` /
/// `cachesReclaimed` were added so a dev-tool cache run (`CacheReclaimer`, which has no Docker
/// backend) can also be recorded here. `HistoryEntry` uses synthesized `Codable`, and every new
/// field is optional, so old `history.json` entries (which have `backend` but no `source`/
/// `cachesReclaimed` keys at all) still decode: the synthesized decoder uses
/// `decodeIfPresent` for optional stored properties, yielding `nil` for missing keys instead of
/// throwing. See `HistoryStoreTests` for a pinned old-format decode test.
public struct HistoryEntry: Codable, Equatable {
    public let date: Date
    /// `nil` for a dev-tool cache run (`source == .caches`) — there is no Docker backend to
    /// name in that case. Always non-nil for `source == .docker` (or `nil` `source`, i.e. an
    /// entry recorded before this field existed).
    public let backend: Backend?
    public let imagesReclaimed: Int64
    public let buildCacheReclaimed: Int64
    public let containersReclaimed: Int64
    public let trimmedBytes: Int64
    public let hostDelta: Int64
    /// `nil` on any entry recorded before M3a. Readers should treat `nil` as "Docker" (the only
    /// kind of run that existed at the time).
    public let source: HistorySource?
    /// Only set (and only meaningful) when `source == .caches`.
    public let cachesReclaimed: Int64?

    public init(
        date: Date,
        backend: Backend? = nil,
        imagesReclaimed: Int64,
        buildCacheReclaimed: Int64,
        containersReclaimed: Int64,
        trimmedBytes: Int64,
        hostDelta: Int64,
        source: HistorySource? = nil,
        cachesReclaimed: Int64? = nil
    ) {
        self.date = date
        self.backend = backend
        self.imagesReclaimed = imagesReclaimed
        self.buildCacheReclaimed = buildCacheReclaimed
        self.containersReclaimed = containersReclaimed
        self.trimmedBytes = trimmedBytes
        self.hostDelta = hostDelta
        self.source = source
        self.cachesReclaimed = cachesReclaimed
    }
}

/// Append-only JSON history log at
/// `~/Library/Application Support/Reclaim/history.json` (path is injectable for tests).
/// Used by the CLI `history` command and, later, the app's history section.
public struct HistoryStore {
    private let fileURL: URL

    public init(fileURL: URL = HistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Reclaim", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    public func load() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HistoryEntry].self, from: data)
    }

    @discardableResult
    public func append(_ entry: HistoryEntry) throws -> [HistoryEntry] {
        var entries = try load()
        entries.append(entry)
        try save(entries)
        return entries
    }

    private func save(_ entries: [HistoryEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
