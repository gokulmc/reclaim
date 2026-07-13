import XCTest
@testable import ReclaimKit

final class CacheScannerTests: XCTestCase {
    private var homeDir: URL!

    override func setUpWithError() throws {
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-scanner-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let homeDir {
            try? FileManager.default.removeItem(at: homeDir)
        }
    }

    private func write(_ bytes: Int, at relativePath: String) throws {
        let url = homeDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    func testSingleDirectoryCacheIsFoundAndSized() throws {
        try write(10_000, at: ".npm/_cacache/content-v2/file1")
        try write(5_000, at: ".npm/_cacache/content-v2/file2")

        let catalog = [
            CacheDefinition(
                id: "npm",
                displayName: "npm cache",
                description: "Downloaded packages npm can re-fetch.",
                relativePaths: [".npm"],
                regenerates: true,
                expansion: .singleDirectory
            )
        ]

        let scanner = CacheScanner(home: homeDir.path)
        let results = scanner.scan(catalog)

        XCTAssertEqual(results.count, 1)
        let npm = try XCTUnwrap(results.first)
        XCTAssertEqual(npm.id, "npm")
        XCTAssertEqual(npm.definitionID, "npm")
        XCTAssertGreaterThanOrEqual(npm.sizeBytes, 15_000)
    }

    func testSingleDirectoryCacheWithMultipleRelativePathsSumsThem() throws {
        try write(4_000, at: "Library/pnpm/store/a")
        try write(6_000, at: ".local/share/pnpm/store/b")

        let catalog = [
            CacheDefinition(
                id: "pnpm",
                displayName: "pnpm store",
                description: "pnpm's content-addressable package store.",
                relativePaths: ["Library/pnpm/store", ".local/share/pnpm/store"],
                regenerates: true,
                expansion: .singleDirectory
            )
        ]

        let scanner = CacheScanner(home: homeDir.path)
        let results = scanner.scan(catalog)

        XCTAssertEqual(results.count, 1)
        let pnpm = try XCTUnwrap(results.first)
        XCTAssertEqual(pnpm.existingPaths.count, 2)
        XCTAssertGreaterThanOrEqual(pnpm.sizeBytes, 10_000)
    }

    func testAbsentCatalogEntryIsSkipped() throws {
        let catalog = [
            CacheDefinition(
                id: "gradle",
                displayName: "Gradle caches",
                description: "Downloaded dependencies Gradle can regenerate.",
                relativePaths: [".gradle/caches"],
                regenerates: true,
                expansion: .singleDirectory
            )
        ]

        let scanner = CacheScanner(home: homeDir.path)
        let results = scanner.scan(catalog)
        XCTAssertTrue(results.isEmpty)
    }

    func testPerAppChildrenFansOutOneScannedCachePerSubdirSortedBySizeDescending() throws {
        try write(30_000, at: "Library/Caches/com.small.app/data")
        try write(90_000, at: "Library/Caches/com.big.app/data")
        try write(60_000, at: "Library/Caches/com.medium.app/data")
        // A stray file directly inside Library/Caches (not a directory) must not become an item.
        try write(1_000, at: "Library/Caches/stray-file.txt")

        let catalog = [
            CacheDefinition(
                id: "library-caches",
                displayName: "App caches (~/Library/Caches)",
                description: "Per-app caches macOS apps rebuild on demand.",
                relativePaths: ["Library/Caches"],
                regenerates: true,
                expansion: .perAppChildren
            )
        ]

        let scanner = CacheScanner(home: homeDir.path)
        let results = scanner.scan(catalog)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.displayName), ["com.big.app", "com.medium.app", "com.small.app"])
        XCTAssertEqual(
            results.map(\.id),
            ["library-caches/com.big.app", "library-caches/com.medium.app", "library-caches/com.small.app"]
        )
        for result in results {
            XCTAssertEqual(result.definitionID, "library-caches")
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(results.first).sizeBytes, 90_000)
    }

    func testPerAppChildrenOnMissingRootReturnsEmpty() throws {
        let catalog = [
            CacheDefinition(
                id: "library-caches",
                displayName: "App caches (~/Library/Caches)",
                description: "Per-app caches macOS apps rebuild on demand.",
                relativePaths: ["Library/Caches"],
                regenerates: true,
                expansion: .perAppChildren
            )
        ]

        let scanner = CacheScanner(home: homeDir.path)
        XCTAssertTrue(scanner.scan(catalog).isEmpty)
    }

    func testReclaimableItemsProjectionIsSelectableCacheCategory() throws {
        try write(10_000, at: ".npm/file")

        let catalog = [
            CacheDefinition(
                id: "npm",
                displayName: "npm cache",
                description: "Downloaded packages npm can re-fetch.",
                relativePaths: [".npm"],
                regenerates: true,
                expansion: .singleDirectory
            )
        ]

        let scanner = CacheScanner(home: homeDir.path)
        let items = scanner.reclaimableItems(catalog)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "npm")
        XCTAssertEqual(item.category, .cache)
        XCTAssertTrue(item.isSelectable)
        XCTAssertFalse(item.isProtected)
        XCTAssertGreaterThanOrEqual(item.sizeBytes, 10_000)
    }

    func testScanNeverTouchesInjectedHomeOutsideCatalogPaths() throws {
        // A sentinel file outside any catalog path must survive scanning untouched — this is a
        // read-only engine, and the injected home guarantees no real cache is ever at risk.
        let sentinel = homeDir.appendingPathComponent("sentinel.txt")
        try Data("do-not-touch".utf8).write(to: sentinel)

        let scanner = CacheScanner(home: homeDir.path)
        _ = scanner.scan(CacheCatalog.default(home: homeDir.path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
