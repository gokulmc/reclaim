import XCTest
@testable import ReclaimKit

/// `CacheSafetyGuard` is the dev-tool-cache analogue of `SafetyGuard` and must land before any
/// real on-disk deletion exists (M2 of the cache-subsystem plan). These tests pin the reject
/// matrix and the allow cases the guard is built around. A temp `home` under
/// `FileManager.default.temporaryDirectory` stands in for `$HOME` — never a real user path.
final class CacheSafetyGuardTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-safety-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    private var home: String { tempHome.path }

    /// The real catalog's allowed roots, joined to the temp home — used whenever a test wants
    /// realistic `allowedRoots` without hand-rolling them.
    private var catalogAllowedRoots: [URL] {
        CacheDeleter.allowedRoots(for: CacheCatalog.default(home: home), home: home)
    }

    @discardableResult
    private func makeDir(_ relativePath: String) throws -> URL {
        let url = tempHome.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Reject matrix

    func testRejectsTargetEqualToHome() {
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: tempHome, home: home, allowedRoots: catalogAllowedRoots)) { error in
            XCTAssertTrue(error is CacheSafetyGuard.Violation)
        }
    }

    func testRejectsDocuments() throws {
        let target = try makeDir("Documents")
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: [target]))
    }

    func testRejectsDesktop() throws {
        let target = try makeDir("Desktop")
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: [target]))
    }

    func testRejectsBareLibrary() throws {
        let target = try makeDir("Library")
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: [target]))
    }

    func testRejectsBareLibraryApplicationSupport() throws {
        let target = try makeDir("Library/Application Support")
        // allowedRoots deliberately includes the target itself — the denylist must reject it
        // independent of whatever the (possibly buggy) allowedRoots list contains.
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: [target]))
    }

    func testRejectsOwnHistoryDirectory() throws {
        let target = try makeDir("Library/Application Support/Reclaim")
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: [target]))
    }

    func testRejectsFilesystemRoot() {
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: URL(fileURLWithPath: "/"), home: home, allowedRoots: catalogAllowedRoots))
    }

    func testRejectsPathOutsideHome() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: outside, home: home, allowedRoots: [outside]))
    }

    func testRejectsPathOneLevelUnderHome() throws {
        // A shallow directory that is NOT itself a defined catalog root — unlike `~/.npm`,
        // nothing vetted this path, so the depth floor must still apply.
        let target = try makeDir("SomeTopLevelDir")
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: catalogAllowedRoots))
    }

    func testRejectsPathContainingVolumeSubstring() throws {
        let target = try makeDir("Library/Caches/com.example.volume")
        let allowedRoots = [tempHome.appendingPathComponent("Library/Caches", isDirectory: true)]
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: allowedRoots))
    }

    func testRejectsSymlinkEscapingHome() throws {
        let outsideTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-outside-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideTarget) }

        let cachesDir = try makeDir("Library/Caches")
        let symlink = cachesDir.appendingPathComponent("com.example.evil", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)

        let allowedRoots = [cachesDir]
        XCTAssertThrowsError(try CacheSafetyGuard.validate(target: symlink, home: home, allowedRoots: allowedRoots)) { error in
            XCTAssertTrue(error is CacheSafetyGuard.Violation)
        }
    }

    // MARK: - Allow cases

    func testAllowsRealCatalogSubdirUnderLibraryCaches() throws {
        let target = try makeDir("Library/Caches/com.example.app")
        let allowedRoots = [tempHome.appendingPathComponent("Library/Caches", isDirectory: true)]
        XCTAssertNoThrow(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: allowedRoots))
    }

    func testAllowsNpmCacheDirectory() throws {
        let target = try makeDir(".npm")
        let allowedRoots = [tempHome.appendingPathComponent(".npm", isDirectory: true)]
        XCTAssertNoThrow(try CacheSafetyGuard.validate(target: target, home: home, allowedRoots: allowedRoots))
    }
}
