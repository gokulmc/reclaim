import XCTest
@testable import ReclaimKit

/// `LargeItemScanner` is entirely read-only — these tests pin its ranking, threshold, symlink,
/// opaque-bundle, exclusion, and protection-stamping behavior against a fake `home` under
/// `FileManager.default.temporaryDirectory`. Never a real user path, and no fixture here is
/// ever deleted or moved — this milestone ships no deletion at all.
final class LargeItemScannerTests: XCTestCase {
    private var homeDir: URL!

    override func setUpWithError() throws {
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-large-scanner-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let homeDir {
            try? FileManager.default.removeItem(at: homeDir)
        }
    }

    @discardableResult
    private func write(_ bytes: Int, at relativePath: String) throws -> URL {
        let url = homeDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    /// Small thresholds so fixtures can be tens of KB instead of the real 100MB/250MB defaults.
    /// Chosen with a wide margin over on-disk block rounding: `DirectorySizer`'s "allocated"
    /// size is block-rounded (typically a 4KB block on APFS), so a handful of tiny fixture
    /// bytes can still allocate a full block. `fileThresholdBytes`/`folderThresholdBytes` sit
    /// far enough above that rounding floor that "sub-threshold" fixtures stay clearly under
    /// and "above-threshold" fixtures stay clearly over, regardless of the underlying block
    /// size.
    private func testConfiguration() -> LargeItemScanner.Configuration {
        LargeItemScanner.Configuration(
            fileThresholdBytes: 50_000,
            folderThresholdBytes: 100_000,
            folderRankMaxDepth: 2,
            maxFileCandidates: 50,
            maxFolderCandidates: 50,
            excludedRelativePaths: [".Trash", "Library/Application Support/Reclaim"],
            opaqueBundleExtensions: [
                "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                "framework", "bundle", "xcappdata"
            ]
        )
    }

    // MARK: - Ranking

    func testRankingMergesFilesAndFoldersSizeDescending() async throws {
        try write(200_000, at: "big-file.bin")
        try write(120_000, at: "folder-a/inner1.bin")
        try write(120_000, at: "folder-a/inner2.bin")

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let result = await scanner.scan()

        let sizes = result.items.map(\.sizeBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "items must be merged and sorted size-descending")

        XCTAssertTrue(result.items.contains { $0.path.hasSuffix("big-file.bin") && $0.sizeBytes >= 200_000 })
        let folderItem = try XCTUnwrap(result.items.first { $0.path.hasSuffix("folder-a") })
        XCTAssertTrue(folderItem.isDirectory)
        XCTAssertGreaterThanOrEqual(folderItem.sizeBytes, 240_000)
    }

    // MARK: - Threshold filtering

    func testSubThresholdFileIsExcluded() async throws {
        try write(100, at: "tiny.bin")

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let result = await scanner.scan()

        XCTAssertFalse(result.items.contains { $0.path.hasSuffix("tiny.bin") })
    }

    func testSubThresholdFolderIsExcluded() async throws {
        try write(200, at: "small-folder/a.bin")
        try write(200, at: "small-folder/b.bin")

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let result = await scanner.scan()

        XCTAssertFalse(result.items.contains { $0.path.hasSuffix("small-folder") })
    }

    // MARK: - Symlink skip

    func testSymlinkedDirectoryIsNotCountedOrSurfaced() async throws {
        let realDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-large-scanner-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 200_000).write(to: realDir.appendingPathComponent("big.bin"))
        defer { try? FileManager.default.removeItem(at: realDir) }

        try FileManager.default.createSymbolicLink(
            at: homeDir.appendingPathComponent("link-to-real", isDirectory: true),
            withDestinationURL: realDir
        )

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let result = await scanner.scan()

        XCTAssertFalse(result.items.contains { $0.path.contains("link-to-real") })
    }

    // MARK: - Opaque bundle collapse

    func testOpaqueBundleCollapsesToOneFolderItemAndIsNotDescendedInto() async throws {
        try write(150_000, at: "Foo.app/Contents/MacOS/big-binary")

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let result = await scanner.scan()

        let bundleItems = result.items.filter { $0.path.hasSuffix("Foo.app") }
        XCTAssertEqual(bundleItems.count, 1)
        XCTAssertTrue(bundleItems[0].isDirectory)
        XCTAssertGreaterThanOrEqual(bundleItems[0].sizeBytes, 150_000)

        XCTAssertFalse(result.items.contains { $0.path.contains("big-binary") })
    }

    // MARK: - Excluded paths

    func testExcludedPathIsNeverSurfaced() async throws {
        try write(150_000, at: ".Trash/deleted-big-file.bin")

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let result = await scanner.scan()

        XCTAssertFalse(result.items.contains { $0.path.contains(".Trash") })
    }

    // MARK: - Protection stamping

    func testProtectionStampingMarksDocumentsRootButNotItsChild() async throws {
        try write(150_000, at: "Documents/big.zip")

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let result = await scanner.scan()

        let documentsItem = try XCTUnwrap(result.items.first { $0.path.hasSuffix("Documents") && $0.isDirectory })
        XCTAssertTrue(documentsItem.isProtected)
        XCTAssertFalse(documentsItem.isSelectable)

        let zipItem = try XCTUnwrap(result.items.first { $0.path.hasSuffix("big.zip") })
        XCTAssertFalse(zipItem.isProtected)
        XCTAssertTrue(zipItem.isSelectable)
    }

    // MARK: - Cancellation

    func testCancellationIsDeterministic() async throws {
        try write(150_000, at: "some-file.bin")
        try write(150_000, at: "another-file.bin")

        let scanner = LargeItemScanner(home: homeDir.path, configuration: testConfiguration())
        let task = Task { await scanner.scan() }
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
    }
}
