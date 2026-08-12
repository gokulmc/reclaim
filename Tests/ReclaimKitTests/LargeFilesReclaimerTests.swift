import XCTest
@testable import ReclaimKit

/// `LargeFilesReclaimer` orchestrates real move-to-Trash end to end, but must never call
/// `FileManager.trashItem` itself — every test here is dry-run-focused and operates against a
/// fake `home` under `FileManager.default.temporaryDirectory` (mirroring
/// `CacheReclaimerTests`), so no real file is ever at risk. Real `trashItem` coverage lives in
/// `FileTrasherTests`.
final class LargeFilesReclaimerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-lf-reclaimer-\(UUID().uuidString)", isDirectory: true)
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

    private func makeFolderItem(relativePath: String) throws -> LargeItem {
        let url = tempHome.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return LargeItem(
            id: url.resolvingSymlinksInPath().standardizedFileURL.path,
            url: url,
            path: url.path,
            sizeBytes: DirectorySizer.size(of: url),
            isDirectory: true,
            isProtected: false
        )
    }

    // MARK: (a) dry run

    func testDryRunLeavesFilesInPlaceAndReportsZeroHostDeltaWithMatchingStepBytes() async throws {
        let itemA = try makeFileItem(relativePath: "big-a.bin", bytes: 4096)
        let itemB = try makeFileItem(relativePath: "nested/big-b.bin", bytes: 2048)

        let reclaimer = LargeFilesReclaimer(home: home, diskProbePath: home)
        var events: [CleanEvent] = []
        let report = try await reclaimer.trash(
            selection: [itemA, itemB],
            options: CleanOptions(dryRun: true)
        ) { events.append($0) }

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.hostDelta, 0, "dry run must not claim any real space was returned")
        XCTAssertNil(report.backend, "a large-files report has no Docker backend")

        XCTAssertTrue(FileManager.default.fileExists(atPath: itemA.url.path), "dry run must not move anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemB.url.path), "dry run must not move anything")

        XCTAssertEqual(report.steps.count, 2)
        for step in report.steps {
            let expected = step.name == itemA.url.lastPathComponent ? DirectorySizer.allocatedSize(of: itemA.url) : DirectorySizer.allocatedSize(of: itemB.url)
            XCTAssertEqual(step.dockerReportedBytes, expected)
        }

        guard case .done(let doneReport)? = events.last else {
            return XCTFail("expected the final event to be .done")
        }
        XCTAssertEqual(doneReport.steps.count, 2)
        let sawStepEvents = events.contains { if case .step = $0 { return true }; return false }
        XCTAssertTrue(sawStepEvents)
    }

    // MARK: (b) ancestor/descendant overlap — vanished-with-parent skip

    func testDescendantVanishedWithParentIsSkippedWithLogAndDoesNotThrow() async throws {
        let folderItem = try makeFolderItem(relativePath: "parent-folder")
        let fileItem = try makeFileItem(relativePath: "parent-folder/child.bin", bytes: 1024)

        // Simulate "already trashed with its parent": remove the child directly, as if a prior
        // move of the parent had already taken it away, before the reclaimer ever processes it.
        try FileManager.default.removeItem(at: fileItem.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileItem.url.path), "fixture sanity check")

        let reclaimer = LargeFilesReclaimer(home: home, diskProbePath: home)
        var logMessages: [String] = []
        let report = try await reclaimer.trash(
            selection: [folderItem, fileItem],
            options: CleanOptions(dryRun: true)
        ) { event in
            if case .log(let text) = event { logMessages.append(text) }
        }

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.steps.count, 1, "only the still-existing parent should produce a step")
        XCTAssertEqual(report.steps.first?.name, folderItem.url.lastPathComponent)
        XCTAssertTrue(
            logMessages.contains { $0.contains("already trashed with its parent") },
            "the vanished descendant must be logged as skipped, not thrown"
        )
    }
}
