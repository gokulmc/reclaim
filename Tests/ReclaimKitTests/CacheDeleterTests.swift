import XCTest
@testable import ReclaimKit

/// `CacheDeleter` is the only `FileManager.removeItem` call site in `Sources/`. Every test
/// here operates against a fake `home` under `FileManager.default.temporaryDirectory` — the
/// injected `home` guarantees no real cache is ever touched, mirroring `HistoryStoreTests`'
/// plain-temp-dir pattern.
final class CacheDeleterTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-cache-deleter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    private var home: String { tempHome.path }

    private var fakeCatalog: [CacheDefinition] {
        [
            CacheDefinition(
                id: "npm",
                displayName: "npm cache",
                description: "test fixture mirroring the real npm catalog entry",
                relativePaths: [".npm"],
                regenerates: true,
                expansion: .singleDirectory
            )
        ]
    }

    /// Populates `home/.npm/_cacache/x` (and `y`) with known-size files and returns the
    /// `ScannedCache` a real `CacheScanner` would have produced for the npm catalog entry.
    @discardableResult
    private func makeNpmCache() throws -> ScannedCache {
        let cacacheDir = tempHome.appendingPathComponent(".npm/_cacache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacacheDir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: cacacheDir.appendingPathComponent("x"))
        try Data(repeating: 0x42, count: 2048).write(to: cacacheDir.appendingPathComponent("y"))

        let root = tempHome.appendingPathComponent(".npm", isDirectory: true)
        return ScannedCache(
            id: "npm",
            definitionID: "npm",
            displayName: "npm cache",
            existingPaths: [root],
            sizeBytes: DirectorySizer.size(of: root),
            regenerates: true
        )
    }

    // MARK: (a) dryRun

    func testDryRunLeavesFilesInPlaceAndReportsWouldBeRemovedBytes() throws {
        let scanned = try makeNpmCache()
        let allowedRoots = CacheDeleter.allowedRoots(for: fakeCatalog, home: home)
        let deleter = CacheDeleter(home: home)

        let result = try deleter.delete(scanned, allowedRoots: allowedRoots, dryRun: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: scanned.existingPaths[0].path), "dryRun must not remove anything")
        XCTAssertGreaterThan(result.bytesBefore, 0)
        XCTAssertEqual(result.bytesBefore, DirectorySizer.size(of: scanned.existingPaths[0]))
        XCTAssertEqual(result.removedPaths, scanned.existingPaths.map(\.path))
        XCTAssertEqual(result.definitionID, "npm")
    }

    // MARK: (b) real delete

    func testRealDeleteRemovesFilesAndBytesBeforeMatchesDirectorySizer() throws {
        let scanned = try makeNpmCache()
        let expectedBytes = DirectorySizer.size(of: scanned.existingPaths[0])
        XCTAssertGreaterThan(expectedBytes, 0, "fixture sanity check")

        let allowedRoots = CacheDeleter.allowedRoots(for: fakeCatalog, home: home)
        let deleter = CacheDeleter(home: home)

        let result = try deleter.delete(scanned, allowedRoots: allowedRoots, dryRun: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: scanned.existingPaths[0].path), "real delete must remove the directory")
        XCTAssertEqual(result.bytesBefore, expectedBytes)
        XCTAssertEqual(result.removedPaths, scanned.existingPaths.map(\.path))
    }

    // MARK: (c) outside allowedRoots

    func testPathOutsideAllowedRootsThrowsAndRemovesNothing() throws {
        let scanned = try makeNpmCache()
        let deleter = CacheDeleter(home: home)

        // Empty allowedRoots — the npm directory is not within any known catalog root, so the
        // safety guard must reject it before anything is removed.
        XCTAssertThrowsError(try deleter.delete(scanned, allowedRoots: [], dryRun: false)) { error in
            XCTAssertTrue(error is CacheSafetyGuard.Violation)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: scanned.existingPaths[0].path), "a rejected delete must leave files untouched")
    }
}
