import XCTest
@testable import ReclaimKit

final class DirectorySizerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-dirsizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testMissingDirectoryReturnsZero() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(DirectorySizer.size(of: missing), 0)
    }

    func testEmptyDirectoryReturnsZero() throws {
        let empty = tempDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(DirectorySizer.size(of: empty), 0)
    }

    func testSumsKnownFileSizesAcrossNestedDirectories() throws {
        let fileA = tempDir.appendingPathComponent("a.bin")
        let fileB = tempDir.appendingPathComponent("nested/b.bin")
        try FileManager.default.createDirectory(
            at: fileB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dataA = Data(repeating: 0x41, count: 12_345)
        let dataB = Data(repeating: 0x42, count: 54_321)
        try dataA.write(to: fileA)
        try dataB.write(to: fileB)

        let expectedMinimum = Int64(dataA.count + dataB.count)
        let size = DirectorySizer.size(of: tempDir)

        // Allocated size is block-rounded, so the measured total can only be >= the logical
        // byte count of the files written — never less, and it must include the nested file.
        XCTAssertGreaterThanOrEqual(size, expectedMinimum)
    }

    func testSymlinkedDirectoryIsNotFollowedOrCounted() throws {
        let realDir = tempDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 100_000).write(to: realDir.appendingPathComponent("big.bin"))

        let scanRoot = tempDir.appendingPathComponent("scan-root", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scanRoot.appendingPathComponent("link-to-real"),
            withDestinationURL: realDir
        )

        // scan-root contains nothing but a symlink to a 100,000-byte directory. Following it
        // would report ~100,000 bytes; skipping it (the required behavior) must report 0.
        XCTAssertEqual(DirectorySizer.size(of: scanRoot), 0)
    }

    func testSymlinkedRegularFileIsNotCounted() throws {
        let realFile = tempDir.appendingPathComponent("real.bin")
        try Data(repeating: 0x44, count: 50_000).write(to: realFile)

        let scanRoot = tempDir.appendingPathComponent("scan-root-file", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scanRoot.appendingPathComponent("link-to-file.bin"),
            withDestinationURL: realFile
        )

        XCTAssertEqual(DirectorySizer.size(of: scanRoot), 0)
    }
}
