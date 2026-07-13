import XCTest
@testable import ReclaimKit

final class HistoryStoreTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    override func tearDownWithError() throws {
        if let tempFile {
            try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent())
        }
    }

    func testLoadOnMissingFileReturnsEmpty() throws {
        let store = HistoryStore(fileURL: tempFile)
        XCTAssertEqual(try store.load(), [])
    }

    func testAppendThenLoadRoundTrips() throws {
        let store = HistoryStore(fileURL: tempFile)
        let entry1 = HistoryEntry(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            backend: .colima,
            imagesReclaimed: 2_680_000_000,
            buildCacheReclaimed: 34_350_000_000,
            containersReclaimed: 0,
            trimmedBytes: 53_456_729_292,
            hostDelta: 50_650_000_000
        )
        let entry2 = HistoryEntry(
            date: Date(timeIntervalSince1970: 1_800_100_000),
            backend: .orbstack,
            imagesReclaimed: 100,
            buildCacheReclaimed: 200,
            containersReclaimed: 300,
            trimmedBytes: 0,
            hostDelta: 600
        )

        try store.append(entry1)
        try store.append(entry2)

        let loaded = try store.load()
        XCTAssertEqual(loaded, [entry1, entry2])
    }

    func testAppendCreatesIntermediateDirectories() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.deletingLastPathComponent().path))
        let store = HistoryStore(fileURL: tempFile)
        try store.append(HistoryEntry(
            date: Date(),
            backend: .dockerDesktop,
            imagesReclaimed: 1,
            buildCacheReclaimed: 2,
            containersReclaimed: 3,
            trimmedBytes: 4,
            hostDelta: 5
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))
    }

    // MARK: - M3a schema evolution: backend optional, `source`/`cachesReclaimed` added

    /// Pinned literal mirroring a real pre-M3a `history.json` entry: `backend` present, and no
    /// `source`/`cachesReclaimed` keys at all (those fields didn't exist yet). `HistoryEntry`
    /// uses synthesized `Codable`, so the decoder must use `decodeIfPresent` for these optional
    /// fields and yield `nil` for the missing keys rather than throwing.
    func testDecodesPinnedOldFormatJSONMissingSourceAndCachesReclaimed() throws {
        let oldFormatJSON = """
        [
          {
            "date": "2026-01-01T00:00:00Z",
            "backend": "colima",
            "imagesReclaimed": 2680000000,
            "buildCacheReclaimed": 34350000000,
            "containersReclaimed": 0,
            "trimmedBytes": 53456729292,
            "hostDelta": 50650000000
          }
        ]
        """
        try FileManager.default.createDirectory(
            at: tempFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try oldFormatJSON.write(to: tempFile, atomically: true, encoding: .utf8)

        let store = HistoryStore(fileURL: tempFile)
        let loaded = try store.load()

        XCTAssertEqual(loaded.count, 1)
        let entry = try XCTUnwrap(loaded.first)
        XCTAssertEqual(entry.backend, .colima)
        XCTAssertNil(entry.source, "an entry recorded before M3a has no source")
        XCTAssertNil(entry.cachesReclaimed)
        XCTAssertEqual(entry.imagesReclaimed, 2_680_000_000)
        XCTAssertEqual(entry.hostDelta, 50_650_000_000)
    }

    /// A new-format cache entry (`backend: nil`, `source: .caches`, `cachesReclaimed` set) must
    /// round-trip through encode/decode unchanged.
    func testNewCacheEntryRoundTrips() throws {
        let store = HistoryStore(fileURL: tempFile)
        let entry = HistoryEntry(
            date: Date(timeIntervalSince1970: 1_800_200_000),
            backend: nil,
            imagesReclaimed: 0,
            buildCacheReclaimed: 0,
            containersReclaimed: 0,
            trimmedBytes: 0,
            hostDelta: 123,
            source: .caches,
            cachesReclaimed: 123
        )

        try store.append(entry)
        let loaded = try store.load()

        XCTAssertEqual(loaded, [entry])
        XCTAssertNil(loaded.first?.backend)
        XCTAssertEqual(loaded.first?.source, .caches)
        XCTAssertEqual(loaded.first?.cachesReclaimed, 123)
    }
}
