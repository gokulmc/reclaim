import XCTest
@testable import ReclaimKit

/// `FileTrasher` is the only move-to-Trash call site in `Sources/`. Every test here operates
/// against a fake `home` under `FileManager.default.temporaryDirectory` — mirroring
/// `CacheDeleterTests`' pattern — so no real user file is ever at risk. The one test that
/// exercises the real move-to-Trash call (`c`) creates its own throwaway fixture and cleans up
/// after itself so the real `~/.Trash` is left exactly as it found it.
final class FileTrasherTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-file-trasher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    private var home: String { tempHome.path }

    private func makeFileItem(relativePath: String, bytes: Int) throws -> LargeItem {
        let url = tempHome.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return LargeItem(
            id: url.resolvingSymlinksInPath().standardizedFileURL.path,
            url: url,
            path: url.path,
            sizeBytes: Int64(bytes),
            isDirectory: false,
            isProtected: false
        )
    }

    // MARK: (a) dryRun

    func testDryRunLeavesFileInPlaceAndReportsNoTrashedPath() throws {
        let item = try makeFileItem(relativePath: "big-file.bin", bytes: 4096)
        let trasher = FileTrasher(home: home)

        let result = try trasher.trash(item, dryRun: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path), "dryRun must not move anything")
        XCTAssertGreaterThan(result.bytesBefore, 0)
        XCTAssertNil(result.trashedPath)
        XCTAssertEqual(result.path, item.url.path)
    }

    // MARK: (b) guard-reject

    func testGuardRejectionLeavesFileUntouched() throws {
        // "Documents" is a protected personal-folder ROOT (rejected on exact equality) —
        // pointing an item directly at it (not a child inside it) must be blocked.
        let documentsURL = tempHome.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 16).write(to: documentsURL.appendingPathComponent("marker.txt"))

        let item = LargeItem(
            id: documentsURL.resolvingSymlinksInPath().standardizedFileURL.path,
            url: documentsURL,
            path: documentsURL.path,
            sizeBytes: 16,
            isDirectory: true,
            isProtected: true
        )
        let trasher = FileTrasher(home: home)

        XCTAssertThrowsError(try trasher.trash(item, dryRun: false)) { error in
            XCTAssertTrue(error is FileTrashGuard.Violation)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsURL.path), "a rejected trash must leave the target untouched")
    }

    // MARK: (c) real trashItem, self-cleaning

    func testRealTrashMovesFileAndSelfCleansTrash() throws {
        let item = try makeFileItem(
            relativePath: "reclaim-trasher-test-\(UUID().uuidString).bin",
            bytes: 2048
        )
        let trasher = FileTrasher(home: home)

        let result = try trasher.trash(item, dryRun: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path), "real trash must move the original away")

        guard let trashedPath = result.trashedPath else {
            throw XCTSkip("no Trash available on this runner — cannot verify real trashItem behavior")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedPath))

        // Clean up the copy real trashItem left in ~/.Trash so this test leaves no residue —
        // this removeItem lives in Tests/, which the isolation gate never scans.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: trashedPath))
    }
}
