import XCTest
@testable import ReclaimKit

/// `CacheReclaimer` orchestrates real dev-tool cache deletion end to end, but must never call
/// `FileManager.removeItem` itself — every test here operates against a fake `home` under
/// `FileManager.default.temporaryDirectory` (mirroring `CacheDeleterTests`/`ReclaimerTests`), so
/// no real cache is ever at risk, and `diskProbePath` is injected the same way `ReclaimerTests`
/// injects it for `Reclaimer`.
final class CacheReclaimerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-cache-reclaimer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    private var home: String { tempHome.path }

    /// A small fixture catalog mirroring two real single-directory entries (same relative
    /// paths as the real `npm`/`gradle` catalog entries) so `CacheSafetyGuard`'s depth/allowed
    /// root rules exercise the same paths the real catalog would.
    private var fakeCatalog: [CacheDefinition] {
        [
            CacheDefinition(
                id: "npm",
                displayName: "npm cache",
                description: "test fixture mirroring the real npm catalog entry",
                relativePaths: [".npm"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "gradle",
                displayName: "Gradle caches",
                description: "test fixture mirroring the real gradle catalog entry",
                relativePaths: [".gradle/caches"],
                regenerates: true,
                expansion: .singleDirectory
            )
        ]
    }

    private func populate(_ relativePath: String, bytes: Int) throws {
        let url = tempHome.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: tempHome.appendingPathComponent(relativePath).path)
    }

    // MARK: (a) dry run

    func testDryRunLeavesFilesInPlaceAndReportsZeroHostDelta() async throws {
        try populate(".npm/_cacache/x", bytes: 4096)
        try populate(".gradle/caches/y", bytes: 2048)

        let reclaimer = CacheReclaimer(home: home, diskProbePath: home)
        var events: [CleanEvent] = []
        let report = try await reclaimer.clean(
            selection: ["npm", "gradle"],
            options: CleanOptions(dryRun: true),
            catalog: fakeCatalog
        ) { events.append($0) }

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.hostDelta, 0, "dry run must not claim any real space was returned")
        XCTAssertNil(report.backend, "a cache-only report has no Docker backend")

        XCTAssertTrue(exists(".npm"), "dry run must not remove anything")
        XCTAssertTrue(exists(".gradle/caches"), "dry run must not remove anything")

        guard case .done(let doneReport)? = events.last else {
            return XCTFail("expected the final event to be .done")
        }
        XCTAssertEqual(doneReport.steps.count, 2)
        XCTAssertTrue(doneReport.steps.contains { $0.name == "npm cache" })
        XCTAssertTrue(doneReport.steps.contains { $0.name == "Gradle caches" })
        XCTAssertTrue(doneReport.steps.allSatisfy { $0.dockerReportedBytes > 0 })

        let sawStepEvents = events.contains { if case .step = $0 { return true }; return false }
        XCTAssertTrue(sawStepEvents)
    }

    // MARK: (b) real delete of a specific selection

    func testRealDeleteRemovesOnlySelectedCacheAndReportsBytesFreed() async throws {
        try populate(".npm/_cacache/x", bytes: 4096)
        try populate(".gradle/caches/y", bytes: 2048)

        let reclaimer = CacheReclaimer(home: home, diskProbePath: home)
        let report = try await reclaimer.clean(
            selection: ["npm"],
            options: CleanOptions(dryRun: false),
            catalog: fakeCatalog
        )

        XCTAssertFalse(report.dryRun)
        XCTAssertFalse(exists(".npm"), "the selected cache must be removed")
        XCTAssertTrue(exists(".gradle/caches/y"), "an unselected cache must be left untouched")

        XCTAssertEqual(report.steps.count, 1)
        XCTAssertEqual(report.steps.first?.name, "npm cache")
        XCTAssertGreaterThan(report.steps.first?.dockerReportedBytes ?? 0, 0)
    }

    // MARK: (c) a selection id not present in the current scan is skipped gracefully

    func testMissingSelectionIsSkippedWithLogAndDoesNotThrow() async throws {
        try populate(".npm/_cacache/x", bytes: 4096)

        let reclaimer = CacheReclaimer(home: home, diskProbePath: home)
        var logMessages: [String] = []
        let report = try await reclaimer.clean(
            selection: ["npm", "does-not-exist"],
            options: CleanOptions(dryRun: false),
            catalog: fakeCatalog
        ) { event in
            if case .log(let text) = event { logMessages.append(text) }
        }

        XCTAssertFalse(report.dryRun)
        XCTAssertFalse(exists(".npm"), "the valid selection must still be processed")
        XCTAssertEqual(report.steps.count, 1, "the missing id must not produce a step")
        XCTAssertTrue(
            logMessages.contains { $0.contains("does-not-exist") },
            "a missing selection id must be logged, not thrown"
        )
    }
}
