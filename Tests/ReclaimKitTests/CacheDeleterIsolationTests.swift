import XCTest

/// The dev-tool-cache analogue of `SourceGrepRegressionTests`: the one invariant this test
/// pins is that `FileManager.removeItem` (or anything containing the substring `removeItem`)
/// appears in exactly one file under `Sources/` — `CacheDeleter.swift`, the sole audited
/// deletion chokepoint (see docs/plan "Safety design for on-disk deletion"). This test lives
/// in `Tests/`, so it is never itself scanned. See `.github/workflows/ci.yml`'s
/// `safety-regression` job for the matching CI-side gate.
final class CacheDeleterIsolationTests: XCTestCase {
    func testRemoveItemAppearsOnlyInCacheDeleter() throws {
        let sourcesURL = try sourcesDirectoryURL()
        var offendingFiles: Set<String> = []

        let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let element = enumerator?.nextObject() {
            guard let fileURL = element as? URL, fileURL.pathExtension == "swift" else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if contents.contains("removeItem") {
                offendingFiles.insert(fileURL.lastPathComponent)
            }
        }

        XCTAssertEqual(
            offendingFiles,
            ["CacheDeleter.swift"],
            "removeItem must appear in exactly Sources/ReclaimKit/CacheDeleter.swift, found in: \(offendingFiles.sorted().joined(separator: ", "))"
        )
    }

    /// Locates the repo's `Sources/` directory relative to this test file, so the test works
    /// regardless of the machine's checkout path — mirrors `SourceGrepRegressionTests`.
    private func sourcesDirectoryURL() throws -> URL {
        // This file lives at Tests/ReclaimKitTests/CacheDeleterIsolationTests.swift — walk up
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
