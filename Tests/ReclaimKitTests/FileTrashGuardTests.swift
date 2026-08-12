import XCTest
@testable import ReclaimKit

/// `FileTrashGuard` is the safety layer standing before any real move-to-Trash of a
/// user-selected large file or folder (the real `trashItem` call site, `FileTrasher`, lands in
/// a later milestone). These tests pin the reject matrix — catastrophic/irreversible targets —
/// and the allow matrix — arbitrary user files under `Documents`/`Desktop`/`Downloads`/... —
/// which is the entire point of the feature. A temp `home` under
/// `FileManager.default.temporaryDirectory` stands in for `$HOME`, never a real user path, and
/// every fixture is removed in `tearDownWithError`.
final class FileTrashGuardTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-trash-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    private var home: String { tempHome.path }

    @discardableResult
    private func makeDir(_ relativePath: String) throws -> URL {
        let url = tempHome.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(_ relativePath: String, bytes: Int = 1_024) throws -> URL {
        let url = tempHome.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    private func assertRejected(_ target: URL, line: UInt = #line) {
        XCTAssertThrowsError(try FileTrashGuard.validate(target: target, home: home), line: line) { error in
            XCTAssertTrue(error is FileTrashGuard.Violation, line: line)
        }
    }

    private func assertAllowed(_ target: URL, line: UInt = #line) {
        XCTAssertNoThrow(try FileTrashGuard.validate(target: target, home: home), line: line)
    }

    // MARK: - Reject matrix

    func testRejectsTargetEqualToHome() {
        assertRejected(tempHome)
    }

    func testRejectsFilesystemRoot() {
        assertRejected(URL(fileURLWithPath: "/"))
    }

    func testRejectsPathOutsideHome() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-trash-guard-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        assertRejected(outside)
    }

    func testRejectsDocumentsRoot() throws {
        assertRejected(try makeDir("Documents"))
    }

    func testRejectsDesktopRoot() throws {
        assertRejected(try makeDir("Desktop"))
    }

    func testRejectsDownloadsRoot() throws {
        assertRejected(try makeDir("Downloads"))
    }

    func testRejectsBareLibrary() throws {
        assertRejected(try makeDir("Library"))
    }

    func testRejectsApplicationsRoot() throws {
        assertRejected(try makeDir("Applications"))
    }

    func testRejectsDotTrashRoot() throws {
        assertRejected(try makeDir(".Trash"))
    }

    func testRejectsLibraryApplicationSupportRoot() throws {
        assertRejected(try makeDir("Library/Application Support"))
    }

    func testRejectsChildOfLibraryApplicationSupport() throws {
        assertRejected(try makeDir("Library/Application Support/com.example.app"))
    }

    func testRejectsLibraryPreferences() throws {
        assertRejected(try makeDir("Library/Preferences"))
    }

    func testRejectsLibraryKeychains() throws {
        assertRejected(try makeDir("Library/Keychains"))
    }

    func testRejectsLibraryContainers() throws {
        assertRejected(try makeDir("Library/Containers"))
    }

    func testRejectsLibraryGroupContainers() throws {
        assertRejected(try makeDir("Library/Group Containers"))
    }

    func testRejectsChildOfLibraryMobileDocuments() throws {
        assertRejected(try makeDir("Library/Mobile Documents/com~apple~CloudDocs"))
    }

    func testRejectsChildOfLibraryCloudStorage() throws {
        assertRejected(try makeDir("Library/CloudStorage/Dropbox"))
    }

    func testRejectsSSHPrivateKey() throws {
        assertRejected(try makeFile(".ssh/id_rsa"))
    }

    func testRejectsChildOfConfig() throws {
        assertRejected(try makeDir(".config/foo"))
    }

    func testRejectsColima() throws {
        assertRejected(try makeDir(".colima"))
    }

    func testRejectsDocker() throws {
        assertRejected(try makeDir(".docker"))
    }

    func testRejectsOwnHistoryDirectory() throws {
        assertRejected(try makeDir("Library/Application Support/Reclaim"))
    }

    func testRejectsOriginalSymlink() throws {
        let realDir = try makeDir("real-target")
        let symlink = tempHome.appendingPathComponent("link-to-real", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realDir)
        assertRejected(symlink)
    }

    func testRejectsPathContainingVolumeSubstring() throws {
        assertRejected(try makeDir("Documents/backup-volume-2024"))
    }

    // MARK: - Allow matrix

    func testAllowsFileInDocuments() throws {
        assertAllowed(try makeFile("Documents/big.zip", bytes: 10_000))
    }

    func testAllowsFileInDesktop() throws {
        assertAllowed(try makeFile("Desktop/clip.mov", bytes: 10_000))
    }

    func testAllowsFolderInDownloads() throws {
        assertAllowed(try makeDir("Downloads/foo"))
    }

    func testAllowsFileInMovies() throws {
        assertAllowed(try makeFile("Movies/render.mov", bytes: 10_000))
    }

    func testAllowsLibraryDeveloperDerivedData() throws {
        assertAllowed(try makeDir("Library/Developer/Xcode/DerivedData"))
    }

    func testAllowsLibraryCachesSubdir() throws {
        assertAllowed(try makeDir("Library/Caches/com.example"))
    }

    func testAllowsDepthOneFile() throws {
        assertAllowed(try makeFile("big.dmg", bytes: 10_000))
    }

    func testAllowsDepthOneDirectory() throws {
        assertAllowed(try makeDir("projects"))
    }

    // MARK: - Full-list coverage (exercises every protected entry, not just the sample matrix)

    func testAllProtectedRootsAreRejectedOnEquality() throws {
        let protectedRoots = [
            "Documents", "Desktop", "Downloads", "Movies", "Music",
            "Pictures", "Public", "Library", "Applications", "Sites", ".Trash"
        ]
        for relativePath in protectedRoots {
            assertRejected(try makeDir(relativePath))
        }
    }

    func testAllProtectedSubtreesAreRejectedIncludingChildren() throws {
        let protectedSubtrees = [
            "Library/Application Support", "Library/Preferences", "Library/Keychains",
            "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
            "Library/CloudStorage", "Library/Application Support/Reclaim",
            ".ssh", ".gnupg", ".aws", ".config", ".kube", ".docker", ".colima",
            ".orbstack", ".rd", ".Trash"
        ]
        for relativePath in protectedSubtrees {
            assertRejected(try makeDir(relativePath))
            assertRejected(try makeDir(relativePath + "/child-item"))
        }
    }
}
