import XCTest

/// The large-files-feature analogue of `CacheDeleterIsolationTests`: the one invariant this
/// test pins is that `FileManager.trashItem` (or anything containing the substring
/// `trashItem`) appears in exactly one file under `Sources/` — `FileTrasher.swift`, the sole
/// audited move-to-Trash chokepoint (see docs/plan "Safety gates"). This test lives in
/// `Tests/`, so it is never itself scanned. See `.github/workflows/ci.yml`'s
/// `safety-regression` job for the matching CI-side gate.
final class FileTrasherIsolationTests: XCTestCase {
    func testTrashItemAppearsOnlyInFileTrasher() throws {
        let sourcesURL = try sourcesDirectoryURL()
        var offendingFiles: Set<String> = []

        let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let element = enumerator?.nextObject() {
            guard let fileURL = element as? URL, fileURL.pathExtension == "swift" else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if contents.contains("trashItem") {
                offendingFiles.insert(fileURL.lastPathComponent)
            }
        }

        XCTAssertEqual(
            offendingFiles,
            ["FileTrasher.swift"],
            "trashItem must appear in exactly Sources/ReclaimKit/FileTrasher.swift, found in: \(offendingFiles.sorted().joined(separator: ", "))"
        )
    }

    /// Locates the repo's `Sources/` directory relative to this test file, so the test works
    /// regardless of the machine's checkout path — mirrors `CacheDeleterIsolationTests`.
    private func sourcesDirectoryURL() throws -> URL {
        // This file lives at Tests/ReclaimKitTests/FileTrasherIsolationTests.swift — walk up
        // three levels to the repo root, then into Sources/.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // ReclaimKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let sourcesURL = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourcesURL.path) else {
            throw XCTSkip("Could not locate Sources/ directory relative to test file at \(thisFile.path)")
        }
        return sourcesURL
    }
}
