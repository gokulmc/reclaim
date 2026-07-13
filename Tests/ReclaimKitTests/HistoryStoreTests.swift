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
}
