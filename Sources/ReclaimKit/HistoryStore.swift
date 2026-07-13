import Foundation

/// One recorded run, appended after every real (non-dry-run) `clean`.
public struct HistoryEntry: Codable, Equatable {
    public let date: Date
    public let backend: Backend
    public let imagesReclaimed: Int64
    public let buildCacheReclaimed: Int64
    public let containersReclaimed: Int64
    public let trimmedBytes: Int64
    public let hostDelta: Int64

    public init(
        date: Date,
        backend: Backend,
        imagesReclaimed: Int64,
        buildCacheReclaimed: Int64,
        containersReclaimed: Int64,
        trimmedBytes: Int64,
        hostDelta: Int64
    ) {
        self.date = date
        self.backend = backend
        self.imagesReclaimed = imagesReclaimed
        self.buildCacheReclaimed = buildCacheReclaimed
        self.containersReclaimed = containersReclaimed
        self.trimmedBytes = trimmedBytes
        self.hostDelta = hostDelta
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
